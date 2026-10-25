//
//  SmartPlaylistDetailVC.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 28.02.26.
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

// MARK: - SmartPlaylistDetailVC

/// G8: read-only detail for smart playlists — a criteria summary section
/// (human-readable rule lines, server badges, honest `unsupportedNotes`)
/// above the resolved song list produced by `SmartPlaylistEvaluator`.
/// `.nsp`-imported playlists are server-managed: no edit affordances
/// anywhere (no edit bar button, no reorder, no row delete).
class SmartPlaylistDetailVC: BasicTableViewController {
  override var sceneTitle: String? { playlist.name }

  private enum SmartSection: Int, CaseIterable {
    case criteria = 0
    case songs = 1
  }

  let playlist: Playlist
  private let criteria: SmartPlaylistCriteria?
  private var resolvedPlayables = [AbstractPlayable]()
  private var isPartiallyEvaluated = false
  private var criteriaLines = [String]()
  private var unsupportedLines = [String]()
  private var badgeLine: String?
  private var detailOperationsView: GenericDetailTableHeader?
  private var optionsButton: UIBarButtonItem!

  init(account: Account, playlist: Playlist) {
    self.playlist = playlist
    self.criteria = playlist.smartCriteria
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SmartRuleCell")
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.backgroundColor = .backgroundColor
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    setNavBarTitle(title: playlist.name)

    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu {
      EntityPreviewActionBuilder(container: self.playlist, on: self).createMenuActions()
    }
    navigationItem.rightBarButtonItem = optionsButton

    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        String(
          format: NSLocalizedString(
            "%lld Songs",
            comment: "Song count label on the resolved-list header (play/shuffle row)"
          ),
          self.resolvedPlayables.count
        )
      },
      playContextCb: { PlayContext(
        containable: self.playlist,
        playables: self.contextPlayables()
      ) },
      player: appDelegate.player,
      isInfoAlwaysHidden: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: playlist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)

    buildCriteriaLines()
    resolveSongs()

    containableAtIndexPathCallback = { indexPath in
      guard indexPath.section == SmartSection.songs.rawValue else { return nil }
      return self.resolvedPlayables.element(at: indexPath.row)
    }
    playContextAtIndexPathCallback = { indexPath in
      guard indexPath.section == SmartSection.songs.rawValue,
            let playable = self.resolvedPlayables.element(at: indexPath.row)
      else { return nil }
      let contextPlayables = self.contextPlayables()
      guard let contextIndex = contextPlayables.firstIndex(of: playable) else { return nil }
      return PlayContext(
        containable: self.playlist,
        index: contextIndex,
        playables: contextPlayables
      )
    }
    swipeCallback = { indexPath, completionHandler in
      guard indexPath.section == SmartSection.songs.rawValue,
            let playable = self.resolvedPlayables.element(at: indexPath.row)
      else {
        completionHandler(nil)
        return
      }
      let contextPlayables = self.contextPlayables()
      let contextIndex = contextPlayables.firstIndex(of: playable) ?? 0
      completionHandler(SwipeActionContext(
        containable: playable,
        playContext: PlayContext(
          containable: self.playlist,
          index: contextIndex,
          playables: contextPlayables
        )
      ))
    }
    updateContentUnavailable()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  private func contextPlayables() -> [AbstractPlayable] {
    resolvedPlayables.filterCached(dependigOn: appDelegate.storage.settings.user.isOfflineMode)
  }

  private func resolveSongs() {
    let resolution = appDelegate.getMeta(account.info).smartPlaylistEvaluator
      .resolve(playlist: playlist, criteria: criteria)
    switch resolution {
    case .localCriteria(let songs):
      resolvedPlayables = songs
      isPartiallyEvaluated = false
    case .serverResolved(let playables, let partiallyEvaluated):
      resolvedPlayables = playables
      isPartiallyEvaluated = partiallyEvaluated
    }
    tableView.reloadData()
    detailOperationsView?.refresh()
    updateContentUnavailable()
  }

  private func updateContentUnavailable() {
    if resolvedPlayables.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = .playlist
      config.text = NSLocalizedString(
        "No Matching Songs",
        comment: "Empty state title for a smart playlist whose rules match nothing"
      )
      config.secondaryText = NSLocalizedString(
        "No songs match these rules right now.",
        comment: "Empty state subtitle for a smart playlist whose rules match nothing"
      )
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: - Criteria summary

  /// turns `SmartPlaylistCriteria` into honest one-line descriptions —
  /// unmapped `.nsp` rules land in `unsupportedNotes` and are rendered
  /// verbatim ("the server resolves the rest"), never silently dropped
  private func buildCriteriaLines() {
    var lines = [String]()
    if playlist.isServerReadOnly {
      badgeLine = NSLocalizedString(
        "Smart playlist · Navidrome — managed by the server, read-only",
        comment: "Badge line for server-managed .nsp smart playlists"
      )
    } else if criteria?.isImportedFromServer == true {
      badgeLine = NSLocalizedString(
        "Smart playlist · imported from server",
        comment: "Badge line for smart playlists imported from the server"
      )
    } else {
      badgeLine = NSLocalizedString(
        "Smart playlist",
        comment: "Badge line for locally-authored smart playlists"
      )
    }

    guard let criteria, !criteria.rules.isEmpty else { return }
    lines.append(
      criteria.combination == .matchAll
        ? NSLocalizedString(
          "Match all rules",
          comment: "Smart playlist combination label: every rule must match"
        )
        : NSLocalizedString(
          "Match any rule",
          comment: "Smart playlist combination label: at least one rule must match"
        )
    )
    for rule in criteria.rules {
      lines.append(
        "\(Self.displayName(for: rule.field)) \(Self.phrase(for: rule.operator)) \(rule.value.displayString)"
      )
    }
    if let sort = criteria.sort {
      lines.append(String(
        format: NSLocalizedString(
          "Sort: %@ (%@)",
          comment: "Smart playlist sort line: field + direction"
        ),
        Self.displayName(for: sort.field),
        sort.ascending
          ? NSLocalizedString("ascending", comment: "Sort direction")
          : NSLocalizedString("descending", comment: "Sort direction")
      ))
    }
    if let limit = criteria.limit, limit > 0 {
      lines.append(String(
        format: NSLocalizedString(
          "Up to %lld songs",
          comment: "Smart playlist limit line"
        ),
        limit
      ))
    }
    if isPartiallyEvaluated || !criteria.unsupportedNotes.isEmpty {
      unsupportedLines = criteria.unsupportedNotes
      lines.append(NSLocalizedString(
        "Partially evaluated — the server resolves rules SonicWave cannot read.",
        comment: "Note on smart playlists with unmapped server rules"
      ))
    }
    criteriaLines = lines
  }

  static func displayName(for field: SmartPlaylistField) -> String {
    switch field {
    case .rating:
      return NSLocalizedString("Rating", comment: "Smart playlist rule field")
    case .playCount:
      return NSLocalizedString("Play count", comment: "Smart playlist rule field")
    case .lastPlayed:
      return NSLocalizedString("Last played", comment: "Smart playlist rule field")
    case .addedDate:
      return NSLocalizedString("Date added", comment: "Smart playlist rule field")
    case .genre:
      return NSLocalizedString("Genre", comment: "Smart playlist rule field")
    case .year:
      return NSLocalizedString("Year", comment: "Smart playlist rule field")
    case .artist:
      return NSLocalizedString("Artist", comment: "Smart playlist rule field")
    case .album:
      return NSLocalizedString("Album", comment: "Smart playlist rule field")
    case .title:
      return NSLocalizedString("Title", comment: "Smart playlist rule field")
    case .favorite:
      return NSLocalizedString("Favorite", comment: "Smart playlist rule field")
    case .disliked:
      return NSLocalizedString("Disliked", comment: "Smart playlist rule field")
    case .custom(let name):
      return name
    }
  }

  static func phrase(for op: SmartPlaylistOperator) -> String {
    switch op {
    case .equal: return NSLocalizedString("is", comment: "Rule operator")
    case .notEqual: return NSLocalizedString("is not", comment: "Rule operator")
    case .greaterThan:
      return NSLocalizedString("is greater than", comment: "Rule operator")
    case .lessThan:
      return NSLocalizedString("is less than", comment: "Rule operator")
    case .contains: return NSLocalizedString("contains", comment: "Rule operator")
    case .notContains:
      return NSLocalizedString("does not contain", comment: "Rule operator")
    case .startsWith:
      return NSLocalizedString("starts with", comment: "Rule operator")
    case .endsWith: return NSLocalizedString("ends with", comment: "Rule operator")
    case .inRange: return NSLocalizedString("is between", comment: "Rule operator")
    case .inLastDays:
      return NSLocalizedString("is within the last", comment: "Rule operator")
    case .notInLastDays:
      return NSLocalizedString("is not within the last", comment: "Rule operator")
    }
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    SmartSection.allCases.count
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch SmartSection(rawValue: section) {
    case .criteria:
      return NSLocalizedString(
        "Rules",
        comment: "Section header for the smart playlist criteria summary"
      )
    case .songs:
      return NSLocalizedString(
        "Songs",
        comment: "Section header for the resolved smart playlist song list"
      )
    default: return nil
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch SmartSection(rawValue: section) {
    case .criteria:
      // badge + rule lines + unsupported notes
      return 1 + criteriaLines.count + unsupportedLines.count
    case .songs:
      return resolvedPlayables.count
    default: return 0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch SmartSection(rawValue: indexPath.section) {
    case .criteria:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: "SmartRuleCell",
        for: indexPath
      )
      var content = UIListContentConfiguration.valueCell()
      if indexPath.row == 0 {
        content.text = badgeLine
        content.image = .sparkles
        content.textProperties.color = .secondaryLabel
      } else if indexPath.row <= criteriaLines.count {
        content.text = criteriaLines[indexPath.row - 1]
        content.image = .listBullet
      } else {
        content.text = unsupportedLines[indexPath.row - 1 - criteriaLines.count]
        content.textProperties.color = .secondaryLabel
      }
      content.textProperties.adjustsFontForContentSizeCategory = true
      cell.contentConfiguration = content
      cell.selectionStyle = .none
      cell.isAccessibilityElement = true
      return cell
    case .songs:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      guard let playable = resolvedPlayables.element(at: indexPath.row) else { return cell }
      cell.display(
        playable: playable,
        playContextCb: { [weak self] cell in
          guard let self,
                let indexPath = self.tableView.indexPath(for: cell)
          else { return nil }
          return self.playContextAtIndexPathCallback?(indexPath)
        },
        rootView: self
      )
      return cell
    default:
      return UITableViewCell()
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch SmartSection(rawValue: indexPath.section) {
    case .criteria: return UITableView.automaticDimension
    case .songs: return PlayableTableCell.rowHeight
    default: return UITableView.automaticDimension
    }
  }
}
