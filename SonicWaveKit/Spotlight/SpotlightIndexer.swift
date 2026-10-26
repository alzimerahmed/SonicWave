//
//  SpotlightIndexer.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 25.10.26.
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

import CoreData
import CoreSpotlight
import Foundation
import os.log

// MARK: - SpotlightChange

/// Coalescible unit of index work extracted synchronously inside a
/// `NSManagedObjectContextDidSave` handler (which runs on the saving
/// context's private queue — attribute access is safe there, but only
/// `objectID` URIs / precomputed identifiers may cross the boundary).
enum SpotlightChange: Sendable {
  /// `objectID.uriRepresentation().absoluteString` of an inserted/updated
  /// indexable entity — resolved to a fresh descriptor during drain
  case upsert(objectUri: String)
  /// encoded `SpotlightItemIdentifier` of a deleted entity
  case delete(identifier: String)
}

// MARK: - SpotlightIndexer

/// CoreSpotlight mirror of the synced library (G27).
///
/// Index lifecycle:
/// - `start()` is called once from each manager-start seam
///   (`startManagerForNormalOperation` without, `startManagerAfterSync`
///   with a forced full reindex). First run — or every initial/resync —
///   walks all entities in `indexBatchSize` chunks on a background context.
/// - Delta path: `NSManagedObjectContextDidSave` on *any* context (sync
///   writes land on background contexts merging into `viewContext`) feeds
///   coalesced upsert/delete buffers drained on a short debounce.
/// - Deletions are captured eagerly in the save handler (attributes are
///   still readable there) and applied via `deleteItems(identifiers:)`.
/// - `AppSettings.hasCompletedInitialSpotlightIndex` guards the one-time
///   full pass for users upgrading with an already-synced library.
/// - Opt-out: `UserSettings.isSpotlightIndexingEnabled` (Optional-backed,
///   defaults true) — disabling wipes the index and re-arms the initial
///   flag so re-enabling rebuilds. Indexing only runs while an account is
///   active and the library is synced.
///
/// Donations: `lastUsedDate`/`playCount` ride along on every upsert —
/// `playedViaContext` MO writes hit the delta observer for free.
public actor SpotlightIndexer {
  private let asyncStorage: AsyncCoreDataAccessWrapper
  private var settings: AmperfySettings
  private let searchableIndex: SearchableIndexing
  private let fileManager: CacheFileManager
  private let performanceMonitor: ThreadPerformanceMonitor
  /// debounce between the last CoreData save and drain — sync writes
  /// arrive in bursts, this collapses them into one batch cycle
  private let drainDebounceNanoseconds: UInt64
  /// max entities resolved/indexed per CoreData + Spotlight call
  private let indexBatchSize: Int

  /// cap for lyric text injected into `attributeSet.textContent` —
  /// lyrics can be huge; ~6 KB keeps index entries cheap
  static let lyricsTextMaxLength = 6_000

  private var contextSaveObserver: NSObjectProtocol?
  private var pendingUpsertUris = Set<String>()
  private var pendingDeleteIdentifiers = Set<String>()
  private var drainTask: Task<Void, Never>?
  /// reentrancy guard — `drainPending` suspends on Spotlight IO with
  /// `drainTask` already nilled, so an enqueue landing mid-drain would
  /// spawn a second, interleaved drain without this flag (unordered
  /// delete/upsert). The single in-flight drain loops until the pending
  /// sets are empty, so an early-returned enqueue loses nothing.
  private var isDraining = false
  private var fullReindexTask: Task<Void, Never>?

  init(
    asyncStorage: AsyncCoreDataAccessWrapper,
    settings: AmperfySettings,
    searchableIndex: SearchableIndexing = CSSearchableIndex.default(),
    fileManager: CacheFileManager = .shared,
    performanceMonitor: ThreadPerformanceMonitor = ThreadPerformanceObserver.shared,
    drainDebounceNanoseconds: UInt64 = 500_000_000,
    indexBatchSize: Int = 250
  ) {
    self.asyncStorage = asyncStorage
    self.settings = settings
    self.searchableIndex = searchableIndex
    self.fileManager = fileManager
    self.performanceMonitor = performanceMonitor
    self.drainDebounceNanoseconds = drainDebounceNanoseconds
    self.indexBatchSize = indexBatchSize
  }

  private var isIndexingAllowed: Bool {
    settings.user.isSpotlightIndexingEnabled &&
      settings.app.isLibrarySynced &&
      settings.accounts.active != nil
  }

  /// Entry point for both manager-start seams and for a future settings
  /// toggle (call again after `isSpotlightIndexingEnabled` changes — the
  /// call re-evaluates the flag both ways).
  public func start(forceFullReindex: Bool = false) async {
    guard settings.user.isSpotlightIndexingEnabled else {
      // opt-out: stop all work and wipe whatever is already indexed;
      // resetting the initial flag makes a later re-enable rebuild
      stop()
      pendingUpsertUris.removeAll()
      pendingDeleteIdentifiers.removeAll()
      try? await searchableIndex.deleteAllItems()
      settings.app.hasCompletedInitialSpotlightIndex = false
      return
    }
    guard isIndexingAllowed else { return }
    startObservingContextSavesIfNeeded()
    if forceFullReindex || !settings.app.hasCompletedInitialSpotlightIndex {
      scheduleFullReindex()
    }
  }

  /// Tears down observers and cancels in-flight work — called on opt-out.
  public func stop() {
    if let observer = contextSaveObserver {
      NotificationCenter.default.removeObserver(observer)
      contextSaveObserver = nil
    }
    drainTask?.cancel()
    drainTask = nil
    fullReindexTask?.cancel()
    fullReindexTask = nil
  }

  /// Purges one account's items — the encoded domain is the account ident
  /// (entity-level deletes also flow through the CoreData save observer).
  public func deleteItems(forAccountIdent accountIdent: String) async {
    guard !accountIdent.isEmpty else { return }
    try? await searchableIndex.deleteItems(domainIdentifiers: [accountIdent])
  }

  /// Targeted refresh for a single playable — used when lyrics get cached
  /// *after* the entity was indexed (the `.swlyrics.json` write touches no
  /// CoreData object, so the delta observer cannot see it).
  public func reindexPlayable(accountIdent: String, playableId: String) async {
    guard isIndexingAllowed else { return }
    let objectUri = try? await asyncStorage.performAndGet { companion in
      guard let account = companion.library.getAccount(ident: accountIdent)
      else { return nil as String? }
      if let song = companion.library.getSong(for: account, id: playableId) {
        return song.objectID.uriRepresentation().absoluteString
      }
      if let episode = companion.library.getPodcastEpisode(for: account, id: playableId) {
        return episode.objectID.uriRepresentation().absoluteString
      }
      return nil
    }
    if let objectUri {
      pendingUpsertUris.insert(objectUri)
    } else {
      // playable is gone — drop either possible index entry
      pendingDeleteIdentifiers.insert(SpotlightItemIdentifier(
        type: .song,
        accountIdent: accountIdent,
        id: playableId
      ).encoded)
      pendingDeleteIdentifiers.insert(SpotlightItemIdentifier(
        type: .podcastEpisode,
        accountIdent: accountIdent,
        id: playableId
      ).encoded)
    }
    scheduleDrain()
  }

  // MARK: delta pipeline

  private func startObservingContextSavesIfNeeded() {
    guard contextSaveObserver == nil else { return }
    contextSaveObserver = NotificationCenter.default.addObserver(
      forName: .NSManagedObjectContextDidSave,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      // handler runs on the saving context's queue — extract only Sendable
      // tokens synchronously, then hop to the actor for storage work
      let tokens = SpotlightIndexer.extractChangeTokens(from: notification)
      guard !tokens.isEmpty else { return }
      Task { await self?.enqueue(tokens) }
    }
  }

  /// Runs on the saving context's private queue, mid-`save()`. Managed
  /// object attribute reads are legal here; nothing else is touched.
  static func extractChangeTokens(from notification: Notification) -> [SpotlightChange] {
    var tokens = [SpotlightChange]()
    let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
    let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
    for object in inserted.union(updated) {
      guard entityType(of: object) != nil else { continue }
      tokens.append(.upsert(objectUri: object.objectID.uriRepresentation().absoluteString))
    }
    let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
    for object in deleted {
      guard let identifier = deleteIdentifier(for: object) else { continue }
      tokens.append(.delete(identifier: identifier.encoded))
    }
    return tokens
  }

  static func entityType(of object: NSManagedObject) -> SpotlightItemType? {
    switch object {
    case is SongMO:
      return .song
    case is PodcastEpisodeMO:
      return .podcastEpisode
    case is AlbumMO:
      return .album
    case is ArtistMO:
      return .artist
    case is PlaylistMO:
      return .playlist
    case is PodcastMO:
      return .podcast
    default:
      return nil
    }
  }

  private static func makeIdentifier(
    _ type: SpotlightItemType,
    id: String,
    accountMO: AccountMO?
  )
    -> SpotlightItemIdentifier? {
    guard !id.isEmpty, let accountMO else { return nil }
    return SpotlightItemIdentifier(
      type: type,
      accountIdent: "\(accountMO.serverHash ?? "")-\(accountMO.userHash ?? "")",
      id: id
    )
  }

  /// Identifier for a deleted entity — relationship + id are still readable
  /// inside `didSave`. `PlaylistMO` (no `AbstractLibraryEntityMO` parent)
  /// carries the same `id`/`account` shape.
  static func deleteIdentifier(for object: NSManagedObject) -> SpotlightItemIdentifier? {
    switch object {
    case let mo as SongMO:
      return makeIdentifier(.song, id: mo.id, accountMO: mo.account)
    case let mo as PodcastEpisodeMO:
      return makeIdentifier(.podcastEpisode, id: mo.id, accountMO: mo.account)
    case let mo as AlbumMO:
      return makeIdentifier(.album, id: mo.id, accountMO: mo.account)
    case let mo as ArtistMO:
      return makeIdentifier(.artist, id: mo.id, accountMO: mo.account)
    case let mo as PlaylistMO:
      return makeIdentifier(.playlist, id: mo.id, accountMO: mo.account)
    case let mo as PodcastMO:
      return makeIdentifier(.podcast, id: mo.id, accountMO: mo.account)
    default:
      return nil
    }
  }

  /// Coalescing entry point — save bursts accumulate, one drain applies them.
  func enqueue(_ tokens: [SpotlightChange]) {
    guard isIndexingAllowed else { return }
    for token in tokens {
      switch token {
      case .upsert(let objectUri):
        pendingUpsertUris.insert(objectUri)
      case .delete(let identifier):
        pendingDeleteIdentifiers.insert(identifier)
      }
    }
    scheduleDrain()
  }

  private func scheduleDrain() {
    // !isDraining: enqueues mid-drain are picked up by the in-flight loop
    // (its exit-check→flag-clear window is synchronous on the actor) — a
    // second task would only early-return and, worse, stay referenced in
    // drainTask and suppress all future scheduling
    guard drainTask == nil, !isDraining else { return }
    let debounce = drainDebounceNanoseconds
    drainTask = Task { [weak self] in
      if debounce > 0 {
        try? await Task.sleep(nanoseconds: debounce)
      }
      await self?.drainPending()
    }
  }

  /// Applies pending work immediately — the debounced drain and tests both
  /// funnel through here. Reentrant calls return early: the in-flight
  /// drain already loops until both pending sets are empty.
  func drainPending() async {
    // nil first — a redundant task spawned just before a drain started must
    // self-clean its reference, or drainTask stays non-nil forever
    drainTask = nil
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }
    while isIndexingAllowed,
          !pendingUpsertUris.isEmpty || !pendingDeleteIdentifiers.isEmpty,
          !Task.isCancelled {
      // deletes first so a delete->reinsert cycle ends with the upsert
      if !pendingDeleteIdentifiers.isEmpty {
        let batch = Array(pendingDeleteIdentifiers.prefix(indexBatchSize))
        try? await searchableIndex.deleteItems(identifiers: batch)
        pendingDeleteIdentifiers.subtract(batch)
        continue
      }
      let batch = Array(pendingUpsertUris.prefix(indexBatchSize))
      let (descriptors, staleIdentifiers) = await buildDescriptors(objectUris: batch)
      if !descriptors.isEmpty {
        try? await searchableIndex.indexItems(descriptors.map { $0.makeSearchableItem() })
      }
      pendingDeleteIdentifiers.formUnion(staleIdentifiers)
      pendingUpsertUris.subtract(batch)
    }
  }

  /// Resolves object URIs into descriptors on a background context —
  /// remote-deleted / system entities come back as identifiers to purge.
  private func buildDescriptors(objectUris: [String]) async
    -> (descriptors: [SpotlightEntityDescriptor], staleIdentifiers: [String]) {
    (try? await asyncStorage.performAndGet { [self] companion in
      var descriptors = [SpotlightEntityDescriptor]()
      var staleIdentifiers = [String]()
      for uri in objectUris {
        guard let url = URL(string: uri),
              let objectID = companion.context.persistentStoreCoordinator?
              .managedObjectID(forURIRepresentation: url),
              let object = try? companion.context.existingObject(with: objectID)
        else { continue }
        switch descriptorResult(for: object, library: companion.library) {
        case .descriptor(let descriptor):
          descriptors.append(descriptor)
        case .stale(let identifier):
          staleIdentifiers.append(identifier)
        case .skip:
          continue
        }
      }
      return (descriptors, staleIdentifiers)
    }) ?? ([], [])
  }

  // MARK: full reindex

  private func scheduleFullReindex() {
    guard fullReindexTask == nil else { return }
    fullReindexTask = Task { [weak self] in
      await self?.performFullReindex()
      await self?.finishFullReindex()
    }
  }

  private func finishFullReindex() {
    fullReindexTask = nil
  }

  /// test seam — lets unit tests await a scheduled full reindex without
  /// racing its background batches
  func awaitFullReindex() async {
    await fullReindexTask?.value
  }

  private func performFullReindex() async {
    os_log(
      "Spotlight: full reindex started",
      log: OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "Spotlight"),
      type: .info
    )
    for type in SpotlightItemType.allCases {
      let objectUris = await fetchAllObjectUris(of: type)
      for chunk in objectUris.chunked(intoSubarraySize: indexBatchSize) {
        guard isIndexingAllowed, !Task.isCancelled else { return }
        let (descriptors, staleIdentifiers) = await buildDescriptors(objectUris: chunk)
        if !descriptors.isEmpty {
          try? await searchableIndex.indexItems(descriptors.map { $0.makeSearchableItem() })
        }
        if !staleIdentifiers.isEmpty {
          try? await searchableIndex.deleteItems(identifiers: staleIdentifiers)
        }
        try? await Task.sleep(nanoseconds: 10_000_000) // yield between batches
      }
    }
    settings.app.hasCompletedInitialSpotlightIndex = true
    os_log(
      "Spotlight: full reindex finished",
      log: OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "Spotlight"),
      type: .info
    )
  }

  /// objectID URIs only — never fetch materialized MOs in bulk here
  /// (50k-track libraries); descriptors are built per batch.
  private func fetchAllObjectUris(of type: SpotlightItemType) async -> [String] {
    (try? await asyncStorage.performAndGet { companion in
      let fetchRequest = NSFetchRequest<NSManagedObjectID>(entityName: type.entityName)
      fetchRequest.resultType = .managedObjectIDResultType
      if type == .playlist {
        fetchRequest.predicate = PlaylistMO.excludeSystemPlaylistsFetchPredicate
      }
      return ((try? companion.context.fetch(fetchRequest)) ?? [])
        .map { $0.uriRepresentation().absoluteString }
    }) ?? []
  }

  // MARK: descriptor builders — run inside context.perform via buildDescriptors

  private enum DescriptorResult {
    case descriptor(SpotlightEntityDescriptor)
    /// entity must not be in the index — return its identifier for purge
    case stale(String)
    case skip
  }

  private nonisolated func descriptorResult(
    for object: NSManagedObject,
    library: LibraryStorage
  )
    -> DescriptorResult {
    switch object {
    case let mo as SongMO:
      return songDescriptor(mo)
    case let mo as PodcastEpisodeMO:
      return podcastEpisodeDescriptor(mo)
    case let mo as AlbumMO:
      return albumDescriptor(mo)
    case let mo as ArtistMO:
      return artistDescriptor(mo)
    case let mo as PlaylistMO:
      return playlistDescriptor(mo, library: library)
    case let mo as PodcastMO:
      return podcastDescriptor(mo)
    default:
      return .skip
    }
  }

  private nonisolated func makeIdentifier(
    _ type: SpotlightItemType,
    entity: AbstractLibraryEntity
  )
    -> SpotlightItemIdentifier? {
    guard !entity.id.isEmpty, let account = entity.account else { return nil }
    return SpotlightItemIdentifier(type: type, accountIdent: account.ident, id: entity.id)
  }

  /// remote-deleted entities keep MO rows around — they belong in the
  /// index as little as they belong in library lists
  private nonisolated func staleIfRemoteDeleted(
    _ entity: AbstractLibraryEntity,
    identifier: SpotlightItemIdentifier
  )
    -> DescriptorResult? {
    entity.remoteStatus == .deleted ? .stale(identifier.encoded) : nil
  }

  private nonisolated func thumbnailURL(for entity: AbstractLibraryEntity) -> URL? {
    guard let relPath = entity.artwork?.relFilePath,
          let absPath = fileManager.getAbsoluteAmperfyPath(relFilePath: relPath),
          FileManager.default.fileExists(atPath: absPath.path)
    else { return nil }
    return absPath
  }

  private nonisolated func joinedDescription(_ parts: String?...) -> String? {
    let joined = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
    return joined.isEmpty ? nil : joined
  }

  private nonisolated func songDescriptor(_ mo: SongMO) -> DescriptorResult {
    let song = Song(managedObject: mo)
    guard let identifier = makeIdentifier(.song, entity: song) else { return .skip }
    if let stale = staleIfRemoteDeleted(song, identifier: identifier) { return stale }
    return .descriptor(SpotlightEntityDescriptor(
      identifier: identifier,
      title: song.title,
      contentDescription: joinedDescription(song.artist?.name, song.album?.name),
      keywords: [song.title, song.artist?.name, song.album?.name, song.genre?.name]
        .compactMap { $0 },
      textContent: cachedLyricsText(for: song),
      rating: song.rating,
      playCount: song.playCount,
      lastUsedDate: song.lastTimePlayed,
      thumbnailFileURL: thumbnailURL(for: song),
      isAudioContent: true
    ))
  }

  private nonisolated func podcastEpisodeDescriptor(_ mo: PodcastEpisodeMO) -> DescriptorResult {
    let episode = PodcastEpisode(managedObject: mo)
    guard let identifier = makeIdentifier(.podcastEpisode, entity: episode) else { return .skip }
    if let stale = staleIfRemoteDeleted(episode, identifier: identifier) { return stale }
    return .descriptor(SpotlightEntityDescriptor(
      identifier: identifier,
      title: episode.title,
      contentDescription: joinedDescription(episode.podcast?.title),
      keywords: [episode.title, episode.podcast?.title].compactMap { $0 },
      textContent: nil,
      rating: episode.rating,
      playCount: episode.playCount,
      lastUsedDate: episode.lastTimePlayed,
      thumbnailFileURL: thumbnailURL(for: episode),
      isAudioContent: true
    ))
  }

  private nonisolated func albumDescriptor(_ mo: AlbumMO) -> DescriptorResult {
    let album = Album(managedObject: mo)
    guard let identifier = makeIdentifier(.album, entity: album) else { return .skip }
    if let stale = staleIfRemoteDeleted(album, identifier: identifier) { return stale }
    return .descriptor(SpotlightEntityDescriptor(
      identifier: identifier,
      title: album.name,
      contentDescription: joinedDescription(album.artist?.name, album.genre?.name),
      keywords: [album.name, album.artist?.name, album.genre?.name].compactMap { $0 },
      textContent: nil,
      rating: album.rating,
      playCount: album.playCount,
      lastUsedDate: album.lastTimePlayed,
      thumbnailFileURL: thumbnailURL(for: album),
      isAudioContent: false
    ))
  }

  private nonisolated func artistDescriptor(_ mo: ArtistMO) -> DescriptorResult {
    let artist = Artist(managedObject: mo)
    guard let identifier = makeIdentifier(.artist, entity: artist) else { return .skip }
    if let stale = staleIfRemoteDeleted(artist, identifier: identifier) { return stale }
    return .descriptor(SpotlightEntityDescriptor(
      identifier: identifier,
      title: artist.name,
      contentDescription: joinedDescription(artist.genre?.name),
      keywords: [artist.name, artist.genre?.name].compactMap { $0 },
      textContent: nil,
      rating: artist.rating,
      playCount: artist.playCount,
      lastUsedDate: artist.lastTimePlayed,
      thumbnailFileURL: thumbnailURL(for: artist),
      isAudioContent: false
    ))
  }

  private nonisolated func playlistDescriptor(
    _ mo: PlaylistMO,
    library: LibraryStorage
  )
    -> DescriptorResult {
    let playlist = Playlist(library: library, managedObject: mo)
    guard let account = playlist.account, !playlist.id.isEmpty else { return .skip }
    let identifier = SpotlightItemIdentifier(
      type: .playlist,
      accountIdent: account.ident,
      id: playlist.id
    )
    // player-queue mirror playlists are app-internal — keep them out
    let isSystemPlaylist = mo.playersContextPlaylist != nil ||
      mo.playersShuffledContextPlaylist != nil ||
      mo.playersUserQueuePlaylist != nil ||
      mo.playersPodcastPlaylist != nil
    guard !isSystemPlaylist else { return .stale(identifier.encoded) }
    return .descriptor(SpotlightEntityDescriptor(
      identifier: identifier,
      title: playlist.name,
      contentDescription: nil,
      keywords: [playlist.name],
      textContent: nil,
      rating: 0,
      playCount: playlist.playCount,
      lastUsedDate: playlist.lastTimePlayed,
      thumbnailFileURL: nil,
      isAudioContent: false
    ))
  }

  private nonisolated func podcastDescriptor(_ mo: PodcastMO) -> DescriptorResult {
    let podcast = Podcast(managedObject: mo)
    guard let identifier = makeIdentifier(.podcast, entity: podcast) else { return .skip }
    if let stale = staleIfRemoteDeleted(podcast, identifier: identifier) { return stale }
    return .descriptor(SpotlightEntityDescriptor(
      identifier: identifier,
      title: podcast.title,
      contentDescription: nil,
      keywords: [podcast.title],
      textContent: nil,
      rating: podcast.rating,
      playCount: podcast.playCount,
      lastUsedDate: podcast.lastTimePlayed,
      thumbnailFileURL: thumbnailURL(for: podcast),
      isAudioContent: false
    ))
  }

  /// Lyric text for `attributeSet.textContent`, disk-cache only — the
  /// indexer must never trigger a network fetch.
  /// 1. resolved `SyncedLyrics` JSON (`lyrics/synced/<md5(id)>.swlyrics.json`)
  /// 2. server lyrics XML cached at `Song.lyricsRelFilePath`
  private nonisolated func cachedLyricsText(for song: Song) -> String? {
    guard let account = song.account else { return nil }

    if let relPath = fileManager.createRelPathForSyncedLyricsCache(
      playableId: song.id,
      account: account.info
    ),
      let absPath = fileManager.getAbsoluteAmperfyPath(relFilePath: relPath),
      let data = fileManager.getFileDataIfNotToBig(url: absPath),
      let synced = try? JSONDecoder().decode(SyncedLyrics.self, from: data) {
      let text = synced.lines.map { $0.value }.joined(separator: "\n")
      if !text.isEmpty { return Self.cappedText(text) }
    }

    if let relPath = song.lyricsRelFilePath,
       let absPath = fileManager.getAbsoluteAmperfyPath(relFilePath: relPath),
       let parser = XMLParser(contentsOf: absPath) {
      let delegate = SsLyricsParserDelegate(performanceMonitor: performanceMonitor)
      parser.delegate = delegate
      parser.parse()
      if let structured = delegate.lyricsList?.getFirstSyncedLyricsOrUnsyncedAsDefault() {
        let text = structured.line.map { $0.value }.joined(separator: "\n")
        if !text.isEmpty { return Self.cappedText(text) }
      }
    }
    return nil
  }

  private nonisolated static func cappedText(_ text: String) -> String {
    text.count > lyricsTextMaxLength ? String(text.prefix(lyricsTextMaxLength)) : text
  }
}
