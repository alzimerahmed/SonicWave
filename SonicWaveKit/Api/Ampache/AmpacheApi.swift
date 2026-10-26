//
//  AmpacheApi.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 19.03.19.
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

import Foundation

final class AmpacheApi: BackendApi {
  private let ampacheXmlServerApi: AmpacheXmlServerApi
  private let networkMonitor: NetworkMonitorFacade
  private let performanceMonitor: ThreadPerformanceMonitor
  private let eventLogger: EventLogger

  init(
    ampacheXmlServerApi: AmpacheXmlServerApi,
    networkMonitor: NetworkMonitorFacade,
    performanceMonitor: ThreadPerformanceMonitor,
    eventLogger: EventLogger
  ) {
    self.ampacheXmlServerApi = ampacheXmlServerApi
    self.networkMonitor = networkMonitor
    self.performanceMonitor = performanceMonitor
    self.eventLogger = eventLogger
  }

  public var clientApiVersion: String {
    ampacheXmlServerApi.clientApiVersion
  }

  public var serverApiVersion: String { ampacheXmlServerApi.serverApiVersion.wrappedValue ?? "-" }

  public var httpHeaders: [String: String] {
    ampacheXmlServerApi.httpHeaders
  }

  func provideCredentials(credentials: LoginCredentials) {
    ampacheXmlServerApi.provideCredentials(credentials: credentials)
  }

  @MainActor
  func isAuthenticationValid(credentials: LoginCredentials) async throws {
    try await ampacheXmlServerApi.isAuthenticationValid(credentials: credentials)
  }

  @MainActor
  func generateUrl(forDownloadingPlayable playableInfo: AbstractPlayableInfo) async throws
    -> URL {
    try await ampacheXmlServerApi.generateUrlForDownloadingPlayable(
      isSong: playableInfo.type == .song,
      id: playableInfo.id
    )
  }

  func generateUrl(
    forStreamingPlayable playableInfo: AbstractPlayableInfo,
    maxBitrate: StreamingMaxBitratePreference,
    formatPreference: StreamingFormatPreference,
    timeOffset: Int? = nil
  ) async throws
    -> URL {
    // Ampache `stream` has no documented time-offset parameter —
    // `.notSupported` semantics: the caller keeps its engine-side seek,
    // nothing is emitted here (G17)
    try await ampacheXmlServerApi.generateUrlForStreamingPlayable(
      isSong: playableInfo.type == .song,
      id: playableInfo.id,
      maxBitrate: maxBitrate,
      formatPreference: formatPreference
    )
  }

  /// Ampache `stream` cannot be restarted at an arbitrary offset (G17)
  func isTranscodeOffsetSeekSupported() async -> Bool { false }

  func generateUrl(forArtwork artwork: Artwork) async throws -> URL {
    try await ampacheXmlServerApi.generateUrlForArtwork(artworkRemoteInfo: artwork.remoteInfo)
  }

  func checkForErrorResponse(response: APIDataResponse) -> ResponseError? {
    ampacheXmlServerApi.checkForErrorResponse(response: response)
  }

  @MainActor
  func createLibrarySyncer(account: Account, storage: PersistentStorage) -> LibrarySyncer {
    AmpacheLibrarySyncer(
      ampacheXmlServerApi: ampacheXmlServerApi, account: account,
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      storage: storage,
      eventLogger: eventLogger
    )
  }

  func createArtworkDownloadDelegate() -> DownloadManagerDelegate {
    AmpacheArtworkDownloadDelegate(
      ampacheXmlServerApi: ampacheXmlServerApi,
      networkMonitor: networkMonitor
    )
  }

  func extractArtworkInfoFromURL(urlString: String) -> ArtworkRemoteInfo? {
    AmpacheXmlServerApi.extractArtworkInfoFromURL(urlString: urlString)
  }

  func cleanse(url: URL?) -> CleansedURL {
    ampacheXmlServerApi.cleanse(url: url)
  }

  // MARK: Phase-8 discovery surface

  /// DTO-level response → delegate plumbing (mirrors SubsonicApi.parse)
  internal func parse<Delegate: AmpacheXmlParser>(
    response: APIDataResponse,
    delegate: Delegate
  ) throws {
    let parser = XMLParser(data: response.data)
    parser.delegate = delegate
    parser.parse()
    if let error = delegate.error {
      throw ResponseError.createFromAmpacheError(
        cleansedURL: response.url?.asCleansedURL(cleanser: ampacheXmlServerApi),
        error: error,
        data: response.data
      )
    }
  }

  /// Ampache answers "method not implemented / disabled" with typed errors
  /// — collapse them into `.notSupported` per the degraded-path contract.
  internal func unsupportedIfMissing<T: Sendable>(
    _ body: () async throws -> BackendFeatureResult<T>
  ) async throws -> BackendFeatureResult<T> {
    do {
      return try await body()
    } catch let error as ResponseError {
      switch error.asAmpacheError {
      case .missing, .depreciated, .accessDenied, .accessControlNotEnabled:
        return .notSupported
      default:
        throw error
      }
    }
  }

  func getArtistInfo(artistId: String) async throws -> BackendFeatureResult<ArtistInfo> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestArtistInfo(id: artistId)
      let delegate = AmpacheArtistInfoParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      return .supported(delegate.artistInfo)
    }
  }

  func getAlbumInfo(albumId: String) async throws -> BackendFeatureResult<AlbumInfo> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestAlbumInfo(id: albumId)
      let delegate = AmpacheAlbumInfoParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      return .supported(delegate.albumInfo)
    }
  }

  func getTopSongs(
    artistName: String,
    count: Int
  ) async throws -> BackendFeatureResult<[RemoteSongInfo]> {
    // Ampache has no per-artist top-songs endpoint in the XML API
    .notSupported
  }

  func getSimilarArtists(
    artistId: String,
    count: Int
  ) async throws -> BackendFeatureResult<[ArtistStub]> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestSimilarArtists(
        id: artistId,
        count: count
      )
      let delegate = AmpacheArtistInfoParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      return .supported(delegate.similarArtists)
    }
  }

  func getAlbums(
    fromYear: Int,
    toYear: Int,
    offset: Int,
    count: Int
  ) async throws -> BackendFeatureResult<[RemoteAlbumInfo]> {
    // no year-range album listing in the Ampache XML API — decade browse
    // falls back to the local mirror via SmartPlaylistCriteria
    .notSupported
  }

  func getShares() async throws -> BackendFeatureResult<[ShareDescription]> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestShares()
      let delegate = AmpacheSharesParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      return .supported(self.ampacheXmlServerApi.applyPublicUrlOverride(to: delegate.shares))
    }
  }

  func createShare(
    shareableType: ShareableType,
    shareableId: String,
    description: String?,
    expiresInDays: Int?
  ) async throws -> BackendFeatureResult<ShareDescription> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestShareCreate(
        objectType: shareableType.rawValue,
        objectId: shareableId,
        description: description,
        expiresInDays: expiresInDays
      )
      let delegate = AmpacheSharesParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      let shares = self.ampacheXmlServerApi.applyPublicUrlOverride(to: delegate.shares)
      guard let created = shares.first else {
        throw ResponseError(type: .xml, cleansedURL: nil, data: response.data)
      }
      return .supported(created)
    }
  }

  func updateShare(
    id: String,
    description: String?,
    expiresInDays: Int?
  ) async throws -> BackendFeatureResult<ShareDescription> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestShareEdit(
        id: id,
        description: description,
        expiresInDays: expiresInDays
      )
      let delegate = AmpacheSharesParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      let shares = self.ampacheXmlServerApi.applyPublicUrlOverride(to: delegate.shares)
      guard let updated = shares.first else {
        throw ResponseError(type: .xml, cleansedURL: nil, data: response.data)
      }
      return .supported(updated)
    }
  }

  func deleteShare(id: String) async throws -> BackendFeatureResult<Bool> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestShareDelete(id: id)
      try self.parse(
        response: response,
        delegate: AmpacheXmlParser(performanceMonitor: self.performanceMonitor)
      )
      return .supported(true)
    }
  }

  // MARK: G19 bookmarks — Ampache `bookmarks`/`bookmark_create`/
  // `bookmark_delete` (API6); position in seconds

  /// maps the playable type to Ampache's `object_type` — radios/streams
  /// cannot be bookmarked
  private static func bookmarkObjectType(of playableInfo: AbstractPlayableInfo) -> String? {
    switch playableInfo.type {
    case .song: return "song"
    case .podcastEpisode: return "podcast_episode"
    case .radio: return nil
    }
  }

  func getBookmarks() async throws -> BackendFeatureResult<[ServerBookmark]> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestBookmarks()
      let delegate = AmpacheBookmarksParserDelegate(
        performanceMonitor: self.performanceMonitor
      )
      try self.parse(response: response, delegate: delegate)
      return .supported(delegate.bookmarks)
    }
  }

  func createBookmark(
    playableInfo: AbstractPlayableInfo,
    positionSeconds: Int
  ) async throws -> BackendFeatureResult<Bool> {
    guard let objectType = Self.bookmarkObjectType(of: playableInfo) else { return .notSupported }
    return try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestBookmarkCreate(
        filter: playableInfo.id,
        type: objectType,
        positionSeconds: max(0, positionSeconds)
      )
      try self.parse(
        response: response,
        delegate: AmpacheXmlParser(performanceMonitor: self.performanceMonitor)
      )
      return .supported(true)
    }
  }

  func deleteBookmark(
    _ bookmark: ServerBookmark
  ) async throws -> BackendFeatureResult<Bool> {
    guard !bookmark.objectType.isEmpty else { return .notSupported }
    return try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestBookmarkDelete(
        filter: bookmark.id,
        type: bookmark.objectType
      )
      try self.parse(
        response: response,
        delegate: AmpacheXmlParser(performanceMonitor: self.performanceMonitor)
      )
      return .supported(true)
    }
  }

  // MARK: G11 localplay — Ampache's server-side player (needs a
  // configured localplay instance; accessDenied → `.notSupported`)

  func getJukeboxPlaylist() async throws -> BackendFeatureResult<JukeboxPlaylist> {
    try await unsupportedIfMissing {
      let response = try await self.ampacheXmlServerApi.requestLocalplaySongs()
      let delegate = AmpacheLocalplaySongsParserDelegate(
        performanceMonitor: self.performanceMonitor
      )
      try self.parse(response: response, delegate: delegate)
      // Ampache reports no transport state/gain/position in
      // `localplay_songs` — honest payload carries entries only
      return .supported(JukeboxPlaylist(isPlaying: false, entries: delegate.entries))
    }
  }

  func jukeboxControl(_ action: JukeboxAction) async throws -> BackendFeatureResult<Bool> {
    // map the shared action set onto Ampache `localplay` commands —
    // `.get`/`start`/`stop`/`skip`/`add`/`clear` translate; `.set`
    // (positional select) and `.setGain` (absolute volume; Ampache has
    // relative volume_up/down only) have no honest equivalent
    let requests: [(command: String, oid: String?, type: String?, clear: Bool?)]
    switch action {
    case .get:
      return getJukeboxPlaylist().map { _ in true }
    case .start:
      requests = [("play", nil, nil, nil)]
    case .stop:
      requests = [("stop", nil, nil, nil)]
    case let .skip(index, _):
      // Ampache `skip` accepts no index — usable only as next-track
      guard index >= 0 else { return .notSupported }
      requests = [("skip", nil, nil, nil)]
    case let .add(ids):
      guard !ids.isEmpty else { return .supported(true) }
      requests = ids.map { ("add", $0, "song", nil) }
    case .clear:
      requests = [("delete_all", nil, nil, nil)]
    case .set, .setGain:
      return .notSupported
    }
    return try await unsupportedIfMissing {
      for req in requests {
        let response = try await self.ampacheXmlServerApi.requestLocalplay(
          command: req.command,
          objectId: req.oid,
          objectType: req.type,
          clear: req.clear
        )
        try self.parse(
          response: response,
          delegate: AmpacheXmlParser(performanceMonitor: self.performanceMonitor)
        )
      }
      return .supported(true)
    }
  }

  // MARK: G23 music folders — Ampache catalogs are browse-only
  // (syncMusicFolders/syncIndexes); no catalog filter exists on the
  // library queries themselves → `.notSupported`

  func getMusicFolders() async throws -> BackendFeatureResult<[MusicFolderStub]> {
    .notSupported
  }

  func getSmartPlaylistCriteria(
    playlistId: String
  ) async throws -> BackendFeatureResult<SmartPlaylistCriteria> {
    // Ampache has no .nsp concept — local smart playlists only
    .notSupported
  }

  // dislike (#587): Ampache `flag` is already the favorites channel —
  // dislike is local-only on this backend too
  func setDislike(playableInfo: AbstractPlayableInfo) async throws -> DislikeResolution {
    .localOnly
  }

  func clearDislike(playableInfo: AbstractPlayableInfo) async throws -> DislikeResolution {
    .localOnly
  }
}
