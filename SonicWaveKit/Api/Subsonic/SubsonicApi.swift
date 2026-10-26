//
//  SubsonicApi.swift
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

import Foundation
import os.log

// MARK: - SubsonicApi

final class SubsonicApi {
  private let subsonicServerApi: SubsonicServerApi
  private let networkMonitor: NetworkMonitorFacade
  private let performanceMonitor: ThreadPerformanceMonitor
  private let eventLogger: EventLogger

  init(
    subsonicServerApi: SubsonicServerApi,
    networkMonitor: NetworkMonitorFacade,
    performanceMonitor: ThreadPerformanceMonitor,
    eventLogger: EventLogger
  ) {
    self.subsonicServerApi = subsonicServerApi
    self.networkMonitor = networkMonitor
    self.performanceMonitor = performanceMonitor
    self.eventLogger = eventLogger
  }

  @MainActor
  var authType: SubsonicApiAuthType { subsonicServerApi.authType.wrappedValue }

  @MainActor
  func setAuthType(newAuthType: SubsonicApiAuthType) {
    subsonicServerApi.setAuthType(newAuthType: newAuthType)
  }
}

// MARK: BackendApi

extension SubsonicApi: BackendApi {
  public var clientApiVersion: String {
    subsonicServerApi.clientApiVersion.wrappedValue?.description ?? "-"
  }

  public var serverApiVersion: String {
    subsonicServerApi.serverApiVersion.wrappedValue?.description ?? "-"
  }

  public var httpHeaders: [String: String] {
    subsonicServerApi.httpHeaders
  }

  func provideCredentials(credentials: LoginCredentials) {
    subsonicServerApi.provideCredentials(credentials: credentials)
  }

  func isAuthenticationValid(credentials: LoginCredentials) async throws {
    try await subsonicServerApi.isAuthenticationValid(credentials: credentials)
  }

  func generateUrl(forDownloadingPlayable playableInfo: AbstractPlayableInfo) async throws
    -> URL {
    let apiId = playableInfo.streamId ?? playableInfo.id
    return try await subsonicServerApi.generateUrl(forDownloadingPlayableId: apiId)
  }

  func generateUrl(
    forStreamingPlayable playableInfo: AbstractPlayableInfo,
    maxBitrate: StreamingMaxBitratePreference,
    formatPreference: StreamingFormatPreference,
    timeOffset: Int? = nil
  ) async throws
    -> URL {
    let apiId = playableInfo.streamId ?? playableInfo.id
    return try await subsonicServerApi.generateUrl(
      forStreamingPlayableId: apiId,
      maxBitrate: maxBitrate,
      formatPreference: formatPreference,
      timeOffset: timeOffset
    )
  }

  /// G17 — the server itself advertises `transcodeOffset` support via
  /// `getOpenSubsonicExtensions`
  func isTranscodeOffsetSeekSupported() async -> Bool {
    await subsonicServerApi.isOpenSubsonicExtensionSupported(extension: .transcodeOffset)
  }

  func generateUrl(forArtwork artwork: Artwork) async throws -> URL {
    try await subsonicServerApi.generateUrl(forArtworkId: artwork.id)
  }

  func checkForErrorResponse(response: APIDataResponse) -> ResponseError? {
    subsonicServerApi.checkForErrorResponse(response: response)
  }

  @MainActor
  func createLibrarySyncer(account: Account, storage: PersistentStorage) -> LibrarySyncer {
    SubsonicLibrarySyncer(
      subsonicServerApi: subsonicServerApi, account: account,
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      storage: storage,
      eventLogger: eventLogger
    )
  }

  func createArtworkDownloadDelegate() -> DownloadManagerDelegate {
    SubsonicArtworkDownloadDelegate(
      subsonicServerApi: subsonicServerApi,
      networkMonitor: networkMonitor
    )
  }

  func extractArtworkInfoFromURL(urlString: String) -> ArtworkRemoteInfo? {
    SubsonicServerApi.extractArtworkInfoFromURL(urlString: urlString)
  }

  func cleanse(url: URL?) -> CleansedURL {
    subsonicServerApi.cleanse(url: url)
  }

  // MARK: G20 enrichment

  /// shared response → delegate plumbing for DTO-level endpoints
  /// (`parse` mirrors SubsonicLibrarySyncer's private variant, kept
  /// internal for cross-file extension members)
  internal func parse<Delegate: SsXmlParser>(
    response: APIDataResponse,
    delegate: Delegate
  ) throws {
    let parser = XMLParser(data: response.data)
    parser.delegate = delegate
    parser.parse()
    if let error = delegate.error {
      throw ResponseError.createFromSubsonicError(
        cleansedURL: response.url?.asCleansedURL(cleanser: subsonicServerApi),
        error: error,
        data: response.data
      )
    }
  }

  func getArtistInfo(artistId: String) async throws -> BackendFeatureResult<ArtistInfo> {
    let response = try await subsonicServerApi.requestArtistInfo2(id: artistId)
    let delegate = SsArtistInfoParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: delegate)
    return .supported(delegate.artistInfo)
  }

  func getAlbumInfo(albumId: String) async throws -> BackendFeatureResult<AlbumInfo> {
    let response = try await subsonicServerApi.requestAlbumInfo(id: albumId)
    let delegate = SsAlbumInfoParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: delegate)
    return .supported(delegate.albumInfo)
  }

  func getTopSongs(
    artistName: String,
    count: Int
  ) async throws -> BackendFeatureResult<[RemoteSongInfo]> {
    let response = try await subsonicServerApi.requestTopSongs(
      artistName: artistName,
      count: count
    )
    let delegate = SsTopSongsParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: delegate)
    return .supported(delegate.topSongs)
  }

  func getSimilarArtists(
    artistId: String,
    count: Int
  ) async throws -> BackendFeatureResult<[ArtistStub]> {
    let response = try await subsonicServerApi.requestSimilarArtists(
      id: artistId,
      count: count
    )
    let delegate = SsSimilarArtistsParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: delegate)
    return .supported(delegate.similarArtists)
  }

  func getAlbums(
    fromYear: Int,
    toYear: Int,
    offset: Int,
    count: Int
  ) async throws -> BackendFeatureResult<[RemoteAlbumInfo]> {
    let response = try await subsonicServerApi.requestAlbumsByYear(
      fromYear: fromYear,
      toYear: toYear,
      offset: offset,
      count: count
    )
    let delegate = SsAlbumListParserDelegate(performanceMonitor: performanceMonitor)
    try parse(response: response, delegate: delegate)
    return .supported(delegate.albums)
  }

  // MARK: G18 shares

  /// Subsonic-family servers answer unimplemented/disabled endpoints with
  /// a typed error — `serverVerionToLow` (unknown action) and
  /// `userIsNotAuthorized` (e.g. Navidrome with sharing disabled or a
  /// non-admin user) both mean "feature not available", so collapse them
  /// into `.notSupported` per the degraded-path contract.
  internal func unsupportedIfMissing<T: Sendable>(
    _ body: () async throws -> BackendFeatureResult<T>
  ) async throws -> BackendFeatureResult<T> {
    do {
      return try await body()
    } catch let error as ResponseError {
      switch error.asSubsonicError {
      case .serverVerionToLow, .userIsNotAuthorized:
        return .notSupported
      default:
        throw error
      }
    }
  }

  func getShares() async throws -> BackendFeatureResult<[ShareDescription]> {
    try await unsupportedIfMissing {
      let response = try await self.subsonicServerApi.requestShares()
      let delegate = SsSharesParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      return .supported(self.subsonicServerApi.applyPublicUrlOverride(to: delegate.shares))
    }
  }

  func createShare(
    shareableType: ShareableType,
    shareableId: String,
    description: String?,
    expiresInDays: Int?
  ) async throws -> BackendFeatureResult<ShareDescription> {
    try await unsupportedIfMissing {
      let response = try await self.subsonicServerApi.requestCreateShare(
        id: shareableId,
        description: description,
        expiresInDays: expiresInDays
      )
      let delegate = SsSharesParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      let shares = self.subsonicServerApi.applyPublicUrlOverride(to: delegate.shares)
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
    guard try await subsonicServerApi.isShareUpdateSupported() else { return .notSupported }
    return try await unsupportedIfMissing {
      let response = try await self.subsonicServerApi.requestUpdateShare(
        id: id,
        description: description,
        expiresInDays: expiresInDays
      )
      let delegate = SsSharesParserDelegate(performanceMonitor: self.performanceMonitor)
      try self.parse(response: response, delegate: delegate)
      let shares = self.subsonicServerApi.applyPublicUrlOverride(to: delegate.shares)
      guard let updated = shares.first else {
        throw ResponseError(type: .xml, cleansedURL: nil, data: response.data)
      }
      return .supported(updated)
    }
  }

  func deleteShare(id: String) async throws -> BackendFeatureResult<Bool> {
    try await unsupportedIfMissing {
      let response = try await self.subsonicServerApi.requestDeleteShare(id: id)
      try self.parse(response: response, delegate: SsPingParserDelegate(
        performanceMonitor: self.performanceMonitor
      ))
      return .supported(true)
    }
  }

  // MARK: G8 smart playlists

  func getSmartPlaylistCriteria(
    playlistId: String
  ) async throws -> BackendFeatureResult<SmartPlaylistCriteria> {
    guard subsonicServerApi.isNavidromeServer,
          let rulesData = try await subsonicServerApi.requestSmartPlaylistRules(
            playlistId: playlistId
          ),
          let nsp = NspCriteriaParser.parse(data: rulesData)
    else { return .notSupported }
    return .supported(nsp.criteria)
  }

  // MARK: dislike (#587) — Subsonic has no dislike concept; rating=0 would
  // destroy the user's stars, so the flag is local-only
  func setDislike(playableInfo: AbstractPlayableInfo) async throws -> DislikeResolution {
    .localOnly
  }

  func clearDislike(playableInfo: AbstractPlayableInfo) async throws -> DislikeResolution {
    .localOnly
  }
}
