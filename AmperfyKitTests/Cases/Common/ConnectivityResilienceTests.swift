//
//  ConnectivityResilienceTests.swift
//  AmperfyKitTests
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
@testable import AmperfyKit
import XCTest

// MARK: - StubNetworkMonitor

/// Controllable `NetworkMonitorFacade` for `ServerUnreachableMonitor` tests.
private final class StubNetworkMonitor: NetworkMonitorFacade {
  var connectionTypeChangedCB: ConnectionTypeChangedCallack?
  var isConnectedToNetwork = true
  var isCellular = false
  var isWifiOrEthernet = true
}

// MARK: - ConnectivityResilienceTests

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
}
