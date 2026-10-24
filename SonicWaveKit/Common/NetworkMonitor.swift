//
//  NetworkMonitor.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 02.04.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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

import Alamofire
import Foundation
import Network
import OSLog
import SystemConfiguration

public typealias ConnectionTypeChangedCallack = @Sendable (_ isWiFiConnected: Bool) async -> ()

// MARK: - NetworkMonitorFacade

public protocol NetworkMonitorFacade: Sendable {
  var connectionTypeChangedCB: ConnectionTypeChangedCallack? { get set }
  var isConnectedToNetwork: Bool { get }
  var isCellular: Bool { get }
  var isWifiOrEthernet: Bool { get }
}

// MARK: - NetworkMonitor

final public class NetworkMonitor: NetworkMonitorFacade {
  private let queue = DispatchQueue(label: "NetworkMonitor")
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "NetworkMonitor")
  private let monitor = NWPathMonitor()
  private let networkPath: Atomic<NWPath>
  private let notificationHandler: EventNotificationHandler
  private let _connectionTypeChangedCB = Atomic<ConnectionTypeChangedCallack?>(wrappedValue: nil)

  init(notificationHandler: EventNotificationHandler) {
    self.networkPath = Atomic<NWPath>(wrappedValue: monitor.currentPath)
    self.notificationHandler = notificationHandler
  }

  public var connectionTypeChangedCB: ConnectionTypeChangedCallack? {
    get { _connectionTypeChangedCB.wrappedValue }
    set { _connectionTypeChangedCB.wrappedValue = newValue }
  }

  private func updateNetworkPath(newPath: NWPath) async {
    let isConnectedBeforeChange = isConnectedToNetwork
    networkPath.wrappedValue = newPath
    let isConnectedAfterChange = isConnectedToNetwork

    if newPath.status != .satisfied {
      os_log("Disconnected: The network is not reachable", log: self.log, type: .info)
    } else if newPath.usesInterfaceType(.cellular) {
      os_log(
        "Connected: The network is reachable over the Cellular connection",
        log: self.log,
        type: .info
      )
    } else if newPath.usesInterfaceType(.wifi) {
      os_log(
        "Connected: The network is reachable over the WiFi connection",
        log: self.log,
        type: .info
      )
    } else if newPath.usesInterfaceType(.wiredEthernet) {
      os_log(
        "Connected: The network is reachable over the Ethernet connection",
        log: self.log,
        type: .info
      )
    } else if newPath.usesInterfaceType(.other) {
      os_log(
        "Connected: The network is reachable over Other connection",
        log: self.log,
        type: .info
      )
    } else if newPath.usesInterfaceType(.loopback) {
      os_log(
        "Connected: The network is reachable over Loop Back connection",
        log: self.log,
        type: .info
      )
    }

    if isConnectedBeforeChange != isConnectedAfterChange {
      await notificationHandler.post(
        name: .networkStatusChanged,
        object: self,
        userInfo: nil
      )
    }
    await connectionTypeChangedCB?(!isCellular)
  }

  func start() {
    monitor.pathUpdateHandler = { [self] networkPath in
      Task {
        await updateNetworkPath(newPath: networkPath)
      }
    }
    monitor.start(queue: queue)
  }

  public var isConnectedToNetwork: Bool {
    let isConneted = networkPath.wrappedValue.status == .satisfied
    return isConneted
  }

  public var isCellular: Bool {
    networkPath.wrappedValue.usesInterfaceType(.cellular)
  }

  public var isWifiOrEthernet: Bool {
    isConnectedToNetwork && !isCellular
  }
}

// MARK: - RequestFailureKind

/// Classification of a failed server request for the connectivity resilience layer.
/// Only transport-level failures count for retry/backoff and server-unreachable
/// detection — never auth failures, HTTP status errors, or response parse errors.
enum RequestFailureKind: Sendable {
  /// The server could not be reached at all (DNS, TCP connect, timeout, lost route).
  case connectivity
  /// The request was cancelled — carries no evidence about server reachability.
  case cancellation
  /// Any other failure — proves the server answered (HTTP status, validation, parse).
  case nonConnectivity

  /// `URLError` codes that indicate the server could not be reached.
  private static let connectivityUrlErrorCodes: Set<URLError.Code> = [
    .timedOut,
    .cannotFindHost,
    .cannotConnectToHost,
    .networkConnectionLost,
    .dnsLookupFailed,
    .notConnectedToInternet,
  ]

  static func classify(error: Error) -> RequestFailureKind {
    if error is CancellationError {
      return .cancellation
    }
    if let afError = error as? AFError {
      if afError.isExplicitlyCancelledError {
        return .cancellation
      }
      // Alamofire wraps URLSession errors in .sessionTaskFailed -> unwrap recursively
      if let underlyingError = afError.underlyingError {
        return classify(error: underlyingError)
      }
      return .nonConnectivity
    }
    if let urlError = error as? URLError {
      if urlError.code == .cancelled {
        return .cancellation
      }
      return connectivityUrlErrorCodes.contains(urlError.code) ? .connectivity : .nonConnectivity
    }
    return .nonConnectivity
  }
}

// MARK: - ConnectivityBackoffPolicy

/// Exponential backoff with jitter for connectivity-class request retries.
/// Value type — the only nondeterminism is the jitter component.
struct ConnectivityBackoffPolicy: Sendable {
  /// retries after the initial attempt (total attempts = maxRetries + 1)
  var maxRetries = 3
  var baseDelayInSeconds: TimeInterval = 1.0
  var multiplier = 2.0
  var maxDelayInSeconds: TimeInterval = 8.0
  /// relative jitter applied to each computed delay (±jitterFactor)
  var jitterFactor = 0.25

  /// Delay to wait before the given retry attempt (1-based).
  func delay(forRetryAttempt retryAttempt: Int) -> TimeInterval {
    let exponent = max(0, retryAttempt - 1)
    let unclamped = baseDelayInSeconds * pow(multiplier, Double(exponent))
    let capped = min(unclamped, maxDelayInSeconds)
    let jitterRange = capped * jitterFactor
    let jittered = capped + Double.random(in: -jitterRange ... jitterRange)
    return max(0.1, jittered)
  }
}

// MARK: - ServerUnreachableMonitor

/// Counts consecutive connectivity-class request failures for one account and
/// switches the app to offline mode when the server stays unreachable.
///
/// State machine:
/// - `reportServerResponded()` (request answered — response data OR HTTP/API
///   error) resets the consecutive-failure counter
/// - `reportConnectivityFailure()` only counts while the device has a network
///   interface up (NetworkMonitor) AND the user is not already in offline mode;
///   while either is true the counter resets to zero (no stale accumulation)
/// - reaching `consecutiveFailuresThreshold` latches `isAutoOfflineActive`,
///   writes `settings.user.isOfflineMode = true` through the UserDefaults-backed
///   setter, posts `.offlineModeChanged`, and emits exactly one user notice
/// - the latch rearms as soon as the user is back in online mode (manual toggle
///   or the auto-return path below), so one unreachable episode produces at
///   most one notice — hysteresis against flapping
///
/// Auto-return (G16): when the monitor switched to offline mode it marks
/// `settings.user.isOfflineModeAutomaticallyActivated` and starts a recovery
/// loop that — with capped exponential backoff — probes all known server URLs
/// (`serverURLCandidatesProvider`, active URL first so alternatives act as
/// failover). The first reachable URL is handed to `autoRecoveryHandler`
/// (which persists it as the active URL and re-provides credentials), then
/// offline mode is exited automatically. The loop never runs while the user
/// went offline manually, and it stops when the account is removed or no
/// longer active. Auth/HTTP answers count as "reachable" — the loop only waits
/// on transport-level failures, so it can never retry-loop on e.g. a 401.
actor ServerUnreachableMonitor {
  static let consecutiveFailuresThreshold = 3

  /// recovery probes run on a much slower cadence than request retries —
  /// a dead server must not be hammered (battery) nor DoSed
  static let defaultRecoveryBackoffPolicy = ConnectivityBackoffPolicy(
    baseDelayInSeconds: 4.0,
    multiplier: 2.0,
    maxDelayInSeconds: 120.0,
    jitterFactor: 0.25
  )
  /// poll cadence while the device has no network path at all
  static let defaultDisconnectedPollIntervalInSeconds: TimeInterval = 5.0

  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "ServerUnreachableMonitor")
  private let networkMonitor: NetworkMonitorFacade
  private let eventLogger: EventLogger
  private let settings: AmperfySettings
  private let accountInfo: AccountInfo?
  private let notificationHandler: EventNotificationHandler

  /// ordered server URL candidates to probe during recovery — active URL first
  private let serverURLCandidatesProvider: (@Sendable () -> [String])?
  /// one transport-level probe; must only return true when the host answered
  private let serverReachabilityProbe: (@Sendable (_ serverURL: String) async -> Bool)?
  /// invoked with the first reachable URL before online mode is restored —
  /// BackendProxy persists it as the active URL and re-provides credentials
  private let autoRecoveryHandler: (@Sendable (_ reachableServerURL: String) async -> ())?
  private let recoveryBackoffPolicy: ConnectivityBackoffPolicy
  private let disconnectedPollIntervalInSeconds: TimeInterval

  private var consecutiveConnectivityFailures = 0
  private var isAutoOfflineActive = false
  private var recoveryTask: Task<Void, Never>?

  init(
    networkMonitor: NetworkMonitorFacade,
    eventLogger: EventLogger,
    settings: AmperfySettings,
    accountInfo: AccountInfo? = nil,
    notificationHandler: EventNotificationHandler = EventNotificationHandler(),
    serverURLCandidatesProvider: (@Sendable () -> [String])? = nil,
    serverReachabilityProbe: (@Sendable (_ serverURL: String) async -> Bool)? = nil,
    autoRecoveryHandler: (@Sendable (_ reachableServerURL: String) async -> ())? = nil,
    recoveryBackoffPolicy: ConnectivityBackoffPolicy = ServerUnreachableMonitor
      .defaultRecoveryBackoffPolicy,
    disconnectedPollIntervalInSeconds: TimeInterval = ServerUnreachableMonitor
      .defaultDisconnectedPollIntervalInSeconds
  ) {
    self.networkMonitor = networkMonitor
    self.eventLogger = eventLogger
    self.settings = settings
    self.accountInfo = accountInfo
    self.notificationHandler = notificationHandler
    self.serverURLCandidatesProvider = serverURLCandidatesProvider
    self.serverReachabilityProbe = serverReachabilityProbe
    self.autoRecoveryHandler = autoRecoveryHandler
    self.recoveryBackoffPolicy = recoveryBackoffPolicy
    self.disconnectedPollIntervalInSeconds = disconnectedPollIntervalInSeconds
  }

  /// The request reached the server (response data or an answered HTTP/API error).
  func reportServerResponded() {
    consecutiveConnectivityFailures = 0
  }

  /// The request failed without reaching the server (retries already exhausted).
  func reportConnectivityFailure() async {
    // AmperfySettings.user decodes from UserDefaults on every read -> live value
    let isUserInOfflineMode = settings.user.isOfflineMode
    if !isUserInOfflineMode {
      // user is (back) in online mode -> rearm the one-shot latch
      isAutoOfflineActive = false
    }
    // no network interface -> local problem, not evidence of an unreachable server;
    // already offline -> do not accumulate while requests are suppressed anyway
    guard networkMonitor.isConnectedToNetwork, !isUserInOfflineMode else {
      consecutiveConnectivityFailures = 0
      return
    }
    consecutiveConnectivityFailures += 1
    os_log(
      "Connectivity failure %i in a row",
      log: self.log,
      type: .info,
      consecutiveConnectivityFailures
    )
    guard consecutiveConnectivityFailures >= Self.consecutiveFailuresThreshold,
          !isAutoOfflineActive
    else { return }
    // only the active account may flip the global offline switch — an
    // unreachable inactive account (e.g. background sync for another account)
    // must not take the app offline
    if let accountInfo, settings.accounts.active != accountInfo {
      os_log(
        "Unreachable server belongs to an inactive account -> offline mode not activated",
        log: self.log,
        type: .info
      )
      consecutiveConnectivityFailures = 0
      return
    }
    // set before any await so concurrent reports can't double-fire the notice
    isAutoOfflineActive = true
    var mutableSettings = settings
    mutableSettings.user.isOfflineMode = true
    // mark AFTER assigning isOfflineMode — its setter clears the flag
    mutableSettings.user.isOfflineModeAutomaticallyActivated = true
    os_log(
      "Server unreachable %i times in a row -> activating offline mode",
      log: self.log,
      type: .info,
      consecutiveConnectivityFailures
    )
    await notificationHandler.post(
      name: .offlineModeChanged,
      object: nil,
      userInfo: ["autoOffline": true]
    )
    await eventLogger.info(
      topic: "Connection",
      message: "Server unreachable - offline mode activated",
      displayPopup: true
    )
    startAutoRecoveryIfNeeded()
  }

  // MARK: Auto recovery (G16)

  /// True while offline mode is active *and* was auto-activated by this
  /// monitor — this launch (`isAutoOfflineActive`) or a previous one
  /// (the persisted flag survives app restarts).
  private var isInAutoOfflineState: Bool {
    settings.user.isOfflineMode && settings.user.isOfflineModeAutomaticallyActivated
  }

  /// Starts the recovery loop when offline mode was auto-activated. Called at
  /// `BackendProxy.initialize` (covers relaunch-while-auto-offline) and each
  /// time the latch fires. No-op for manual offline mode, while a loop is
  /// already running, or when no probe was injected (e.g. unit tests).
  func startAutoRecoveryIfNeeded() {
    guard isInAutoOfflineState, recoveryTask == nil, serverReachabilityProbe != nil
    else { return }
    os_log("Starting server recovery loop", log: self.log, type: .info)
    recoveryTask = Task { [weak self] in
      await self?.runRecoveryLoop()
    }
  }

  /// Cancels a running recovery loop (account teardown).
  func stopAutoRecovery() {
    recoveryTask?.cancel()
    recoveryTask = nil
  }

  private func runRecoveryLoop() async {
    defer { recoveryTask = nil }
    var attempt = 0
    while !Task.isCancelled {
      // user toggled back online manually or cleared the auto state -> done
      guard isInAutoOfflineState else { return }
      // only the account that tripped the latch may restore online mode — and
      // only while it still exists and remains the active account
      if let accountInfo {
        guard settings.accounts.allAccounts.contains(accountInfo),
              settings.accounts.active == accountInfo
        else {
          os_log(
            "Recovery aborted - account is gone or no longer active",
            log: self.log,
            type: .info
          )
          return
        }
      }
      // no network interface -> a probe would fail instantly; poll cheaply
      guard networkMonitor.isConnectedToNetwork else {
        await Self.sleep(seconds: disconnectedPollIntervalInSeconds)
        continue
      }
      if let reachableURL = await firstReachableServerURL() {
        await recoverOnlineMode(reachableURL: reachableURL)
        return
      }
      attempt += 1
      await Self.sleep(seconds: recoveryBackoffPolicy.delay(forRetryAttempt: attempt))
    }
  }

  private func firstReachableServerURL() async -> String? {
    guard let probe = serverReachabilityProbe else { return nil }
    for url in serverURLCandidatesProvider?() ?? [] {
      if Task.isCancelled { return nil }
      if await probe(url) {
        return url
      }
    }
    return nil
  }

  private func recoverOnlineMode(reachableURL: String) async {
    consecutiveConnectivityFailures = 0
    isAutoOfflineActive = false
    var mutableSettings = settings
    // the setter also clears isOfflineModeAutomaticallyActivated
    mutableSettings.user.isOfflineMode = false
    os_log(
      "Server reachable again -> restoring online mode",
      log: self.log,
      type: .info
    )
    // failover happens before the notification so observers (download
    // managers, syncers) already see the updated credentials
    await autoRecoveryHandler?(reachableURL)
    await notificationHandler.post(
      name: .offlineModeChanged,
      object: nil,
      userInfo: ["autoOnline": true]
    )
    await eventLogger.info(
      topic: "Connection",
      message: "Server reachable again - online mode activated",
      displayPopup: true
    )
  }

  private static func sleep(seconds: TimeInterval) async {
    try? await Task.sleep(for: .seconds(seconds))
  }
}
