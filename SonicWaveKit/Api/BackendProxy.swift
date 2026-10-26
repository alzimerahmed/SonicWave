//
//  BackendProxy.swift
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

// MARK: - ServerApiType

public enum ServerApiType: Int, Sendable {
  case ampache = 1
  case subsonic = 2
}

// MARK: - BackenApiType

public enum BackenApiType: Int, Sendable, Codable {
  case notDetected = 0
  case ampache = 1
  case subsonic = 2
  case subsonic_legacy = 3

  public var description: String {
    switch self {
    case .notDetected: return "NotDetected"
    case .ampache: return "Ampache"
    case .subsonic: return "Subsonic"
    case .subsonic_legacy: return "Subsonic (legacy login)"
    }
  }

  public var selectorDescription: String {
    switch self {
    case .notDetected: return "Auto-Detect"
    case .ampache: return "Ampache"
    case .subsonic: return "Subsonic"
    case .subsonic_legacy: return "Subsonic (legacy login)"
    }
  }

  public var asServerApiType: ServerApiType? {
    switch self {
    case .notDetected: return nil
    case .ampache: return .ampache
    case .subsonic: return .subsonic
    case .subsonic_legacy: return .subsonic
    }
  }
}

// MARK: - AuthenticationError

public enum AuthenticationError: LocalizedError {
  case notAbleToLogin
  case invalidUrl
  case requestStatusError(message: String)
  case downloadError(message: String)

  public var errorDescription: String? {
    var ret = ""
    switch self {
    case .notAbleToLogin:
      ret = "Not able to login, please check credentials!"
    case .invalidUrl:
      ret = "Server URL is invalid!"
    case let .requestStatusError(message: message):
      ret = "Requesting server URL finished with status response error code '\(message)'!"
    case let .downloadError(message: message):
      ret = message
    }
    return ret
  }
}

// MARK: - BackendError

public enum BackendError: LocalizedError {
  case invalidUrl
  case noCredentials
  case persistentSaveFailed
  case notSupported
  case incorrectServerBehavior(message: String)

  public var errorDescription: String? {
    var ret = ""
    switch self {
    case .invalidUrl:
      ret = "Provided URL is invalid."
    case .noCredentials:
      ret = "Internal error: no credentials provided."
    case .persistentSaveFailed:
      ret = "Change could not be saved."
    case .notSupported:
      ret = "Requested functionality is not supported."
    case let .incorrectServerBehavior(message: message):
      ret = "Server didn't behave as expected: \(message)"
    }
    return ret
  }
}

// MARK: - ResponseErrorType

public enum ResponseErrorType: Sendable {
  case api
  case xml
  case resource
}

// MARK: - ResponseError

final public class ResponseError: LocalizedError, Sendable {
  public let type: ResponseErrorType
  public let statusCode: Int
  public let message: String
  public let cleansedURL: CleansedURL?
  public let data: Data?

  init(
    type: ResponseErrorType,
    statusCode: Int = 0,
    message: String = "",
    cleansedURL: CleansedURL? = nil,
    data: Data? = nil
  ) {
    self.type = type
    self.statusCode = statusCode
    self.cleansedURL = cleansedURL
    self.data = data

    switch type {
    case .api:
      self.message = message
    case .xml:
      self.message = "XML response could not be parsed."
    case .resource:
      self.message = message
    }
  }

  public var errorDescription: String? {
    switch type {
    case .api:
      return "API error \(statusCode): \(message)"
    case .xml:
      return "\(message)"
    case .resource:
      return "API error \(statusCode): \(message)"
    }
  }

  public func asInfo(topic: String) -> ResponseErrorInfo {
    var dataString: String?
    if let data = data {
      dataString = String(decoding: data, as: UTF8.self)
    }
    return ResponseErrorInfo(
      topic: topic,
      statusCode: statusCode,
      message: message,
      cleansedURL: cleansedURL?.description ?? "",
      data: dataString
    )
  }
}

// MARK: - ResponseErrorInfo

public struct ResponseErrorInfo: Encodable {
  public var topic: String
  public var statusCode: Int
  public var message: String
  public var cleansedURL: String
  public var data: String?
}

// MARK: - BackendProxy

public final class BackendProxy: Sendable {
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "BackendProxy")
  private let networkMonitor: NetworkMonitorFacade
  private let performanceMonitor: ThreadPerformanceMonitor
  private let eventLogger: EventLogger
  private let settings: AmperfySettings
  private let accountInfo: AccountInfo
  private let notificationHandler: EventNotificationHandler
  /// Per-account TLS policy (self-signed TOFU pins + mTLS client certificate)
  /// shared by all sessions that talk to this account's server.
  private let sessionSecurity: AccountSessionSecurity
  /// latest known credentials — kept so URL failover can re-provide them
  private let currentCredentials = Atomic<LoginCredentials?>(wrappedValue: nil)
  /// the shared unreachable monitor — kept so account teardown can cancel
  /// its auto-recovery probe loop (`stopAutoRecovery`)
  private let unreachableMonitor = Atomic<ServerUnreachableMonitor?>(wrappedValue: nil)

  public var selectedApi: BackenApiType {
    get {
      activeApiType.wrappedValue
    }
    set {
      os_log("%s is active backend api", log: self.log, type: .info, newValue.description)
      activeApiType.wrappedValue = newValue
      downloadManagerDelegate.wrappedValue = activeApi.createArtworkDownloadDelegate()
    }
  }

  private let activeApiType = Atomic<BackenApiType>(wrappedValue: .ampache)
  private let downloadManagerDelegate = Atomic<DownloadManagerDelegate?>(wrappedValue: nil)

  private var activeApi: BackendApi {
    switch activeApiType.wrappedValue {
    case .notDetected:
      return ampacheApi.wrappedValue!
    case .ampache:
      return ampacheApi.wrappedValue!
    case .subsonic:
      return subsonicApi.wrappedValue!
    case .subsonic_legacy:
      return subsonicLegacyApi.wrappedValue!
    }
  }

  private let ampacheApi = Atomic<BackendApi?>(wrappedValue: nil)
  private let subsonicApi = Atomic<SubsonicApi?>(wrappedValue: nil)
  private let subsonicLegacyApi = Atomic<SubsonicApi?>(wrappedValue: nil)

  init(
    networkMonitor: NetworkMonitorFacade,
    performanceMonitor: ThreadPerformanceMonitor,
    eventLogger: EventLogger,
    settings: AmperfySettings,
    accountInfo: AccountInfo,
    notificationHandler: EventNotificationHandler,
    sessionSecurity: AccountSessionSecurity
  ) {
    self.networkMonitor = networkMonitor
    self.performanceMonitor = performanceMonitor
    self.eventLogger = eventLogger
    self.settings = settings
    self.accountInfo = accountInfo
    self.notificationHandler = notificationHandler
    self.sessionSecurity = sessionSecurity
  }

  @MainActor
  public func initialize() {
    // one monitor per account — shared by all API implementations so consecutive
    // connectivity failures of any of them count toward auto-offline detection;
    // the injected probe/failover closures drive the auto-recovery loop (G16)
    let serverUnreachableMonitor = ServerUnreachableMonitor(
      networkMonitor: networkMonitor,
      eventLogger: eventLogger,
      settings: settings,
      accountInfo: accountInfo,
      notificationHandler: notificationHandler,
      serverURLCandidatesProvider: { [weak self] in
        self?.serverURLCandidates() ?? []
      },
      serverReachabilityProbe: { [weak self] serverURL in
        await self?.isServerUrlReachable(serverUrl: serverURL) ?? false
      },
      autoRecoveryHandler: { [weak self] reachableURL in
        await self?.handleAutoRecovery(reachableURL: reachableURL)
      }
    )
    unreachableMonitor.wrappedValue = serverUnreachableMonitor
    ampacheApi.wrappedValue = AmpacheApi(
      ampacheXmlServerApi: AmpacheXmlServerApi(
        performanceMonitor: performanceMonitor,
        eventLogger: eventLogger,
        settings: settings,
        serverUnreachableMonitor: serverUnreachableMonitor,
        sessionSecurity: sessionSecurity
      ),
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      eventLogger: eventLogger
    )
    subsonicApi.wrappedValue = SubsonicApi(
      subsonicServerApi: SubsonicServerApi(
        performanceMonitor: performanceMonitor,
        eventLogger: eventLogger,
        settings: settings,
        serverUnreachableMonitor: serverUnreachableMonitor,
        sessionSecurity: sessionSecurity
      ),
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      eventLogger: eventLogger
    )
    subsonicApi.wrappedValue!.setAuthType(newAuthType: .autoDetect)
    subsonicLegacyApi.wrappedValue = SubsonicApi(
      subsonicServerApi: SubsonicServerApi(
        performanceMonitor: performanceMonitor,
        eventLogger: eventLogger,
        settings: settings,
        serverUnreachableMonitor: serverUnreachableMonitor,
        sessionSecurity: sessionSecurity
      ),
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      eventLogger: eventLogger
    )
    subsonicLegacyApi.wrappedValue!.setAuthType(newAuthType: .legacy)
    // app was restarted while auto-offline -> resume reconnecting immediately
    Task {
      await serverUnreachableMonitor.startAutoRecoveryIfNeeded()
    }
  }

  @MainActor
  public func login(
    apiType: BackenApiType,
    credentials: LoginCredentials
  ) async throws
    -> BackenApiType {
    // pending credentials are fed to the session policy upfront so the
    // reachability probe and the auth probes can already present a client
    // certificate (mTLS) or apply the self-signed TOFU pin for this account
    sessionSecurity.provideCredentials(credentials)
    currentCredentials.wrappedValue = credentials
    try await checkServerReachablity(credentials: credentials)

    if apiType == .notDetected || apiType == .ampache {
      do {
        try await ampacheApi.wrappedValue!.isAuthenticationValid(credentials: credentials)
        return .ampache
      } catch {} // error -> ignore this api and check the others
    }

    if apiType == .notDetected || apiType == .subsonic {
      do {
        try await subsonicApi.wrappedValue!.isAuthenticationValid(credentials: credentials)
        return .subsonic
      } catch {} // error -> ignore this api and check the others
    }

    if apiType == .notDetected || apiType == .subsonic_legacy {
      do {
        try await subsonicLegacyApi.wrappedValue!.isAuthenticationValid(credentials: credentials)
        return .subsonic_legacy
      } catch {} // error -> ignore this api and check the others
    }

    throw AuthenticationError.notAbleToLogin
  }

  @MainActor
  private func checkServerReachablity(credentials: LoginCredentials) async throws {
    guard let activeBackendServerUrl = URL(string: credentials.activeBackendServerUrl) else {
      throw AuthenticationError.invalidUrl
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), Error>) in
      let sessionConfig = URLSessionConfiguration.default
      // the account's session policy answers client-cert challenges (mTLS) and
      // applies the self-signed TOFU pin — a locked-down reverse proxy must be
      // reachable even for this very first probe
      let session = URLSession(
        configuration: sessionConfig,
        delegate: AccountSessionChallengeHandler(security: sessionSecurity),
        delegateQueue: nil
      )
      var request = URLRequest(url: activeBackendServerUrl)
      for (field, value) in credentials.httpHeaders {
        request.setValue(value, forHTTPHeaderField: field)
      }
      let task = session.downloadTask(with: request) { tempLocalUrl, response, error in
        // the closure captures the session — release session + delegate once
        // the probe is done (same pattern as isServerUrlReachable)
        defer { session.invalidateAndCancel() }
        if let error = error {
          continuation
            .resume(
              throwing: AuthenticationError
                .downloadError(message: error.localizedDescription)
            )
        } else {
          if let statusCode = (response as? HTTPURLResponse)?.statusCode {
            if statusCode >= 400,
               // ignore 401 Unauthorized (RFC 7235) status code
               // -> Can occur if root website requires http basic authentication,
               //    but the REST API endpoints are reachable without http basic authentication
               statusCode != 401 {
              continuation
                .resume(throwing: AuthenticationError.requestStatusError(message: "\(statusCode)"))
            } else {
              continuation.resume()
            }
          } else {
            continuation.resume(
              throwing: AuthenticationError.downloadError(message: "Server sent no HTTP response")
            )
          }
        }
      }
      task.resume()
    }
    os_log("Server url is reachable.", log: self.log, type: .info)
  }

  // MARK: Auto recovery (G16)

  /// Ordered candidates for the recovery probe — the currently active URL
  /// first, then primary + all alternative URLs (deduplicated), so a reachable
  /// alternative can take over when the active endpoint stays dead. Falls back
  /// to the persisted credentials (same source `handleAutoRecovery` uses) so
  /// early loop iterations before `provideCredentials` aren't empty.
  private func serverURLCandidates() -> [String] {
    guard let credentials = currentCredentials.wrappedValue
          ?? settings.accounts.getSetting(accountInfo).read.loginCredentials
    else { return [] }
    var urls = [String]()
    if !credentials.activeBackendServerUrl.isEmpty {
      urls.append(credentials.activeBackendServerUrl)
    }
    for url in credentials.availableServerURLs where !urls.contains(url) {
      urls.append(url)
    }
    return urls
  }

  /// Transport-level probe used by the recovery loop: a host that answers —
  /// even with an HTTP error or an authentication failure — counts as
  /// reachable. Connectivity-class failures (DNS, TCP connect, timeout,
  /// no route) keep it "unreachable" — and so do TLS/certificate-validation
  /// failures (`RequestFailureKind.tlsFailure`): a host whose certificate
  /// cannot be trusted must never exit offline mode nor be persisted as the
  /// active URL (possible MITM). This intentionally can never retry-loop on
  /// 401s: auth failures surface to the user once back online instead.
  private func isServerUrlReachable(serverUrl: String) async -> Bool {
    guard let url = URL(string: serverUrl) else { return false }
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = 10
    sessionConfig.timeoutIntervalForResource = 15
    let session = URLSession(
      configuration: sessionConfig,
      delegate: AccountSessionChallengeHandler(security: sessionSecurity),
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    for (field, value) in currentCredentials.wrappedValue?.httpHeaders ?? [:] {
      request.setValue(value, forHTTPHeaderField: field)
    }
    do {
      _ = try await session.data(for: request)
      return true
    } catch {
      return RequestFailureKind.classify(error: error) == .nonConnectivity
    }
  }

  /// Failover handler — runs before online mode is restored: when the probe
  /// reached an alternative URL, it becomes the persisted active URL and the
  /// updated credentials are re-provided to the active API + session policy.
  /// The detected `selectedApi` is kept: alternatives must reach the same
  /// server (documented in the server-URL management UI).
  private func handleAutoRecovery(reachableURL: String) async {
    guard var credentials = currentCredentials.wrappedValue
          ?? settings.accounts.getSetting(accountInfo).read.loginCredentials
    else { return }
    if credentials.activeBackendServerUrl != reachableURL,
       credentials.availableServerURLs.contains(reachableURL) {
      credentials.activeBackendServerUrl = reachableURL
      var mutableSettings = settings
      mutableSettings.accounts.updateSetting(accountInfo) { accountSettings in
        accountSettings.loginCredentials?.activeBackendServerUrl = reachableURL
      }
      os_log(
        "Auto recovery: switched active server URL to a reachable alternative",
        log: self.log,
        type: .info
      )
      await eventLogger.info(
        topic: "Connection",
        message: "Server URL switched to a reachable alternative",
        displayPopup: false
      )
    }
    // refresh the active API + session policy with the (possibly failed-over)
    // credentials — the first requests after returning online re-auth lazily
    provideCredentials(credentials: credentials)
  }

  /// Cancels the auto-recovery probe loop — called on account teardown
  /// (`AmperKit.resetMeta` via `MetaManager.stopAutoRecovery`) so the loop
  /// can't outlive its account.
  func stopAutoRecovery() {
    guard let monitor = unreachableMonitor.wrappedValue else { return }
    Task { await monitor.stopAutoRecovery() }
  }
}

// MARK: BackendApi

extension BackendProxy: BackendApi {
  public var clientApiVersion: String { activeApi.clientApiVersion }

  public var serverApiVersion: String { activeApi.serverApiVersion }

  public var httpHeaders: [String: String] { activeApi.httpHeaders }

  public func provideCredentials(credentials: LoginCredentials) {
    currentCredentials.wrappedValue = credentials
    sessionSecurity.provideCredentials(credentials)
    activeApi.provideCredentials(credentials: credentials)
  }

  public func isAuthenticationValid(credentials: LoginCredentials) async throws {
    try await activeApi.isAuthenticationValid(credentials: credentials)
  }

  public func generateUrl(forDownloadingPlayable playableInfo: AbstractPlayableInfo) async throws
    -> URL {
    try await activeApi.generateUrl(forDownloadingPlayable: playableInfo)
  }

  public func generateUrl(
    forStreamingPlayable playableInfo: AbstractPlayableInfo,
    maxBitrate: StreamingMaxBitratePreference,
    formatPreference: StreamingFormatPreference,
    timeOffset: Int? = nil
  ) async throws
    -> URL {
    try await activeApi.generateUrl(
      forStreamingPlayable: playableInfo,
      maxBitrate: maxBitrate,
      formatPreference: formatPreference,
      timeOffset: timeOffset
    )
  }

  public func isTranscodeOffsetSeekSupported() async -> Bool {
    await activeApi.isTranscodeOffsetSeekSupported()
  }

  public func generateUrl(forArtwork artwork: Artwork) async throws -> URL {
    try await activeApi.generateUrl(forArtwork: artwork)
  }

  public func checkForErrorResponse(response: APIDataResponse) -> ResponseError? {
    activeApi.checkForErrorResponse(response: response)
  }

  public func createLibrarySyncer(account: Account, storage: PersistentStorage) -> LibrarySyncer {
    activeApi.createLibrarySyncer(account: account, storage: storage)
  }

  public func getActiveArtworkDownloadDelegate() -> DownloadManagerDelegate {
    var dlDelegate = downloadManagerDelegate.wrappedValue
    if dlDelegate == nil {
      dlDelegate = activeApi.createArtworkDownloadDelegate()
      downloadManagerDelegate.wrappedValue = dlDelegate
    }
    return dlDelegate!
  }

  public func createArtworkDownloadDelegate() -> DownloadManagerDelegate {
    activeApi.createArtworkDownloadDelegate()
  }

  public func extractArtworkInfoFromURL(urlString: String) -> ArtworkRemoteInfo? {
    activeApi.extractArtworkInfoFromURL(urlString: urlString)
  }

  public func cleanse(url: URL?) -> CleansedURL {
    activeApi.cleanse(url: url)
  }

  // MARK: Phase-8 discovery surface — forwards to the detected backend

  public func getArtistInfo(artistId: String) async throws -> BackendFeatureResult<ArtistInfo> {
    try await activeApi.getArtistInfo(artistId: artistId)
  }

  public func getAlbumInfo(albumId: String) async throws -> BackendFeatureResult<AlbumInfo> {
    try await activeApi.getAlbumInfo(albumId: albumId)
  }

  public func getTopSongs(
    artistName: String,
    count: Int
  ) async throws -> BackendFeatureResult<[RemoteSongInfo]> {
    try await activeApi.getTopSongs(artistName: artistName, count: count)
  }

  public func getSimilarArtists(
    artistId: String,
    count: Int
  ) async throws -> BackendFeatureResult<[ArtistStub]> {
    try await activeApi.getSimilarArtists(artistId: artistId, count: count)
  }

  public func getAlbums(
    fromYear: Int,
    toYear: Int,
    offset: Int,
    count: Int
  ) async throws -> BackendFeatureResult<[RemoteAlbumInfo]> {
    try await activeApi.getAlbums(
      fromYear: fromYear,
      toYear: toYear,
      offset: offset,
      count: count
    )
  }

  public func getShares() async throws -> BackendFeatureResult<[ShareDescription]> {
    try await activeApi.getShares()
  }

  public func createShare(
    shareableType: ShareableType,
    shareableId: String,
    description: String?,
    expiresInDays: Int?
  ) async throws -> BackendFeatureResult<ShareDescription> {
    try await activeApi.createShare(
      shareableType: shareableType,
      shareableId: shareableId,
      description: description,
      expiresInDays: expiresInDays
    )
  }

  public func updateShare(
    id: String,
    description: String?,
    expiresInDays: Int?
  ) async throws -> BackendFeatureResult<ShareDescription> {
    try await activeApi.updateShare(
      id: id,
      description: description,
      expiresInDays: expiresInDays
    )
  }

  public func deleteShare(id: String) async throws -> BackendFeatureResult<Bool> {
    try await activeApi.deleteShare(id: id)
  }

  public func getSmartPlaylistCriteria(
    playlistId: String
  ) async throws -> BackendFeatureResult<SmartPlaylistCriteria> {
    try await activeApi.getSmartPlaylistCriteria(playlistId: playlistId)
  }

  // MARK: G19 bookmarks — forwards to the detected backend

  public func getBookmarks() async throws -> BackendFeatureResult<[ServerBookmark]> {
    try await activeApi.getBookmarks()
  }

  public func createBookmark(
    playableInfo: AbstractPlayableInfo,
    positionSeconds: Int
  ) async throws -> BackendFeatureResult<Bool> {
    try await activeApi.createBookmark(
      playableInfo: playableInfo,
      positionSeconds: positionSeconds
    )
  }

  public func deleteBookmark(
    _ bookmark: ServerBookmark
  ) async throws -> BackendFeatureResult<Bool> {
    try await activeApi.deleteBookmark(bookmark)
  }

  // MARK: G11 jukebox

  public func getJukeboxPlaylist() async throws -> BackendFeatureResult<JukeboxPlaylist> {
    try await activeApi.getJukeboxPlaylist()
  }

  public func jukeboxControl(_ action: JukeboxAction) async throws -> BackendFeatureResult<Bool> {
    try await activeApi.jukeboxControl(action)
  }

  // MARK: G23 music folders

  public func getMusicFolders() async throws -> BackendFeatureResult<[MusicFolderStub]> {
    try await activeApi.getMusicFolders()
  }

  public func setDislike(playableInfo: AbstractPlayableInfo) async throws -> DislikeResolution {
    try await activeApi.setDislike(playableInfo: playableInfo)
  }

  public func clearDislike(playableInfo: AbstractPlayableInfo) async throws -> DislikeResolution {
    try await activeApi.clearDislike(playableInfo: playableInfo)
  }
}
