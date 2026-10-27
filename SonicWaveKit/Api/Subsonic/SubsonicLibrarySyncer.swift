//
//  SubsonicLibrarySyncer.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 05.04.19.
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

import CoreData
import Foundation
import os.log

class SubsonicLibrarySyncer: CommonLibrarySyncer, LibrarySyncer {
  private let subsonicServerApi: SubsonicServerApi

  private static let maxItemCountToPollAtOnce: Int = 500
  /// cap for the delta resync window — beyond it a full sync is cheaper
  /// and guaranteed complete
  private static let maxDeltaAlbumFetchCount: Int = 2_000

  init(
    subsonicServerApi: SubsonicServerApi,
    account: Account,
    networkMonitor: NetworkMonitorFacade,
    performanceMonitor: ThreadPerformanceMonitor,
    storage: PersistentStorage,
    eventLogger: EventLogger
  ) {
    self.subsonicServerApi = subsonicServerApi
    super.init(
      account: account,
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      storage: storage,
      eventLogger: eventLogger
    )
  }

  @MainActor
  func syncInitial(statusNotifyier: SyncCallbacks?) async throws {
    // captured BEFORE any fetch — `markLibrarySyncFinished` stamps this
    // (minus a safety overlap) as the delta-sync marker, so albums
    // created server-side during the sync stay inside the next window
    let syncStartDate = Date()
    try await super.createCachedItemRepresentationsInCoreData(statusNotifyier: statusNotifyier)

    statusNotifyier?.notifySyncStarted(ofType: .genre, totalCount: 0)
    let genreResponse = try await subsonicServerApi.requestGenres()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = Account(
        managedObject: asyncCompanion.context
          .object(with: self.accountObjectId) as! AccountMO
      )
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: genreResponse,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsGenreParserDelegate(
        performanceMonitor: self.performanceMonitor,
        prefetch: prefetch,
        account: accountAsync,
        library: asyncCompanion.library,
        parseNotifier: statusNotifyier
      )
      try self.parse(
        response: genreResponse,
        delegate: parserDelegate,
        isThrowingErrorsAllowed: false
      )
    }

    statusNotifyier?.notifySyncStarted(ofType: .artist, totalCount: 0)
    let artistsResponse = try await subsonicServerApi.requestArtists()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: artistsResponse,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsArtistParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library,
        parseNotifier: statusNotifyier
      )
      try self.parse(
        response: artistsResponse,
        delegate: parserDelegate,
        isThrowingErrorsAllowed: false
      )
    }

    // Album table: on resync (`lastLibrarySyncDate` set) fetch only the
    // delta window via `getAlbumList2 type=newest` merged by server id —
    // falls back to a full paged sync when the window cannot be bounded
    var runFullAlbumSync = true
    if let lastSyncDate = account.lastLibrarySyncDate {
      statusNotifyier?.notifySyncStarted(ofType: .album, totalCount: 0)
      runFullAlbumSync = !(try await self.syncAlbumsDelta(
        lastSyncDate: lastSyncDate,
        statusNotifyier: statusNotifyier
      ))
    }
    if runFullAlbumSync {
      var pollCountArtist = 0
      storage.main.perform { companion in
        let accountAsync = companion.library.getAccount(managedObjectId: self.accountObjectId)
        let artists = companion.library.getArtists(for: accountAsync).filter { !$0.id.isEmpty }
        let albumCount = artists.reduce(0) { $0 + $1.remoteAlbumCount }
        pollCountArtist = max(
          1,
          Int(ceil(Double(albumCount) / Double(Self.maxItemCountToPollAtOnce)))
        )
      }
      statusNotifyier?.notifySyncStarted(ofType: .album, totalCount: pollCountArtist)
      try await withThrowingTaskGroup(of: Void.self) { taskGroup in
        for index in Array(0 ..< pollCountArtist) {
          taskGroup.addTask { @MainActor @Sendable in
            let albumsResponse = try await self.subsonicServerApi.requestAlbums(
              offset: index * Self.maxItemCountToPollAtOnce,
              count: Self.maxItemCountToPollAtOnce
            )
            try await self.storage.async.perform { asyncCompanion in
              let accountAsync = Account(
                managedObject: asyncCompanion.context
                  .object(with: self.accountObjectId) as! AccountMO
              )
              let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
              try self.parse(
                response: albumsResponse,
                delegate: idParserDelegate,
                isThrowingErrorsAllowed: false
              )
              let prefetch = asyncCompanion.library
                .getElements(account: accountAsync, prefetchIDs: idParserDelegate.prefetchIDs)

              let parserDelegate = SsAlbumParserDelegate(
                performanceMonitor: self.performanceMonitor, prefetch: prefetch,
                account: accountAsync,
                library: asyncCompanion.library,
                parseNotifier: statusNotifyier
              )
              parserDelegate.prefetch = prefetch
              try self.parse(
                response: albumsResponse,
                delegate: parserDelegate,
                isThrowingErrorsAllowed: false
              )
            }
            statusNotifyier?.notifyParsedObject(ofType: .album)
          }
        }
        try await taskGroup.waitForAll()
      }
    }

    // Dedupe by server id: page parses run on concurrent background
    // contexts (`AsyncCoreDataAccessWrapper` allocates a fresh context per
    // call) whose prefetches cannot see sibling inserts, so identical
    // server ids can be committed twice. Resolving must reparent songs —
    // deleting a duplicate album without `passOwnership` orphaned its
    // songs, which then spawned stub albums on later syncs (the visible
    // "duplicate albums after resync" defect).
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let artistDuplicates = asyncCompanion.library.findDuplicates(
        for: Artist.typeName,
        keyPathString: #keyPath(ArtistMO.id),
        account: accountAsync
      )
      asyncCompanion.library.resolveArtistsDuplicates(
        account: accountAsync,
        duplicates: artistDuplicates
      )
      let albumDuplicates = asyncCompanion.library.findDuplicates(
        for: Album.typeName,
        keyPathString: #keyPath(AlbumMO.id),
        account: accountAsync
      )
      asyncCompanion.library.resolveAlbumsDuplicates(
        account: accountAsync,
        duplicates: albumDuplicates
      )
    }

    statusNotifyier?.notifySyncStarted(ofType: .playlist, totalCount: 0)
    let playlistsResponse = try await subsonicServerApi.requestPlaylists()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = Account(
        managedObject: asyncCompanion.context
          .object(with: self.accountObjectId) as! AccountMO
      )
      let parserDelegate = SsPlaylistParserDelegate(
        performanceMonitor: self.performanceMonitor, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(
        response: playlistsResponse,
        delegate: parserDelegate,
        isThrowingErrorsAllowed: false
      )
      self.applyReadonlyPlaylistFlags(
        parserDelegate.readonlyPlaylistIds,
        account: accountAsync,
        library: asyncCompanion.library
      )
    }
    await syncSmartPlaylistCriteria()

    let isSupported = try await subsonicServerApi.requestServerPodcastSupport()
    if isSupported {
      statusNotifyier?.notifySyncStarted(ofType: .podcast, totalCount: 0)
      let podcastsResponse = try await subsonicServerApi.requestPodcasts()
      try await storage.async.perform { asyncCompanion in
        let accountAsync = Account(
          managedObject: asyncCompanion.context
            .object(with: self.accountObjectId) as! AccountMO
        )
        let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
        try self.parse(
          response: podcastsResponse,
          delegate: idParserDelegate,
          isThrowingErrorsAllowed: false
        )
        let prefetch = asyncCompanion.library.getElements(
          account: accountAsync,
          prefetchIDs: idParserDelegate.prefetchIDs
        )

        let parserDelegate = SsPodcastParserDelegate(
          performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
          library: asyncCompanion.library,
          parseNotifier: statusNotifyier
        )
        try self.parse(
          response: podcastsResponse,
          delegate: parserDelegate,
          isThrowingErrorsAllowed: false
        )
        parserDelegate.performPostParseOperations()
      }
    }

    // stamp at the actual finish point — also reached when the server
    // has no podcast support (the marker only feeds the album delta
    // window, so its placement is about completeness, not ordering)
    markLibrarySyncFinished(syncStartDate: syncStartDate)
  }

  /// Delta album resync (fix: "duplicate albums after resync").
  /// `getAlbumList2` has no `since` parameter — `type=newest` is the best
  /// windowed approximation: pages are fetched serially until the oldest
  /// album `created` timestamp falls at/below `lastSyncDate`. Each page is
  /// merged by server id via the prefetch pass, so re-parsed albums update
  /// the existing managed objects instead of spawning duplicates.
  /// Pages are parsed serially on purpose: `AsyncCoreDataAccessWrapper`
  /// allocates a fresh background context per `perform`, so concurrent
  /// page parsing cannot see sibling inserts and can commit the same
  /// server id twice.
  /// Returns `false` when the delta window cannot be bounded (server does
  /// not emit `created`, or more than `maxDeltaAlbumFetchCount` albums
  /// changed) — the caller must then run the full sync.
  @MainActor
  private func syncAlbumsDelta(
    lastSyncDate: Date,
    statusNotifyier: SyncCallbacks?
  ) async throws
    -> Bool {
    enum PageBoundary {
      case reachedSyncBoundary
      case continueFetching
      case cannotBoundWindow
    }

    var offset = 0
    while offset < Self.maxDeltaAlbumFetchCount {
      let albumsResponse = try await subsonicServerApi.requestNewestAlbums(
        offset: offset,
        count: Self.maxItemCountToPollAtOnce
      )
      let boundary = try await storage.async.performAndGet { asyncCompanion in
        let accountAsync = Account(
          managedObject: asyncCompanion.context
            .object(with: self.accountObjectId) as! AccountMO
        )
        let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
        try self.parse(
          response: albumsResponse,
          delegate: idParserDelegate,
          isThrowingErrorsAllowed: false
        )
        let prefetch = asyncCompanion.library
          .getElements(account: accountAsync, prefetchIDs: idParserDelegate.prefetchIDs)

        let parserDelegate = SsAlbumParserDelegate(
          performanceMonitor: self.performanceMonitor, prefetch: prefetch,
          account: accountAsync,
          library: asyncCompanion.library,
          parseNotifier: statusNotifyier
        )
        try self.parse(
          response: albumsResponse,
          delegate: parserDelegate,
          isThrowingErrorsAllowed: false
        )
        guard !parserDelegate.parsedAlbums.isEmpty else {
          return PageBoundary.reachedSyncBoundary // empty page -> list exhausted
        }
        let createdDates = parserDelegate.parsedAlbums
          .compactMap { parserDelegate.albumCreatedDates[$0.id] }
        guard !createdDates.isEmpty else {
          // server does not emit `created` -> window cannot be bounded
          return PageBoundary.cannotBoundWindow
        }
        return (createdDates.min() ?? Date()) <= lastSyncDate
          ? .reachedSyncBoundary : .continueFetching
      }

      switch boundary {
      case .reachedSyncBoundary:
        return true
      case .continueFetching:
        offset += Self.maxItemCountToPollAtOnce
      case .cannotBoundWindow:
        return false
      }
    }
    return false
  }

  @MainActor
  func sync(genre: Genre) async throws {
    guard isSyncAllowed else { return }
    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      genre.albums.forEach { album in
        taskGroup.addTask { @MainActor @Sendable in
          try await self.sync(album: album)
        }
      }
      try await taskGroup.waitForAll()
    }
  }

  @MainActor
  func sync(artist: Artist) async throws {
    guard isSyncAllowed, !artist.id.isEmpty, artist.remoteStatus != .deleted else { return }
    let artistObjectId = artist.managedObject.objectID

    func handleNotAvailableArtist(error: Error) async throws {
      try await storage.async.perform { asyncCompanion in
        if let responseError = error as? ResponseError,
           let subsonicError = responseError.asSubsonicError, !subsonicError.isRemoteAvailable {
          let artistAsync = Artist(
            managedObject: asyncCompanion.context
              .object(with: artistObjectId) as! ArtistMO
          )
          let reportError = ResponseError(
            type: .resource,
            statusCode: responseError.statusCode,
            message: "Artist \"\(artistAsync.name)\" is no longer available on the server.",
            cleansedURL: responseError.cleansedURL,
            data: responseError.data
          )
          artistAsync.remoteStatus = .deleted
          throw reportError
        }
      }
      throw error
    }

    var artistResponse: APIDataResponse?
    do {
      artistResponse = try await subsonicServerApi.requestArtist(id: artist.id)
    } catch {
      try await handleNotAvailableArtist(error: error)
    }
    guard let artistResponse else { return }

    do {
      try await storage.async.perform { asyncCompanion in
        let accountAsync = Account(
          managedObject: asyncCompanion.context
            .object(with: self.accountObjectId) as! AccountMO
        )
        let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
        try self.parse(
          response: artistResponse,
          delegate: idParserDelegate,
          isThrowingErrorsAllowed: false
        )
        let prefetch = asyncCompanion.library.getElements(
          account: accountAsync,
          prefetchIDs: idParserDelegate.prefetchIDs
        )

        let parserDelegate = SsArtistParserDelegate(
          performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
          library: asyncCompanion.library
        )
        try self.parse(response: artistResponse, delegate: parserDelegate)
      }
    } catch {
      try await handleNotAvailableArtist(error: error)
    }

    guard artist.remoteStatus == .available else { return }
    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      artist.albums.forEach { album in
        taskGroup.addTask { @MainActor @Sendable in
          try await self.sync(album: album)
        }
      }
      try await taskGroup.waitForAll()
    }
  }

  @MainActor
  func sync(album: Album) async throws {
    guard isSyncAllowed, album.remoteStatus != .deleted else { return }
    let albumObjectId = album.managedObject.objectID

    func handleNotAvailableAlbum(error: Error) async throws {
      try await storage.async.perform { asyncCompanion in
        if let responseError = error as? ResponseError,
           let subsonicError = responseError.asSubsonicError, !subsonicError.isRemoteAvailable {
          let albumAsync = Album(
            managedObject: asyncCompanion.context
              .object(with: albumObjectId) as! AlbumMO
          )
          let reportError = ResponseError(
            type: .resource,
            statusCode: responseError.statusCode,
            message: "Album \"\(albumAsync.name)\" is no longer available on the server.",
            cleansedURL: responseError.cleansedURL,
            data: responseError.data
          )
          albumAsync.markAsRemoteDeleted()
          throw reportError
        }
      }
      throw error
    }

    var albumResponse: APIDataResponse?
    do {
      albumResponse = try await subsonicServerApi.requestAlbum(id: album.id)
    } catch {
      try await handleNotAvailableAlbum(error: error)
    }
    guard let albumResponse else { return }

    do {
      try await storage.async.perform { asyncCompanion in
        let accountAsync = Account(
          managedObject: asyncCompanion.context
            .object(with: self.accountObjectId) as! AccountMO
        )
        let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
        try self.parse(
          response: albumResponse,
          delegate: idParserDelegate,
          isThrowingErrorsAllowed: false
        )
        let prefetch = asyncCompanion.library.getElements(
          account: accountAsync,
          prefetchIDs: idParserDelegate.prefetchIDs
        )

        let parserDelegate = SsAlbumParserDelegate(
          performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
          library: asyncCompanion.library
        )
        try self.parse(response: albumResponse, delegate: parserDelegate)
      }
    } catch {
      try await handleNotAvailableAlbum(error: error)
    }

    guard album.remoteStatus == .available else { return }
    try await storage.async.perform { asyncCompanion in
      let albumAsync = Album(
        managedObject: asyncCompanion.context
          .object(with: albumObjectId) as! AlbumMO
      )
      let accountAsync = Account(
        managedObject: asyncCompanion.context
          .object(with: self.accountObjectId) as! AccountMO
      )
      let oldSongs = Set(albumAsync.songs)

      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: albumResponse,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )
      let parserDelegate = SsSongParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: albumResponse, delegate: parserDelegate)
      let removedSongs = oldSongs.subtracting(parserDelegate.parsedSongs)
      removedSongs.lazy.compactMap { $0.asSong }.forEach {
        os_log("Song <%s> is remote deleted", log: self.log, type: .info, $0.displayString)
        $0.remoteStatus = .deleted
        albumAsync.managedObject.removeFromSongs($0.managedObject)
      }
      albumAsync.isCached = parserDelegate.isCollectionCached
      albumAsync.isSongsMetaDataSynced = true
    }
  }

  @MainActor
  func sync(song: Song) async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestSongInfo(id: song.id)
    try await storage.async.perform { asyncCompanion in
      let accountAsync = Account(
        managedObject: asyncCompanion.context
          .object(with: self.accountObjectId) as! AccountMO
      )
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsSongParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
    }
    try await syncLyrics(song: song)
  }

  @MainActor
  private func syncLyrics(song: Song) async throws {
    do {
      _ = try await fetchLyrics(song: song)
    } catch {
      // lyrics are optional — every failure path degrades silently
    }
  }

  /// G4: live `getLyricsBySongId` fetch — `songLyrics` extension-gated like
  /// the sync path. The raw XML is persisted to `Song.lyricsRelFilePath`
  /// (same as the old `syncLyrics`) so the plain-lyrics consumers
  /// (`LyricsVC`, `PlainDetailsVC`, `getCachedLyrics`) keep working.
  @MainActor
  func fetchLyrics(song: Song) async throws -> LyricsList {
    guard isSyncAllowed else { throw BackendError.notSupported }
    let isSupported = await subsonicServerApi
      .isOpenSubsonicExtensionSupported(extension: .songLyrics)
    guard isSupported else { throw BackendError.notSupported }
    let response = try await subsonicServerApi.requestLyricsBySongId(id: song.id)

    let parserDelegate = SsLyricsParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: parserDelegate, isThrowingErrorsAllowed: false)
    guard let lyricsList = parserDelegate.lyricsList, !lyricsList.lyrics.isEmpty else {
      os_log(
        "No lyrics available for <%s>",
        log: self.log,
        type: .info,
        song.displayString
      )
      throw ResponseError(type: .xml)
    }

    let songObjectId = song.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      guard let songAsyncMO = asyncCompanion.context.object(with: songObjectId) as? SongMO,
            let accountAsyncMO = asyncCompanion.context
            .object(with: self.accountObjectId) as? AccountMO
      else { return }
      let songAsync = Song(managedObject: songAsyncMO)
      let accountAsync = Account(managedObject: accountAsyncMO)

      guard let lyricsRelFilePath = self.fileManager.createRelPath(forLyricsOf: songAsync),
            let lyricsAbsFilePath = self.fileManager
            .getAbsoluteAmperfyPath(relFilePath: lyricsRelFilePath)
      else { return }

      // save xml response only if it contains valid lyrics
      do {
        try self.fileManager.writeDataExcludedFromBackup(
          data: response.data,
          to: lyricsAbsFilePath,
          accountInfo: accountAsync.info
        )
        songAsync.lyricsRelFilePath = lyricsRelFilePath
        os_log(
          "Lyrics found for <%s> and saved to: %s",
          log: self.log,
          type: .info,
          songAsync.displayString,
          lyricsRelFilePath.path
        )
      } catch {
        songAsync.lyricsRelFilePath = nil
      }
    }
    return lyricsList
  }

  @MainActor
  func sync(podcast: Podcast) async throws {
    guard isSyncAllowed, podcast.remoteStatus != .deleted else { return }
    let isSupported = try await subsonicServerApi.requestServerPodcastSupport()
    guard isSupported else { return }
    let podcastObjectId = podcast.managedObject.objectID

    func handleNotAvailablePodcast(podcastObjectId: NSManagedObjectID, error: Error) async throws {
      try await storage.async.perform { asyncCompanion in
        if let responseError = error as? ResponseError,
           let subsonicError = responseError.asSubsonicError, !subsonicError.isRemoteAvailable {
          let podcastAsync = Podcast(
            managedObject: asyncCompanion.context
              .object(with: podcastObjectId) as! PodcastMO
          )
          let reportError = ResponseError(
            type: .resource,
            statusCode: responseError.statusCode,
            message: "Podcast \"\(podcastAsync.name)\" is no longer available on the server.",
            cleansedURL: responseError.cleansedURL,
            data: responseError.data
          )
          podcastAsync.remoteStatus = .deleted
          throw reportError
        }
      }
      throw error
    }

    var podcastResponse: APIDataResponse?
    do {
      podcastResponse = try await subsonicServerApi.requestPodcastEpisodes(id: podcast.id)
    } catch {
      try await handleNotAvailablePodcast(podcastObjectId: podcastObjectId, error: error)
    }
    guard let podcastResponse else { return }

    do {
      try await storage.async.perform { asyncCompanion in
        let accountAsync = Account(
          managedObject: asyncCompanion.context
            .object(with: self.accountObjectId) as! AccountMO
        )
        let podcastAsync = Podcast(
          managedObject: asyncCompanion.context
            .object(with: podcastObjectId) as! PodcastMO
        )
        let oldEpisodes = Set(podcastAsync.episodes)

        let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
        try self.parse(
          response: podcastResponse,
          delegate: idParserDelegate,
          isThrowingErrorsAllowed: false
        )
        let prefetch = asyncCompanion.library.getElements(
          account: accountAsync,
          prefetchIDs: idParserDelegate.prefetchIDs
        )

        let parserDelegate = SsPodcastEpisodeParserDelegate(
          performanceMonitor: self.performanceMonitor,
          podcast: podcastAsync, prefetch: prefetch, account: accountAsync,
          library: asyncCompanion.library
        )
        try self.parse(response: podcastResponse, delegate: parserDelegate)
        parserDelegate.performPostParseOperations()

        let deletedEpisodes = oldEpisodes.subtracting(parserDelegate.parsedEpisodes)
        deletedEpisodes.forEach {
          os_log(
            "Podcast Episode <%s> is remote deleted",
            log: self.log,
            type: .info,
            $0.displayString
          )
          $0.podcastStatus = .deleted
        }
        podcastAsync.isCached = parserDelegate.isCollectionCached
      }
    } catch {
      try await handleNotAvailablePodcast(podcastObjectId: podcastObjectId, error: error)
    }
  }

  @MainActor
  func syncNewestPodcastEpisodes() async throws {
    guard isSyncAllowed else { return }
    os_log("Sync newest podcast episodes", log: log, type: .info)
    let isSupported = try await subsonicServerApi.requestServerPodcastSupport()
    guard isSupported else { return }
    try await syncDownPodcastsWithoutEpisodes()
    let response = try await subsonicServerApi.requestNewestPodcasts()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsPodcastEpisodeParserDelegate(
        performanceMonitor: self.performanceMonitor,
        podcast: nil, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      parserDelegate.performPostParseOperations()
    }
  }

  @MainActor
  func syncNewestAlbums(offset: Int, count: Int) async throws {
    guard isSyncAllowed else { return }
    os_log("Sync newest albums: offset: %i count: %i", log: log, type: .info, offset, count)
    let response = try await subsonicServerApi.requestNewestAlbums(offset: offset, count: count)
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsAlbumParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      let oldNewestAlbums = asyncCompanion.library.getNewestAlbums(
        for: accountAsync,
        offset: offset,
        count: count
      )
      oldNewestAlbums.forEach { $0.markAsNotNewAnymore() }
      parserDelegate.parsedAlbums.enumerated().forEach { index, album in
        album.updateIsNewestInfo(index: index + 1 + offset)
      }
    }
  }

  @MainActor
  func syncRecentAlbums(offset: Int, count: Int) async throws {
    guard isSyncAllowed else { return }
    os_log("Sync recent albums: offset: %i count: %i", log: log, type: .info, offset, count)
    let response = try await subsonicServerApi.requestRecentAlbums(offset: offset, count: count)
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsAlbumParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      let oldRecentAlbums = asyncCompanion.library.getRecentAlbums(
        for: accountAsync,
        offset: offset,
        count: count
      )
      oldRecentAlbums.forEach { $0.markAsNotRecentAnymore() }
      parserDelegate.parsedAlbums.enumerated().forEach { index, album in
        album.updateIsRecentInfo(index: index + 1 + offset)
      }
    }
  }

  @MainActor
  func syncFavoriteLibraryElements() async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestFavoriteElements()
    try await storage.async.perform { asyncCompanion in
      os_log("Sync favorite artists", log: self.log, type: .info)
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let oldFavoriteArtists = Set(asyncCompanion.library.getFavoriteArtists(for: accountAsync))
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )
      let parserDelegateArtist = SsArtistParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegateArtist)
      let notFavoriteArtistsAnymore = oldFavoriteArtists
        .subtracting(parserDelegateArtist.parsedArtists)
      notFavoriteArtistsAnymore.forEach { $0.isFavorite = false; $0.starredDate = nil }

      os_log("Sync favorite albums", log: self.log, type: .info)
      let oldFavoriteAlbums = Set(asyncCompanion.library.getFavoriteAlbums(for: accountAsync))
      let parserDelegateAlbum = SsAlbumParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegateAlbum)
      let notFavoriteAlbumsAnymore = oldFavoriteAlbums.subtracting(parserDelegateAlbum.parsedAlbums)
      notFavoriteAlbumsAnymore.forEach { $0.isFavorite = false; $0.starredDate = nil }

      os_log("Sync favorite songs", log: self.log, type: .info)
      let oldFavoriteSongs = Set(asyncCompanion.library.getFavoriteSongs(for: accountAsync))
      let parserDelegateSong = SsSongParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegateSong)
      let notFavoriteSongsAnymore = oldFavoriteSongs.subtracting(parserDelegateSong.parsedSongs)
      notFavoriteSongsAnymore.forEach { $0.isFavorite = false; $0.starredDate = nil }
    }
  }

  @MainActor
  func syncRadios() async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestRadios()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let oldRadios = Set(asyncCompanion.library.getRadios(for: accountAsync))

      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsRadioParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)

      let deletedRadios = oldRadios.subtracting(parserDelegate.parsedRadios)
      deletedRadios.forEach {
        os_log("Radio <%s> is remote deleted", log: self.log, type: .info, $0.displayString)
        $0.remoteStatus = .deleted
      }
    }
  }

  @MainActor
  func syncMusicFolders() async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestMusicFolders()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsMusicFolderParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
    }
  }

  @MainActor
  func syncIndexes(musicFolder: MusicFolder) async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestIndexes(musicFolderId: musicFolder.id)
    let musicFolderObjectId = musicFolder.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let musicFolderAsync = MusicFolder(
        managedObject: asyncCompanion.context
          .object(with: musicFolderObjectId) as! MusicFolderMO
      )
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsDirectoryParserDelegate(
        performanceMonitor: self.performanceMonitor,
        musicFolder: musicFolderAsync, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      musicFolderAsync.isCached = parserDelegate.isCollectionCached
    }
  }

  @MainActor
  func sync(directory: Directory) async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestMusicDirectory(id: directory.id)
    let directoryObjectId = directory.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let directoryAsync = Directory(
        managedObject: asyncCompanion.context
          .object(with: directoryObjectId) as! DirectoryMO
      )
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsDirectoryParserDelegate(
        performanceMonitor: self.performanceMonitor,
        directory: directoryAsync, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      directoryAsync.isCached = parserDelegate.isCollectionCached
    }
  }

  @MainActor
  func requestRandomSongs(playlist: Playlist, count: Int) async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestRandomSongs(count: count)
    let playlistObjectId = playlist.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsSongParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      let playlistAsync = Playlist(
        library: asyncCompanion.library,
        managedObject: asyncCompanion.context.object(with: playlistObjectId) as! PlaylistMO
      )
      playlistAsync.append(playables: parserDelegate.parsedSongs)
    }
  }

  @MainActor
  func requestSimilarSongs(song: Song, count: Int) async throws -> [Song] {
    guard isSyncAllowed else { return [] }
    let response = try await subsonicServerApi.requestSimilarSongs(id: song.id, count: count)

    let similarSongObjectIds: [NSManagedObjectID] = try await storage.async.performAndGet {
      asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsSongParserDelegate(
        performanceMonitor: self.performanceMonitor,
        prefetch: prefetch,
        account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      return parserDelegate.parsedSongs.compactMap { $0.managedObject.objectID }
    }

    return try similarSongObjectIds.map {
      Song(managedObject: try storage.main.context.existingObject(with: $0) as! SongMO)
    }
  }

  @MainActor
  func requestPodcastEpisodeDelete(podcastEpisode: PodcastEpisode) async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestPodcastEpisodeDelete(id: podcastEpisode.id)
    try parseForError(response: response)
  }

  @MainActor
  func syncDownPlaylistsWithoutSongs() async throws {
    guard isSyncAllowed else { return }
    let response = try await subsonicServerApi.requestPlaylists()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let parserDelegate = SsPlaylistParserDelegate(
        performanceMonitor: self.performanceMonitor, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      self.applyReadonlyPlaylistFlags(
        parserDelegate.readonlyPlaylistIds,
        account: accountAsync,
        library: asyncCompanion.library
      )
    }
    await syncSmartPlaylistCriteria()
  }

  @MainActor
  func syncDown(playlist: Playlist) async throws {
    guard isSyncAllowed, playlist.id != "" else { return }
    os_log("Playlist \"%s\": Download songs from server", log: self.log, type: .info, playlist.name)
    let response = try await subsonicServerApi.requestPlaylistSongs(id: playlist.id)

    os_log("Playlist \"%s\": Parse songs start", log: self.log, type: .info, playlist.name)
    let playlistObjectId = playlist.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let playlistAsync = Playlist(
        library: asyncCompanion.library,
        managedObject: asyncCompanion.context.object(with: playlistObjectId) as! PlaylistMO
      )

      let idsParserDelegate = SsIDsParserDelegate(
        performanceMonitor: self.performanceMonitor
      )
      try self.parse(response: response, delegate: idsParserDelegate)
      let prefetch = asyncCompanion.library
        .getElements(account: accountAsync, prefetchIDs: idsParserDelegate.prefetchIDs)

      let parserDelegate = SsPlaylistSongsParserDelegate(
        performanceMonitor: self.performanceMonitor,
        playlist: playlistAsync, account: accountAsync,
        library: asyncCompanion.library, prefetch: prefetch
      )
      try self.parse(response: response, delegate: parserDelegate)
      playlistAsync.isCached = parserDelegate.isCollectionCached
      os_log(
        "Playlist \"%s\": Parse songs (%i) done",
        log: self.log,
        type: .info,
        playlistAsync.name,
        parserDelegate.parsedCount
      )
    }
  }

  @MainActor
  private func validatePlaylistId(playlist: Playlist) async throws {
    if playlist.id == "" {
      try await createPlaylistRemote(playlist: playlist)
    }
    if playlist.id == "" {
      os_log("Playlist id was not assigned after creation", log: self.log, type: .info)
      throw BackendError
        .incorrectServerBehavior(message: "Playlist id was not assigned after creation")
    }
  }

  @MainActor
  func syncUpload(playlistToUpdateName playlist: Playlist) async throws {
    guard isSyncAllowed else { return }
    os_log("Upload name on playlist to: \"%s\"", log: log, type: .info, playlist.name)
    try await validatePlaylistId(playlist: playlist)
    let response = try await subsonicServerApi.requestPlaylistUpdate(
      id: playlist.id,
      name: playlist.name,
      songIndicesToRemove: [],
      songIdsToAdd: []
    )
    try parseForError(response: response)
  }

  @MainActor
  func syncUpload(playlistToAddSongs playlist: Playlist, songs: [Song]) async throws {
    guard isSyncAllowed, !songs.isEmpty else { return }
    os_log("Upload SongsAdded on playlist \"%s\"", log: log, type: .info, playlist.name)
    try await validatePlaylistId(playlist: playlist)
    let response = try await subsonicServerApi.requestPlaylistUpdate(
      id: playlist.id,
      name: playlist.name,
      songIndicesToRemove: [],
      songIdsToAdd: songs.compactMap { $0.id }
    )
    try parseForError(response: response)
  }

  @MainActor
  func syncUpload(playlistToDeleteSong playlist: Playlist, index: Int) async throws {
    guard isSyncAllowed else { return }
    os_log(
      "Upload SongDelete on playlist \"%s\" at index: %i",
      log: log,
      type: .info,
      playlist.name,
      index
    )
    try await validatePlaylistId(playlist: playlist)
    let response = try await subsonicServerApi.requestPlaylistUpdate(
      id: playlist.id,
      name: playlist.name,
      songIndicesToRemove: [index],
      songIdsToAdd: []
    )
    try parseForError(response: response)
  }

  @MainActor
  func syncUpload(playlistToUpdateOrder playlist: Playlist) async throws {
    guard isSyncAllowed else { return }
    os_log("Upload OrderChange on playlist \"%s\"", log: log, type: .info, playlist.name)
    try await validatePlaylistId(playlist: playlist)
    let songIdsToAdd = playlist.playables.compactMap { $0.id }
    let songIndicesToRemove = Array(0 ..< songIdsToAdd.count)
    let response = try await subsonicServerApi.requestPlaylistUpdate(
      id: playlist.id,
      name: playlist.name,
      songIndicesToRemove: songIndicesToRemove,
      songIdsToAdd: songIdsToAdd
    )
    try parseForError(response: response)
  }

  @MainActor
  func syncUpload(playlistIdToDelete id: String) async throws {
    guard isSyncAllowed else { return }
    os_log("Upload Delete playlist \"%s\"", log: log, type: .info, id)
    let response = try await subsonicServerApi.requestPlaylistDelete(id: id)
    try parseForError(response: response)
  }

  /// G9: push the local play queue snapshot to the server
  /// (`savePlayQueue`). Only song ids are mirrored; podcast/radio items
  /// have no server representation and are skipped upstream.
  @MainActor
  func syncUpload(playQueue: PlayQueueSnapshot) async throws {
    // no silent no-op: `PlayQueueSyncer` clears `isPlayQueueDirty` only
    // after a real upload — a suppressed upload must surface as an
    // error so the dirty flag survives for the reconnect flush
    guard isSyncAllowed else {
      throw ResponseError(
        type: .api,
        message: "Play queue upload skipped: server sync is not allowed"
      )
    }
    // capability gate (API < 1.12.0): degrade to the Ampache-style
    // no-op — the queue can never be mirrored, so keeping the dirty
    // flag set would only error every sync attempt
    guard try await subsonicServerApi.isServerPlayQueueSupported() else { return }
    os_log(
      "Save play queue on server: %i songs",
      log: self.log,
      type: .info,
      playQueue.songIds.count
    )
    let response = try await subsonicServerApi.requestSavePlayQueue(
      songIds: playQueue.songIds,
      currentSongId: playQueue.currentSongId,
      positionInMilliseconds: playQueue.positionInMilliseconds
    )
    try parseForError(response: response)
  }

  /// G9: fetch the server-side play queue (`getPlayQueue`). Entries are
  /// returned as ordered server song ids — resolution to local Song
  /// entities happens in `PlayQueueSyncer` (unknown ids are skipped,
  /// never stub-inserted).
  @MainActor
  func syncDownRemotePlayQueue() async throws -> RemotePlayQueue? {
    guard isSyncAllowed else { return nil }
    // capability gate: `getPlayQueue` requires API >= 1.12.0 — without
    // the check every startup pull errors on older servers
    guard try await subsonicServerApi.isServerPlayQueueSupported() else { return nil }
    let response = try await subsonicServerApi.requestPlayQueue()
    let parserDelegate = SsPlayQueueParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: parserDelegate)
    return parserDelegate.remotePlayQueue
  }

  @MainActor
  func syncDownPodcastsWithoutEpisodes() async throws {
    guard isSyncAllowed else { return }
    let isSupported = try await subsonicServerApi.requestServerPodcastSupport()
    guard isSupported else { return }

    let response = try await subsonicServerApi.requestPodcasts()
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let oldPodcasts = Set(asyncCompanion.library.getRemoteAvailablePodcasts(for: accountAsync))

      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsPodcastParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
      parserDelegate.performPostParseOperations()

      let deletedPodcasts = oldPodcasts.subtracting(parserDelegate.parsedPodcasts)
      deletedPodcasts.forEach {
        os_log("Podcast <%s> is remote deleted", log: self.log, type: .info, $0.title)
        $0.remoteStatus = .deleted
      }
    }
  }

  @MainActor
  func syncNowPlaying(song: Song, songPosition: NowPlayingSongPosition) async throws {
    guard isSyncAllowed else { return }
    switch songPosition {
    case .start:
      return try await scrobble(song: song, submission: false)
    case .end:
      return try await scrobble(song: song, submission: true)
    }
  }

  @MainActor
  func scrobble(song: Song, date: Date?) async throws {
    try await scrobble(song: song, submission: true, date: date)
  }

  @MainActor
  private func scrobble(song: Song, submission: Bool, date: Date? = nil) async throws {
    guard isSyncAllowed else { return }
    if !submission {
      os_log("Now Playing Begin: %s", log: log, type: .info, song.displayString)
    } else if let date = date {
      os_log("Scrobbled at %s: %s", log: log, type: .info, date.description, song.displayString)
    } else {
      os_log("Now Playing End (Scrobble): %s", log: log, type: .info, song.displayString)
    }
    let response = try await subsonicServerApi.requestScrobble(
      id: song.id,
      submission: submission,
      date: date
    )
    try parseForError(response: response)
  }

  @MainActor
  func setRating(song: Song, rating: Int) async throws {
    guard isSyncAllowed, rating >= 0, rating <= 5 else { return }
    os_log("Rate %i stars: %s", log: log, type: .info, rating, song.displayString)
    let response = try await subsonicServerApi.requestRating(id: song.id, rating: rating)
    try parseForError(response: response)
  }

  @MainActor
  func setRating(album: Album, rating: Int) async throws {
    guard isSyncAllowed, rating >= 0, rating <= 5 else { return }
    os_log("Rate %i stars: %s", log: log, type: .info, rating, album.name)
    let response = try await subsonicServerApi.requestRating(id: album.id, rating: rating)
    try parseForError(response: response)
  }

  @MainActor
  func setRating(artist: Artist, rating: Int) async throws {
    guard isSyncAllowed, rating >= 0, rating <= 5 else { return }
    os_log("Rate %i stars: %s", log: log, type: .info, rating, artist.name)
    let response = try await subsonicServerApi.requestRating(id: artist.id, rating: rating)
    try parseForError(response: response)
  }

  @MainActor
  func setFavorite(song: Song, isFavorite: Bool) async throws {
    guard isSyncAllowed else { return }
    os_log(
      "Set Favorite %s: %s",
      log: log,
      type: .info,
      isFavorite ? "TRUE" : "FALSE",
      song.displayString
    )
    let response = try await subsonicServerApi.requestSetFavorite(
      songId: song.id,
      isFavorite: isFavorite
    )
    try parseForError(response: response)
  }

  @MainActor
  func setFavorite(album: Album, isFavorite: Bool) async throws {
    guard isSyncAllowed else { return }
    os_log("Set Favorite %s: %s", log: log, type: .info, isFavorite ? "TRUE" : "FALSE", album.name)
    let response = try await subsonicServerApi.requestSetFavorite(
      albumId: album.id,
      isFavorite: isFavorite
    )
    try parseForError(response: response)
  }

  @MainActor
  func setFavorite(artist: Artist, isFavorite: Bool) async throws {
    guard isSyncAllowed else { return }
    os_log("Set Favorite %s: %s", log: log, type: .info, isFavorite ? "TRUE" : "FALSE", artist.name)
    let response = try await subsonicServerApi.requestSetFavorite(
      artistId: artist.id,
      isFavorite: isFavorite
    )
    try parseForError(response: response)
  }

  @MainActor
  func searchArtists(searchText: String) async throws {
    guard isSyncAllowed, !searchText.isEmpty else { return }
    os_log("Search artists via API: \"%s\"", log: log, type: .info, searchText)
    let response = try await subsonicServerApi.requestSearchArtists(searchText: searchText)
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsArtistParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
    }
  }

  @MainActor
  func searchAlbums(searchText: String) async throws {
    guard isSyncAllowed, !searchText.isEmpty else { return }
    os_log("Search albums via API: \"%s\"", log: log, type: .info, searchText)
    let response = try await subsonicServerApi.requestSearchAlbums(searchText: searchText)
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsAlbumParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
    }
  }

  @MainActor
  func searchSongs(searchText: String) async throws {
    guard isSyncAllowed, !searchText.isEmpty else { return }
    os_log("Search songs via API: \"%s\"", log: log, type: .info, searchText)
    let response = try await subsonicServerApi.requestSearchSongs(searchText: searchText)
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsSongParserDelegate(
        performanceMonitor: self.performanceMonitor, prefetch: prefetch, account: accountAsync,
        library: asyncCompanion.library
      )
      try self.parse(response: response, delegate: parserDelegate)
    }
  }

  @MainActor
  func parseLyrics(relFilePath: URL) async throws -> LyricsList {
    let parserDelegate = SsLyricsParserDelegate(performanceMonitor: performanceMonitor)
    guard let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath) else {
      throw ResponseError(type: .xml)
    }
    do {
      try parse(absFilePath: absFilePath, delegate: parserDelegate, isThrowingErrorsAllowed: false)
    } catch {
      throw ResponseError(type: .xml)
    }
    guard let lyricsList = parserDelegate.lyricsList else {
      throw ResponseError(type: .xml)
    }
    return lyricsList
  }

  @MainActor
  private func createPlaylistRemote(playlist: Playlist) async throws {
    os_log("Create playlist on server", log: log, type: .info)
    let response = try await subsonicServerApi.requestPlaylistCreate(name: playlist.name)
    let playlistObjectId = playlist.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let playlistAsync = Playlist(
        library: asyncCompanion.library,
        managedObject: asyncCompanion.context.object(with: playlistObjectId) as! PlaylistMO
      )

      let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(
        response: response,
        delegate: idParserDelegate,
        isThrowingErrorsAllowed: false
      )
      let prefetch = asyncCompanion.library.getElements(
        account: accountAsync,
        prefetchIDs: idParserDelegate.prefetchIDs
      )

      let parserDelegate = SsPlaylistSongsParserDelegate(
        performanceMonitor: self.performanceMonitor,
        playlist: playlistAsync, account: accountAsync,
        library: asyncCompanion.library, prefetch: prefetch
      )
      try self.parse(response: response, delegate: parserDelegate)
    }
    // Old api version -> need to match the created playlist via name
    if playlist.id == "" {
      try await updatePlaylistIdViaItsName(playlist: playlist)
    }
  }

  @MainActor
  private func updatePlaylistIdViaItsName(playlist: Playlist) async throws {
    try await syncDownPlaylistsWithoutSongs()
    let playlistObjectId = playlist.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let playlistAsync = Playlist(
        library: asyncCompanion.library,
        managedObject: asyncCompanion.context.object(with: playlistObjectId) as! PlaylistMO
      )
      let playlists = asyncCompanion.library.getPlaylists(for: accountAsync)
      let nameMatchingPlaylists = playlists.filter { filterPlaylist in
        filterPlaylist.name == playlistAsync.name && filterPlaylist.id != ""
      }
      guard !nameMatchingPlaylists.isEmpty,
            let firstMatch = nameMatchingPlaylists.first else { return }
      let matchedId = firstMatch.id
      asyncCompanion.library.deletePlaylist(firstMatch)
      playlistAsync.id = matchedId
    }
  }

  private func parseForError(response: APIDataResponse) throws {
    let parserDelegate = SsPingParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: parserDelegate)
  }

  nonisolated private func parse(
    response: APIDataResponse,
    delegate: SsXmlParser,
    isThrowingErrorsAllowed: Bool = true
  ) throws {
    let parser = XMLParser(data: response.data)
    parser.delegate = delegate
    parser.parse()
    if let error = parser.parserError, isThrowingErrorsAllowed {
      os_log(
        "Error during response parsing: %s",
        log: self.log,
        type: .error,
        error.localizedDescription
      )
      throw ResponseError(
        type: .xml,
        cleansedURL: response.url?.asCleansedURL(cleanser: subsonicServerApi),
        data: response.data
      )
    }
    if let error = delegate.error, let _ = error.subsonicError, isThrowingErrorsAllowed {
      throw ResponseError.createFromSubsonicError(
        cleansedURL: response.url?.asCleansedURL(cleanser: subsonicServerApi),
        error: error,
        data: response.data
      )
    }
  }

  /// G8 (CoreDataMigrationVersion v51): persists the server `readonly`
  /// flag captured by `SsPlaylistParserDelegate` — Navidrome's marker for
  /// `.nsp`-backed smart playlists. Clears the flag on playlists the
  /// server no longer reports readonly and marks readonly playlists smart;
  /// the criteria themselves are fetched by `syncSmartPlaylistCriteria`
  /// and persisted as `smartCriteriaJson`.
  /// (Ampache exposes no equivalent marker — nothing wired there.)
  nonisolated private func applyReadonlyPlaylistFlags(
    _ readonlyPlaylistIds: Set<String>,
    account: Account,
    library: LibraryStorage
  ) {
    for playlist in library.getPlaylists(for: account) {
      let isServerReadOnly = readonlyPlaylistIds.contains(playlist.id)
      playlist.isServerReadOnly = isServerReadOnly
      if isServerReadOnly {
        playlist.isSmartPlaylist = true
      } else if !playlist.id.hasPrefix(Playlist.smartPlaylistIdPrefix) {
        // server no longer reports the playlist readonly — it is a plain
        // playlist again (`smart_`-prefixed locally-authored ones stay smart)
        playlist.isSmartPlaylist = false
      }
    }
  }

  /// G8: fetches the `.nsp` criteria of every server-readonly playlist via
  /// the Navidrome native API (`requestSmartPlaylistRules` — gated on
  /// `isNavidromeServer` internally) and persists them as
  /// `smartCriteriaJson`. Runs after `applyReadonlyPlaylistFlags` so the
  /// readonly set is fresh. Every failure degrades silently — a broken
  /// `.nsp` must never fail the surrounding playlist sync; the playlist
  /// stays playable via its server-resolved song list.
  @MainActor
  private func syncSmartPlaylistCriteria() async {
    guard subsonicServerApi.isNavidromeServer else { return }
    let readonlyPlaylistIds =
      (try? await storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(
          managedObjectId: self.accountObjectId
        )
        return Set(
          asyncCompanion.library.getPlaylists(for: accountAsync)
            .filter { $0.isServerReadOnly }
            .map { $0.id }
        )
      }) ?? Set<String>()
    guard !readonlyPlaylistIds.isEmpty else { return }

    var criteriaByPlaylistId = [String: SmartPlaylistCriteria]()
    for playlistId in readonlyPlaylistIds {
      do {
        guard let rulesData = try await subsonicServerApi.requestSmartPlaylistRules(
          playlistId: playlistId
        ),
          let parsed = NspCriteriaParser.parse(data: rulesData)
        else { continue }
        criteriaByPlaylistId[playlistId] = parsed.criteria
      } catch {
        os_log(
          "Smart playlist criteria fetch failed for playlist %s: %s",
          log: self.log,
          type: .info,
          playlistId,
          error.localizedDescription
        )
      }
    }
    guard !criteriaByPlaylistId.isEmpty else { return }

    try? await storage.async.perform { asyncCompanion in
      let accountAsync = asyncCompanion.library.getAccount(
        managedObjectId: self.accountObjectId
      )
      for playlist in asyncCompanion.library.getPlaylists(for: accountAsync)
      where readonlyPlaylistIds.contains(playlist.id) {
        // failed/absent fetches keep prior criteria — a nil-assign would wipe
        // good rules (and via the setter also clear isSmartPlaylist)
        if let criteria = criteriaByPlaylistId[playlist.id] {
          playlist.smartCriteria = criteria
        }
      }
    }
  }

  nonisolated private func parse(
    absFilePath: URL,
    delegate: SsXmlParser,
    isThrowingErrorsAllowed: Bool = true
  ) throws {
    guard let parser = XMLParser(contentsOf: absFilePath) else {
      throw ResponseError(type: .xml)
    }
    parser.delegate = delegate
    parser.parse()
    if let error = parser.parserError, isThrowingErrorsAllowed {
      os_log(
        "Error during response parsing: %s",
        log: self.log,
        type: .error,
        error.localizedDescription
      )
      throw ResponseError(type: .xml)
    }
    if let error = delegate.error, let _ = error.subsonicError, isThrowingErrorsAllowed {
      throw ResponseError(type: .xml)
    }
  }
}
