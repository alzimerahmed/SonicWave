//
//  ConnectivityResilienceTests.swift
//  SonicWaveKitTests
//
//  Created by Alzimer Ahmed on 24.10.26.
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

import Alamofire
@testable import SonicWaveKit
import XCTest

// MARK: - StubNetworkMonitor

/// Controllable `NetworkMonitorFacade` for `ServerUnreachableMonitor` tests.
private final class StubNetworkMonitor: NetworkMonitorFacade, @unchecked Sendable {
  var connectionTypeChangedCB: ConnectionTypeChangedCallack?
  var isConnectedToNetwork = true
  var isCellular = false
  var isWifiOrEthernet = true
}

// MARK: - ConnectivityResilienceTests

@MainActor
final class ConnectivityResilienceTests: XCTestCase {
  private var cdHelper: CoreDataHelper!
  private var eventLogger: EventLogger!
  private var settings: AmperfySettings!
  private var savedUserSettings: UserSettings!
  private var savedAccountSettings: AccountSettings!

  override func setUp() async throws {
    try await super.setUp()
    cdHelper = CoreDataHelper()
    let storage = PersistentStorage(
      coreDataManager: MOCK_CoreDataManager(persistentContainer: cdHelper.persistentContainer)
    )
    eventLogger = EventLogger(storage: storage)
    eventLogger.supressAlerts = true
    settings = AmperfySettings()
    savedUserSettings = settings.user
    savedAccountSettings = settings.accounts
    settings.user.isOfflineMode = false
  }

  override func tearDown() async throws {
    settings.user = savedUserSettings
    settings.accounts = savedAccountSettings
    try await super.tearDown()
  }

  private func makeMonitor(
    accountInfo: AccountInfo? = nil,
    isConnected: Bool = true
  ) -> ServerUnreachableMonitor {
    let stub = StubNetworkMonitor()
    stub.isConnectedToNetwork = isConnected
    return ServerUnreachableMonitor(
      networkMonitor: stub,
      eventLogger: eventLogger,
      settings: settings,
      accountInfo: accountInfo,
      notificationHandler: EventNotificationHandler()
    )
  }

  private func makeRecoveryMonitor(
    accountInfo: AccountInfo? = nil,
    isConnected: Bool = true,
    urls: [String] = ["https://primary.example"],
    probe: @escaping @Sendable (String) async -> Bool,
    onRecovered: (@Sendable (String) async -> ())? = nil
  ) -> ServerUnreachableMonitor {
    let stub = StubNetworkMonitor()
    stub.isConnectedToNetwork = isConnected
    return ServerUnreachableMonitor(
      networkMonitor: stub,
      eventLogger: eventLogger,
      settings: settings,
      accountInfo: accountInfo,
      notificationHandler: EventNotificationHandler(),
      serverURLCandidatesProvider: { urls },
      serverReachabilityProbe: probe,
      autoRecoveryHandler: onRecovered,
      recoveryBackoffPolicy: ConnectivityBackoffPolicy(
        baseDelayInSeconds: 0.01,
        multiplier: 1.0,
        maxDelayInSeconds: 0.02,
        jitterFactor: 0
      ),
      disconnectedPollIntervalInSeconds: 0.01
    )
  }

  /// Marks the settings as auto-offline the same way the monitor does when the
  /// latch fires (flag must be assigned *after* isOfflineMode — its setter
  /// clears it).
  private func enterAutoOffline() {
    settings.user.isOfflineMode = true
    settings.user.isOfflineModeAutomaticallyActivated = true
  }

  // MARK: RequestFailureKind

  func testClassifyConnectivityUrlErrors() {
    let codes: [URLError.Code] = [
      .timedOut,
      .cannotFindHost,
      .cannotConnectToHost,
      .networkConnectionLost,
      .dnsLookupFailed,
      .notConnectedToInternet,
    ]
    for code in codes {
      guard case .connectivity = RequestFailureKind.classify(error: URLError(code)) else {
        XCTFail("URLError.\(code) must classify as connectivity")
        continue
      }
    }
  }

  func testClassifyAlamofireWrappedConnectivityError() {
    let afError = AFError.sessionTaskFailed(error: URLError(.cannotConnectToHost))
    guard case .connectivity = RequestFailureKind.classify(error: afError) else {
      XCTFail("AFError wrapping a connectivity URLError must classify as connectivity")
      return
    }
  }

  func testClassifyCancellation() {
    guard case .cancellation = RequestFailureKind.classify(error: CancellationError()) else {
      XCTFail("CancellationError must classify as cancellation")
      return
    }
    guard case .cancellation = RequestFailureKind.classify(error: URLError(.cancelled)) else {
      XCTFail("URLError.cancelled must classify as cancellation")
      return
    }
  }

  func testClassifyNonConnectivity() {
    // answered by the server (HTTP status error) -> proves reachability
    guard case .nonConnectivity = RequestFailureKind
      .classify(error: URLError(.badServerResponse))
    else {
      XCTFail("URLError.badServerResponse must classify as nonConnectivity")
      return
    }
    guard case .nonConnectivity = RequestFailureKind
      .classify(error: AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: 500)))
    else {
      XCTFail("AFError.responseValidationFailed must classify as nonConnectivity")
      return
    }
  }

  func testClassifyTlsFailures() {
    // certificate-validation failures are their own kind: NOT connectivity
    // (the peer was reached — must not trip auto-offline) and NOT reachable
    // evidence (a MITM must not satisfy the recovery probe / exit offline mode)
    let codes: [URLError.Code] = [
      .serverCertificateHasBadDate,
      .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot,
      .serverCertificateNotYetValid,
      .clientCertificateRejected,
      .clientCertificateRequired,
    ]
    for code in codes {
      guard case .tlsFailure = RequestFailureKind.classify(error: URLError(code)) else {
        XCTFail("URLError.\(code) must classify as tlsFailure")
        continue
      }
    }
    // Alamofire wraps URLSession errors in .sessionTaskFailed
    let afError = AFError.sessionTaskFailed(error: URLError(.serverCertificateUntrusted))
    guard case .tlsFailure = RequestFailureKind.classify(error: afError) else {
      XCTFail("AFError wrapping a TLS URLError must classify as tlsFailure")
      return
    }
  }

  // MARK: ConnectivityBackoffPolicy

  func testBackoffDelayWithinJitterBounds() {
    let policy = ConnectivityBackoffPolicy()
    let expectedBaseDelay = [1.0, 2.0, 4.0]
    for (index, base) in expectedBaseDelay.enumerated() {
      for _ in 0 ..< 100 {
        let delay = policy.delay(forRetryAttempt: index + 1)
        XCTAssertGreaterThanOrEqual(delay, base * 0.75)
        XCTAssertLessThanOrEqual(delay, base * 1.25)
      }
    }
  }

  func testBackoffCapsAtMaxDelay() {
    let policy = ConnectivityBackoffPolicy()
    for _ in 0 ..< 200 {
      let delay = policy.delay(forRetryAttempt: 10)
      XCTAssertGreaterThanOrEqual(delay, 0.1)
      XCTAssertLessThanOrEqual(delay, policy.maxDelayInSeconds * 1.25)
    }
  }

  // MARK: ServerUnreachableMonitor

  func testAutoOfflineAfterThreshold() async {
    let monitor = makeMonitor()
    for _ in 0 ..< ServerUnreachableMonitor.consecutiveFailuresThreshold {
      await monitor.reportConnectivityFailure()
    }
    XCTAssertTrue(settings.user.isOfflineMode)
  }

  func testNoAutoOfflineBelowThreshold() async {
    let monitor = makeMonitor()
    for _ in 0 ..< ServerUnreachableMonitor.consecutiveFailuresThreshold - 1 {
      await monitor.reportConnectivityFailure()
    }
    XCTAssertFalse(settings.user.isOfflineMode)
  }

  func testServerResponseResetsFailureCounter() async {
    let monitor = makeMonitor()
    for _ in 0 ..< 2 {
      await monitor.reportConnectivityFailure()
    }
    await monitor.reportServerResponded()
    for _ in 0 ..< 2 {
      await monitor.reportConnectivityFailure()
    }
    XCTAssertFalse(settings.user.isOfflineMode)
    await monitor.reportConnectivityFailure()
    XCTAssertTrue(settings.user.isOfflineMode)
  }

  func testNoAutoOfflineWithoutNetwork() async {
    let monitor = makeMonitor(isConnected: false)
    for _ in 0 ..< 10 {
      await monitor.reportConnectivityFailure()
    }
    XCTAssertFalse(settings.user.isOfflineMode)
  }

  func testInactiveAccountDoesNotTriggerAutoOffline() async {
    settings.accounts.switchActiveAccount(TestAccountInfo.create1())
    let monitor = makeMonitor(accountInfo: TestAccountInfo.create2())
    for _ in 0 ..< 5 {
      await monitor.reportConnectivityFailure()
    }
    XCTAssertFalse(settings.user.isOfflineMode)
  }

  func testActiveAccountTriggersAutoOffline() async {
    let accountInfo = TestAccountInfo.create1()
    settings.accounts.switchActiveAccount(accountInfo)
    let monitor = makeMonitor(accountInfo: accountInfo)
    for _ in 0 ..< ServerUnreachableMonitor.consecutiveFailuresThreshold {
      await monitor.reportConnectivityFailure()
    }
    XCTAssertTrue(settings.user.isOfflineMode)
  }

  // MARK: Auto recovery (G16)

  func testRecoveryLoopRestoresOnlineMode() async {
    let recoveredURL = Atomic<String?>(wrappedValue: nil)
    let monitor = makeRecoveryMonitor(
      urls: ["https://primary.example"],
      probe: { _ in true },
      onRecovered: { url in recoveredURL.wrappedValue = url }
    )
    enterAutoOffline()
    await monitor.startAutoRecoveryIfNeeded()
    try? await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(settings.user.isOfflineMode)
    XCTAssertFalse(settings.user.isOfflineModeAutomaticallyActivated)
    XCTAssertEqual(recoveredURL.wrappedValue, "https://primary.example")
  }

  func testRecoveryFailoverToAlternativeURL() async {
    let recoveredURL = Atomic<String?>(wrappedValue: nil)
    let monitor = makeRecoveryMonitor(
      urls: ["https://primary.example", "https://alt.example"],
      probe: { url in url == "https://alt.example" },
      onRecovered: { url in recoveredURL.wrappedValue = url }
    )
    enterAutoOffline()
    await monitor.startAutoRecoveryIfNeeded()
    try? await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(recoveredURL.wrappedValue, "https://alt.example")
    XCTAssertFalse(settings.user.isOfflineMode)
  }

  func testRecoveryKeepsWaitingOnDeadServer() async {
    let monitor = makeRecoveryMonitor(
      urls: ["https://dead.example"],
      probe: { _ in false }
    )
    enterAutoOffline()
    await monitor.startAutoRecoveryIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(settings.user.isOfflineMode)
    XCTAssertTrue(settings.user.isOfflineModeAutomaticallyActivated)
  }

  func testManualOfflineIsNotAutoRecovered() async {
    let monitor = makeRecoveryMonitor(
      urls: ["https://primary.example"],
      probe: { _ in true }
    )
    // manual offline -> the auto flag is cleared by the setter
    settings.user.isOfflineMode = true
    XCTAssertFalse(settings.user.isOfflineModeAutomaticallyActivated)
    await monitor.startAutoRecoveryIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(settings.user.isOfflineMode)
  }

  func testRecoveryOnlyRunsForActiveAccount() async {
    let accountInfo = TestAccountInfo.create1()
    let otherAccount = TestAccountInfo.create2()
    settings.accounts.updateSetting(accountInfo) { _ in }
    settings.accounts.updateSetting(otherAccount) { _ in }
    // monitor belongs to account 1 but account 2 is active -> no recovery
    settings.accounts.switchActiveAccount(otherAccount)
    let monitor = makeRecoveryMonitor(
      accountInfo: accountInfo,
      urls: ["https://primary.example"],
      probe: { _ in true }
    )
    enterAutoOffline()
    await monitor.startAutoRecoveryIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(settings.user.isOfflineMode)
  }

  func testRecoveryForActiveAccount() async {
    let accountInfo = TestAccountInfo.create1()
    settings.accounts.updateSetting(accountInfo) { _ in }
    settings.accounts.switchActiveAccount(accountInfo)
    let monitor = makeRecoveryMonitor(
      accountInfo: accountInfo,
      urls: ["https://primary.example"],
      probe: { _ in true }
    )
    enterAutoOffline()
    await monitor.startAutoRecoveryIfNeeded()
    try? await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(settings.user.isOfflineMode)
  }
}
