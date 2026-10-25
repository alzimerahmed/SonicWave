//
//  ArtistDetailVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import CoreData
import UIKit

class ArtistDetailVC: MultiSourceTableViewController {
  override var sceneTitle: String? { artist.name }

  /// G20 enrichment sections appended after the FRC-driven ones —
  /// presence is data-driven: `.notSupported`/empty results hide them
  private enum EnrichmentSection {
    case similarArtists
    case topSongs
  }

  private let artist: Artist
  var albumToScrollTo: Album?
  private var albumsFetchedResultsController: ArtistAlbumsItemsFetchedResultsController!
  private var songsFetchedResultsController: ArtistSongsItemsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var detailOperationsView: GenericDetailTableHeader?
  private var similarArtistStubs = [ArtistStub]()
  private var topSongs = [Song]()
  private var artistBio: String?
  private var enrichmentTask: Task<Void, Never>?

  /// FRC-driven table sections: top spacer + albums + songs —
  /// enrichment sections are appended after them
  private static let frcSectionCount = 3
  private static let similarArtistsFetchCount = 20
  private static let topSongsFetchCount = 10

  /// applied enrichment result per account+artist (`objectID` is
  /// account-scoped) — return-navigation must not refire 3 endpoints
  private struct ArtistEnrichment {
    var bio: String?
    var similarStubs: [ArtistStub]
    var topSongs: [Song]
  }
  private static var enrichmentCache = [String: ArtistEnrichment]()
  private var enrichmentCacheKey: String {
    artist.managedObject.objectID.uriRepresentation().absoluteString
  }

  private var visibleEnrichmentSections: [EnrichmentSection] {
    var sections = [EnrichmentSection]()
    if !similarArtistStubs.isEmpty { sections.append(.similarArtists) }
    if !topSongs.isEmpty { sections.append(.topSongs) }
    return sections
  }

  /// FRC sections keep their historic indices (0 = top spacer, 1 = albums,
  /// 2 = songs); enrichment sections sit after them
  private func enrichmentSectionKind(for section: Int) -> EnrichmentSection? {
    guard section >= Self.frcSectionCount else { return nil }
    return visibleEnrichmentSections.element(at: section - Self.frcSectionCount)
  }

  init(account: Account, artist: Artist) {
    self.artist = artist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.artistDetail)

    optionsButton = UIBarButtonItem.createOptionsBarButton()

    albumsFetchedResultsController = ArtistAlbumsItemsFetchedResultsController(
      for: artist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    albumsFetchedResultsController.delegate = self
    songsFetchedResultsController = ArtistSongsItemsFetchedResultsController(
      for: artist,
      displayFilter: appDelegate.storage.settings.user.artistsFilterSetting,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    songsFetchedResultsController.delegate = self
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.register(
      SimilarArtistsShelfCell.self,
      forCellReuseIdentifier: SimilarArtistsShelfCell.reuseID
    )
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    configureSearchController(placeholder: "Albums and Songs", scopeButtonTitles: ["All", "Cached"])
    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        "\(self.artist.albumCount) Album\(self.artist.albumCount == 1 ? "" : "s") \(CommonString.oneMiddleDot) \(self.artist.songCount) Song\(self.artist.songCount == 1 ? "" : "s")"
      },
      playContextCb: { () in
        let songs = self.songsFetchedResultsController
          .getContextSongs(onlyCachedSongs: self.appDelegate.storage.settings.user.isOfflineMode) ??
          []
        let sortedSongs = songs.filterSongs().sortByAlbum()
        return PlayContext(containable: self.artist, playables: sortedSongs)
      },
      player: appDelegate.player,
      isInfoAlwaysHidden: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: artist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    // bio tap expands into the text sheet — install once; the recognizer
    // stays inert until a bio enables interaction (`showFullBio` guards)
    detailOperationsView?.descriptionLabel.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(showFullBio))
    )

    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu {
      EntityPreviewActionBuilder(container: self.artist, on: self).createMenuActions()
    }
    navigationItem.rightBarButtonItem = optionsButton

    containableAtIndexPathCallback = { indexPath in
      if self.enrichmentSectionKind(for: indexPath.section) == .topSongs {
        return self.topSongs.element(at: indexPath.row)
      }
      switch indexPath.section + 1 {
      case LibraryElement.Album.rawValue:
        return self.albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      case LibraryElement.Song.rawValue:
        return self.songsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      default:
        return nil
      }
    }
    playContextAtIndexPathCallback = { indexPath in
      if self.enrichmentSectionKind(for: indexPath.section) == .topSongs,
         let song = self.topSongs.element(at: indexPath.row) {
        let playables = self.topSongs
          .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
        guard let contextIndex = playables.firstIndex(of: song) else { return nil }
        return PlayContext(containable: self.artist, index: contextIndex, playables: playables)
      }
      switch indexPath.section + 1 {
      case LibraryElement.Album.rawValue:
        let album = self.albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        Task { @MainActor in do {
          try await album.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Album Sync", error: error)
        }}
        return PlayContext(containable: album)
      case LibraryElement.Song.rawValue:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        return self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
      default:
        return nil
      }
    }
    swipeCallback = { indexPath, completionHandler in
      if self.enrichmentSectionKind(for: indexPath.section) == .topSongs {
        guard let song = self.topSongs.element(at: indexPath.row) else {
          completionHandler(nil)
          return
        }
        completionHandler(SwipeActionContext(
          containable: song,
          playContext: PlayContext(containable: self.artist, playables: self.topSongs)
        ))
        return
      }
      guard self.enrichmentSectionKind(for: indexPath.section) == nil else {
        completionHandler(nil)
        return
      }
      switch indexPath.section + 1 {
      case LibraryElement.Album.rawValue:
        let album = self.albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        Task { @MainActor in
          do {
            try await album.fetch(
              storage: self.appDelegate.storage,
              librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
              playableDownloadManager: self.appDelegate.getMeta(self.account.info)
                .playableDownloadManager
            )
          } catch {
            self.appDelegate.eventLogger.report(topic: "Album Sync", error: error)
          }
          completionHandler(SwipeActionContext(containable: album))
        }
      case LibraryElement.Song.rawValue:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        let song = self.songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
        let playContext = self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
        completionHandler(SwipeActionContext(containable: song, playContext: playContext))
      default:
        completionHandler(nil)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    albumsFetchedResultsController?.delegate = self
    songsFetchedResultsController?.delegate = self
    Task { @MainActor in
      do {
        try await artist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Artist Sync", error: error)
      }
      self.detailOperationsView?.refresh()
    }
    enrichmentTask?.cancel()
    enrichmentTask = Task { @MainActor [weak self] in
      await self?.loadEnrichment()
    }
  }

  /// G20: server-side enrichment (bio, similar artists, top songs).
  /// Every call is `BackendFeatureResult`-matched — `.notSupported` or an
  /// empty payload leaves the section hidden, it never shows "error".
  /// Each endpoint degrades independently so one failure cannot suppress
  /// the others; the completed result is cached per account+artist.
  private func loadEnrichment() async {
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    if let cached = Self.enrichmentCache[enrichmentCacheKey] {
      applyEnrichment(cached)
      tableView.reloadData()
      return
    }
    let backendApi = appDelegate.getMeta(account.info).backendApi
    var enrichment = ArtistEnrichment(similarStubs: [], topSongs: [])
    var allEndpointsAnswered = true
    do {
      if case .supported(let info) = try await backendApi.getArtistInfo(artistId: artist.id) {
        if let bio = info.biography?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bio.isEmpty {
          enrichment.bio = bio
        }
        if !info.similarArtists.isEmpty {
          enrichment.similarStubs = info.similarArtists
        }
      }
    } catch {
      allEndpointsAnswered = false
      appDelegate.eventLogger.report(topic: "Artist Enrichment", error: error)
    }
    guard !Task.isCancelled else { return }
    if enrichment.similarStubs.isEmpty {
      do {
        if case .supported(let stubs) = try await backendApi.getSimilarArtists(
          artistId: artist.id,
          count: Self.similarArtistsFetchCount
        ) {
          enrichment.similarStubs = stubs
        }
      } catch {
        allEndpointsAnswered = false
        appDelegate.eventLogger.report(topic: "Artist Enrichment", error: error)
      }
    }
    guard !Task.isCancelled else { return }
    do {
      if case .supported(let remoteSongs) = try await backendApi.getTopSongs(
        artistName: artist.name,
        count: Self.topSongsFetchCount
      ) {
        enrichment.topSongs = remoteSongs.compactMap {
          appDelegate.storage.main.library.getSong(for: account, id: $0.id)
        }
      }
    } catch {
      allEndpointsAnswered = false
      appDelegate.eventLogger.report(topic: "Artist Enrichment", error: error)
    }
    guard !Task.isCancelled else { return }
    // cache only fully-answered rounds — a transient failure retries on
    // the next open instead of freezing a partial result forever
    if allEndpointsAnswered {
      Self.enrichmentCache[enrichmentCacheKey] = enrichment
    }
    applyEnrichment(enrichment)
    tableView.reloadData()
  }

  private func applyEnrichment(_ enrichment: ArtistEnrichment) {
    if let bio = enrichment.bio {
      artistBio = bio
      detailOperationsView?.updateDescription(text: bio)
      // collapsed bio in the header → tap expands into the text sheet
      detailOperationsView?.descriptionLabel.isUserInteractionEnabled = true
      detailOperationsView?.descriptionLabel.accessibilityTraits = .button
      detailOperationsView?.descriptionLabel.accessibilityHint = NSLocalizedString(
        "Shows the full biography",
        comment: "VoiceOver hint on the collapsed artist bio"
      )
    }
    similarArtistStubs = enrichment.similarStubs
    topSongs = enrichment.topSongs
  }

  /// collapsed bio in the header expands into the plain-text sheet
  @objc
  private func showFullBio() {
    guard let artistBio else { return }
    let detailsVC = PlainDetailsVC()
    detailsVC.display(
      text: artistBio,
      header: NSLocalizedString("About", comment: "Artist bio sheet header"),
      on: self
    )
    present(detailsVC, animated: true)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    albumsFetchedResultsController?.delegate = nil
    songsFetchedResultsController?.delegate = nil
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { albumToScrollTo = nil }
    guard let albumToScrollTo = albumToScrollTo,
          let indexPath = albumsFetchedResultsController.fetchResultsController
          .indexPath(forObject: albumToScrollTo.managedObject)
    else { return }
    let adjustedIndexPath = IndexPath(row: indexPath.row, section: 1)
    tableView.scrollToRow(at: adjustedIndexPath, at: .top, animated: true)
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = songsFetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    let selectedSong = songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
    guard let playContextIndex = songs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: artist, index: playContextIndex, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell),
          indexPath.section + 1 == LibraryElement.Song.rawValue
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    // 2 section + 1 top section. The top section is needed due to display bugs
    // + G20 enrichment sections (similar artists shelf, top songs)
    3 + visibleEnrichmentSections.count
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch enrichmentSectionKind(for: section) {
    case .similarArtists:
      return NSLocalizedString(
        "Similar Artists",
        comment: "Artist detail section header"
      )
    case .topSongs:
      return NSLocalizedString("Top Songs", comment: "Artist detail section header")
    case nil:
      break
    }
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return "Albums"
    case LibraryElement.Song.rawValue:
      return "Songs"
    default:
      return ""
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch enrichmentSectionKind(for: section) {
    case .similarArtists: return 1
    case .topSongs: return topSongs.count
    case nil:
      break
    }
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return albumsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    default:
      return 0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch enrichmentSectionKind(for: indexPath.section) {
    case .similarArtists:
      guard let cell = tableView.dequeueReusableCell(
        withIdentifier: SimilarArtistsShelfCell.reuseID,
        for: indexPath
      ) as? SimilarArtistsShelfCell else { return UITableViewCell() }
      cell.display(stubs: similarArtistStubs, account: account)
      cell.onSelectArtist = { [weak self] artist in
        guard let self else { return }
        self.navigationController?.pushViewController(
          AppStoryboard.Main.segueToArtistDetail(account: self.account, artist: artist),
          animated: true
        )
      }
      return cell
    case .topSongs:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      guard let song = topSongs.element(at: indexPath.row) else { return cell }
      cell.display(
        playable: song,
        playContextCb: { [weak self] cell in
          guard let self,
                let indexPath = self.tableView.indexPath(for: cell)
          else { return nil }
          return self.playContextAtIndexPathCallback?(indexPath)
        },
        rootView: self
      )
      return cell
    case nil:
      break
    }
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      let album = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(container: album, rootView: self)
      return cell
    case LibraryElement.Song.rawValue:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      let song = songsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
      return cell
    default:
      return UITableViewCell()
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    if enrichmentSectionKind(for: section) != nil {
      return CommonScreenOperations.tableSectionHeightLarge
    }
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return albumsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch enrichmentSectionKind(for: indexPath.section) {
    case .similarArtists: return SimilarArtistsShelfCell.shelfHeight
    case .topSongs: return PlayableTableCell.rowHeight
    case nil: break
    }
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch enrichmentSectionKind(for: indexPath.section) {
    case .similarArtists: return SimilarArtistsShelfCell.shelfHeight
    case .topSongs: return PlayableTableCell.rowHeight
    case nil: break
    }
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    switch enrichmentSectionKind(for: indexPath.section) {
    case .topSongs:
      // forwards to one-tap row playback when enabled in settings
      super.tableView(tableView, didSelectRowAt: indexPath)
      return
    case .similarArtists, nil:
      break
    }
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      let album = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
    case LibraryElement.Song.rawValue:
      // forwards to one-tap row playback when enabled in settings
      super.tableView(tableView, didSelectRowAt: indexPath)
    default: break
    }
  }

  override func updateSearchResults(for searchController: UISearchController) {
    guard let searchText = searchController.searchBar.text else { return }
    if !searchText.isEmpty, searchController.searchBar.selectedScopeButtonIndex == 0 {
      albumsFetchedResultsController.search(searchText: searchText, onlyCached: false)
      songsFetchedResultsController.search(searchText: searchText, onlyCachedSongs: false)
    } else if searchController.searchBar.selectedScopeButtonIndex == 1 {
      albumsFetchedResultsController.search(searchText: searchText, onlyCached: true)
      songsFetchedResultsController.search(searchText: searchText, onlyCachedSongs: true)
    } else {
      albumsFetchedResultsController.showAllResults()
      songsFetchedResultsController.showAllResults()
    }
    tableView.reloadData()
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange anObject: Any,
    at indexPath: IndexPath?,
    for type: NSFetchedResultsChangeType,
    newIndexPath: IndexPath?
  ) {
    var section = 0
    switch controller {
    case albumsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Album.rawValue - 1
    case songsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Song.rawValue - 1
    default:
      return
    }

    resultUpdateHandler?.applyChangesOfMultiRowType(
      controller,
      didChange: anObject,
      determinedSection: section,
      at: indexPath,
      for: type,
      newIndexPath: newIndexPath
    )
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange sectionInfo: NSFetchedResultsSectionInfo,
    atSectionIndex sectionIndex: Int,
    for type: NSFetchedResultsChangeType
  ) {}
}
