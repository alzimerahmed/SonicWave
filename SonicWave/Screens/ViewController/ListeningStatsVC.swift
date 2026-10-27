//
//  ListeningStatsVC.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 26.10.26.
//  Copyright (c) 2026 Alzimer Ahmed. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import SonicWaveKit
import UIKit

// MARK: - ListeningStatsVC

/// G14 listening analytics — Recap card, totals and top-N charts over
/// the on-device `PlayEvent` history for one account. All numbers come
/// from `ListeningStatsProvider` (pure aggregation over real rows);
/// when collection is off or nothing was recorded the screen says so
/// honestly instead of drawing fake charts.
class ListeningStatsVC: UITableViewController {
  private enum SectionKind {
    case recap
    case totals
    case topSongs
    case topArtists
    case topAlbums
    case topGenres

    var header: String? {
      switch self {
      case .recap: nil
      case .totals:
        String(localized: "Totals", comment: "Listening stats section header")
      case .topSongs:
        String(localized: "Top Songs", comment: "Listening stats section header")
      case .topArtists:
        String(localized: "Top Artists", comment: "Listening stats section header")
      case .topAlbums:
        String(localized: "Top Albums", comment: "Listening stats section header")
      case .topGenres:
        String(localized: "Top Genres", comment: "Listening stats section header")
      }
    }
  }

  private let account: Account
  /// lazy — `appDelegate` can't be touched before `super.init`
  private lazy var statsProvider = ListeningStatsProvider(
    library: appDelegate.storage.main.library
  )
  private var period: ListeningPeriod = .week
  private var stats: ListeningStats?
  /// playable id → Song, prefetched once per reload — cells must not
  /// run a `getSong` fetch per render
  private var representativeSongs = [String: Song]()
  private var hasAnyEvents = false
  private var sections = [SectionKind]()

  init(account: Account) {
    self.account = account
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "Listening Stats", comment: "Listening stats screen title")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "statsCell")
    tableView.backgroundColor = .backgroundColor
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "square.and.arrow.up"),
      style: .plain,
      target: self,
      action: #selector(shareRecap)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "Share recap",
      comment: "VoiceOver label for the listening stats share button"
    )
    tableView.tableHeaderView = createPeriodSelector()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
    reload()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  // MARK: period selector

  private func createPeriodSelector() -> UIView {
    let segmented = UISegmentedControl(
      items: ListeningPeriod.allCases.map { $0.displayName }
    )
    segmented.selectedSegmentIndex = period.rawValue
    segmented.addTarget(self, action: #selector(periodChanged(_:)), for: .valueChanged)
    let header = UIView()
    header.addSubview(segmented)
    segmented.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      segmented.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      segmented.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
      segmented.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
    ])
    header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 48)
    return header
  }

  @objc
  private func periodChanged(_ sender: UISegmentedControl) {
    guard let newPeriod = ListeningPeriod(rawValue: sender.selectedSegmentIndex) else { return }
    period = newPeriod
    reload()
  }

  // MARK: data

  private var isCollectionEnabled: Bool {
    appDelegate.storage.settings.user.isListeningHistoryEnabled
  }

  private func reload() {
    hasAnyEvents = statsProvider.hasAnyEvents(for: account)
    if isCollectionEnabled || hasAnyEvents {
      stats = statsProvider.stats(for: account, period: period)
    } else {
      stats = nil
    }
    prefetchRepresentativeSongs()
    rebuildSections()
    updateContentUnavailable()
    navigationItem.rightBarButtonItem?.isEnabled = stats?.isEmpty == false
    tableView.reloadData()
  }

  private func rebuildSections() {
    sections = [SectionKind]()
    guard let stats, !stats.isEmpty else { return }
    sections.append(.recap)
    sections.append(.totals)
    if !stats.topSongs.isEmpty { sections.append(.topSongs) }
    if !stats.topArtists.isEmpty { sections.append(.topArtists) }
    if !stats.topAlbums.isEmpty { sections.append(.topAlbums) }
    if !stats.topGenres.isEmpty { sections.append(.topGenres) }
  }

  private func updateContentUnavailable() {
    if !isCollectionEnabled, !hasAnyEvents {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "chart.bar")
      config.text = String(
        localized: "Listening History Is Off",
        comment: "Listening stats empty state: collection disabled"
      )
      config.secondaryText = String(
        localized: "Turn it on in Settings to start recording what you play — it never leaves this device.",
        comment: "Listening stats empty state: collection disabled hint"
      )
      contentUnavailableConfiguration = config
    } else if let stats, stats.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "music.note")
      if hasAnyEvents {
        config.text = String(
          localized: "Nothing In This Period",
          comment: "Listening stats empty state: no events in selected period"
        )
        config.secondaryText = String(
          localized: "No plays recorded in this range — try a wider period.",
          comment: "Listening stats empty state: widen period hint"
        )
      } else {
        config.text = String(
          localized: "No Listening History Yet",
          comment: "Listening stats empty state: nothing recorded"
        )
        config.secondaryText = String(
          localized: "Play some music — your listening stats will appear here.",
          comment: "Listening stats empty state: play music hint"
        )
      }
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: artwork

  private var themePreference: ThemePreference {
    appDelegate.storage.settings.accounts.getSetting(account.info).read.themePreference
  }

  private var artworkDisplayPreference: ArtworkDisplayPreference {
    appDelegate.storage.settings.accounts.getSetting(account.info).read.artworkDisplayPreference
  }

  private func image(forEntity entity: AbstractLibraryEntity?) -> UIImage {
    guard let entity else {
      return UIImage.getGeneratedArtwork(theme: themePreference, artworkType: .song)
    }
    return LibraryEntityImage.getImageToDisplayImmediately(
      libraryEntity: entity,
      themePreference: themePreference,
      artworkDisplayPreference: artworkDisplayPreference,
      useCache: true
    )
  }

  /// one fetch pass per reload — the chart lists are bounded
  /// (topLimit), so a flat id→Song map keeps `cellForRowAt` fetch-free
  private func prefetchRepresentativeSongs() {
    var songs = [String: Song]()
    if let stats {
      let library = appDelegate.storage.main.library
      let ids = (stats.topSongs + stats.topArtists + stats.topAlbums)
        .compactMap { $0.representativePlayableId }
      for id in Set(ids) {
        if let song = library.getSong(for: account, id: id) {
          songs[id] = song
        }
      }
    }
    representativeSongs = songs
  }

  private func representativeSong(of entry: ListeningTopEntry) -> Song? {
    guard let playableId = entry.representativePlayableId else { return nil }
    return representativeSongs[playableId]
  }

  // MARK: actions

  @objc
  private func shareRecap() {
    guard let stats, !stats.isEmpty else { return }
    let text = ListeningStatsAggregator.recapText(for: stats, periodTitle: stats.period.recapTitle)
    let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
    present(activityVC, animated: true)
  }

  // MARK: table

  override func numberOfSections(in tableView: UITableView) -> Int {
    sections.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].header
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard let stats else { return 0 }
    switch sections[section] {
    case .recap: return 1
    case .totals: return 3
    case .topSongs: return stats.topSongs.count
    case .topArtists: return stats.topArtists.count
    case .topAlbums: return stats.topAlbums.count
    case .topGenres: return stats.topGenres.count
    }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "statsCell", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.image = nil
    cell.accessoryType = .none
    cell.selectionStyle = .none
    cell.accessibilityLabel = nil // reused cells must not leak the recap label
    guard let stats else {
      cell.contentConfiguration = content
      return cell
    }

    switch sections[indexPath.section] {
    case .recap:
      content.text = String(
        format: String(
          localized: "Recap — %@",
          comment: "Listening stats recap card title (e.g. 'Recap — Last 7 Days')"
        ),
        stats.period.recapTitle
      )
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      content.secondaryText = recapDetail(for: stats)
      content.secondaryTextProperties.numberOfLines = 0
      cell.accessibilityLabel = [
        content.text,
        content.secondaryText,
      ].compactMap { $0 }.joined(separator: ", ")

    case .totals:
      switch indexPath.row {
      case 0:
        content.text = String(localized: "Listening Time", comment: "Listening stats total row")
        content.secondaryText = stats.secondsListened.asDurationShortString
        content.image = UIImage(systemName: "clock")
      case 1:
        content.text = String(localized: "Counted Plays", comment: "Listening stats total row")
        content.secondaryText = "\(stats.playCount)"
        content.image = UIImage(systemName: "play.circle")
      default:
        content.text = String(localized: "Skips", comment: "Listening stats total row")
        content.secondaryText = "\(stats.skipCount)"
        content.image = UIImage(systemName: "forward.end")
      }

    case .topSongs:
      configureTopEntryCell(content: &content, entry: stats.topSongs[indexPath.row], rank: indexPath.row + 1)
      content.image = image(forEntity: representativeSong(of: stats.topSongs[indexPath.row]))
      content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
      content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)

    case .topArtists:
      configureTopEntryCell(content: &content, entry: stats.topArtists[indexPath.row], rank: indexPath.row + 1)
      content.image = image(forEntity: representativeSong(of: stats.topArtists[indexPath.row])?.artist)
      content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
      content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)

    case .topAlbums:
      configureTopEntryCell(content: &content, entry: stats.topAlbums[indexPath.row], rank: indexPath.row + 1)
      content.image = image(forEntity: representativeSong(of: stats.topAlbums[indexPath.row])?.album)
      content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
      content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)

    case .topGenres:
      configureTopEntryCell(content: &content, entry: stats.topGenres[indexPath.row], rank: indexPath.row + 1)
      content.image = UIImage.getGeneratedArtwork(theme: themePreference, artworkType: .genre)
      content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
      content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
    }

    cell.contentConfiguration = content
    return cell
  }

  private func configureTopEntryCell(
    content: inout UIListContentConfiguration,
    entry: ListeningTopEntry,
    rank: Int
  ) {
    content.text = "\(rank). \(entry.name)"
    var detailParts = [String]()
    if let detail = entry.detail { detailParts.append(detail) }
    detailParts.append(
      String(
        format: String(
          localized: "%lld plays",
          comment: "Listening stats entry play count"
        ),
        entry.playCount
      )
    )
    detailParts.append(entry.secondsListened.asDurationShortString)
    content.secondaryText = detailParts.joined(separator: " · ")
  }

  private func recapDetail(for stats: ListeningStats) -> String {
    var parts = [String]()
    parts.append(
      String(
        format: String(
          localized: "%@ of music · %lld plays across %lld songs",
          comment: "Listening stats recap summary line"
        ),
        stats.secondsListened.asDurationShortString,
        stats.playCount,
        stats.uniqueSongCount
      )
    )
    if let topArtist = stats.topArtists.first {
      parts.append(
        String(
          format: String(
            localized: "Top artist: %@ (%lld plays)",
            comment: "Listening stats recap top artist line"
          ),
          topArtist.name,
          topArtist.playCount
        )
      )
    }
    return parts.joined(separator: "\n")
  }
}

// MARK: - ListeningPeriod + display strings

/// display strings live in the app target so they resolve through the
/// app's `Localizable.xcstrings` — the kit keeps the raw semantics
private extension ListeningPeriod {
  var displayName: String {
    switch self {
    case .week:
      String(localized: "Week", comment: "Listening stats period label")
    case .month:
      String(localized: "Month", comment: "Listening stats period label")
    case .year:
      String(localized: "Year", comment: "Listening stats period label")
    case .allTime:
      String(localized: "All Time", comment: "Listening stats period label")
    }
  }

  /// recap-share phrasing ("Last 7 Days", …) — kept separate from
  /// `displayName` so the compact segmented labels stay short
  var recapTitle: String {
    switch self {
    case .week:
      String(localized: "Last 7 Days", comment: "Listening stats recap period title")
    case .month:
      String(localized: "Last Month", comment: "Listening stats recap period title")
    case .year:
      String(localized: "Last Year", comment: "Listening stats recap period title")
    case .allTime:
      String(localized: "All Time", comment: "Listening stats recap period title")
    }
  }
}
