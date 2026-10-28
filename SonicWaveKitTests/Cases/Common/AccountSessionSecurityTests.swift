//
//  AccountSessionSecurityTests.swift
//  SonicWaveKitTests
//
//  Created by Alzimer Ahmed on 27.10.26.
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

@testable import SonicWaveKit
import Foundation
import XCTest

// MARK: - StubChallengeSender

/// Minimal `URLAuthenticationChallengeSender` — fabricated challenges are only
/// inspected, never answered through the sender.
private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender,
  @unchecked Sendable {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
}

// MARK: - AccountSessionSecurityTests

final class AccountSessionSecurityTests: XCTestCase {  /// hosted tests inside the unsigned app can't touch the keychain
  /// (`errSecMissingEntitlement` -34018) — skip rather than fake success;
  /// real devices/signing still exercise these paths
  private func requireKeychainOrSkip(
    _ keychain: KeychainHelper
  ) throws {
    let status = keychain.save(data: Data([0x01]), account: "probe")
    guard status == errSecSuccess else {
      keychain.delete(account: "probe")
      throw XCTSkip("keychain unavailable in unsigned test host (OSStatus \(status))")
    }
    keychain.delete(account: "probe")
  }

  private let pinStore = ServerCertificatePinStore()
  private let clientCertificateStore = ClientCertificateStore()
  private let accountIdent = TestAccountInfo.create1().ident

  override func tearDown() async throws {
    pinStore.deleteAll(accountIdent: accountIdent)
    clientCertificateStore.delete(accountIdent: testAccountIdent)
    try await super.tearDown()
  }

  // MARK: ServerCertificatePinStore

  func testPinStoreRoundTrip()  throws {
    try requireKeychainOrSkip(KeychainHelper(service: "probe"))
    pinStore.deleteAll(accountIdent: accountIdent)
    XCTAssertNil(pinStore.pinnedHash(accountIdent: accountIdent, host: "SelfSigned.Example"))

    XCTAssertTrue(
      pinStore.setPinnedHash(accountIdent: accountIdent, host: "SelfSigned.Example", hash: "ab12")
    )
    // host lookup is case-insensitive (pins are keyed on lowercased hosts)
    XCTAssertEqual(
      pinStore.pinnedHash(accountIdent: accountIdent, host: "selfsigned.example"),
      "ab12"
    )
    // a different host has no pin
    XCTAssertNil(pinStore.pinnedHash(accountIdent: accountIdent, host: "other.example"))
  }

  func testPinStoreMismatchDetection()  throws {
    try requireKeychainOrSkip(KeychainHelper(service: "probe"))
    pinStore.deleteAll(accountIdent: accountIdent)
    pinStore.setPinnedHash(accountIdent: accountIdent, host: "s.example", hash: "pin-a")
    // a rotated/attacked certificate presents a different hash -> mismatch
    XCTAssertNotEqual(
      pinStore.pinnedHash(accountIdent: accountIdent, host: "s.example"),
      "pin-b"
    )
    // overwriting (user reset) rotates the pin
    pinStore.setPinnedHash(accountIdent: accountIdent, host: "s.example", hash: "pin-b")
    XCTAssertEqual(
      pinStore.pinnedHash(accountIdent: accountIdent, host: "s.example"),
      "pin-b"
    )
  }

  func testPinStoreDeleteAll() {
    pinStore.setPinnedHash(accountIdent: accountIdent, host: "a.example", hash: "1")
    pinStore.setPinnedHash(accountIdent: accountIdent, host: "b.example", hash: "2")
    pinStore.deleteAll(accountIdent: accountIdent)
    XCTAssertNil(pinStore.pinnedHash(accountIdent: accountIdent, host: "a.example"))
    XCTAssertNil(pinStore.pinnedHash(accountIdent: accountIdent, host: "b.example"))
  }

  // MARK: Challenge scoping (isConfiguredServerHost)

  private var testAccountIdent: String {
    configuredCredentials().accountIdent
  }

  private func configuredCredentials() -> LoginCredentials {
    var credentials = LoginCredentials(
      serverUrl: "https://trusted.example",
      username: "u",
      password: "p"
    )
    credentials.alternativeServerURLs = ["https://alt.example"]
    credentials.allowUntrustedServerCertificates = true
    return credentials
  }

  private func configuredSecurity() -> AccountSessionSecurity {
    let security = AccountSessionSecurity()
    security.provideCredentials(configuredCredentials())
    return security
  }

  private func makeChallenge(
    host: String,
    authenticationMethod: String
  ) -> URLAuthenticationChallenge {
    let protectionSpace = URLProtectionSpace(
      host: host,
      port: 443,
      protocol: "https",
      realm: nil,
      authenticationMethod: authenticationMethod
    )
    return URLAuthenticationChallenge(
      protectionSpace: protectionSpace,
      proposedCredential: nil,
      previousFailureCount: 0,
      failureResponse: nil,
      error: nil,
      sender: StubChallengeSender()
    )
  }

  /// A client-certificate challenge must never be answered for a foreign
  /// host — the mTLS identity must not leak to redirected/unknown endpoints.
  func testClientCertificateNotOfferedToForeignHost() {
    clientCertificateStore.delete(accountIdent: testAccountIdent)
    let security = configuredSecurity()
    let challenge = makeChallenge(
      host: "evil.example",
      authenticationMethod: NSURLAuthenticationMethodClientCertificate
    )
    XCTAssertNil(security.evaluateChallenge(challenge))
  }

  /// No client certificate is installed in the test Keychain — even a
  /// configured host must get nil (default handling) rather than a fabricated
  /// credential.
  func testClientCertificateChallengeWithoutInstalledCert() {
    clientCertificateStore.delete(accountIdent: testAccountIdent)
    let security = configuredSecurity()
    let challenge = makeChallenge(
      host: "trusted.example",
      authenticationMethod: NSURLAuthenticationMethodClientCertificate
    )
    XCTAssertNil(security.evaluateChallenge(challenge))
  }

  /// Server-trust challenges for hosts outside the configured URL set fall
  /// back to default handling — the account's TOFU pins are never applied to
  /// foreign hosts reached via redirects.
  func testServerTrustChallengeIgnoredForForeignHost() {
    let security = configuredSecurity()
    let challenge = makeChallenge(
      host: "evil.example",
      authenticationMethod: NSURLAuthenticationMethodServerTrust
    )
    XCTAssertNil(security.evaluateChallenge(challenge))
  }

  /// Without the `allowUntrustedServerCertificates` opt-in the TOFU path is
  /// never engaged — even a configured host falls back to default handling.
  func testServerTrustChallengeIgnoredWithoutOptIn() {
    let security = AccountSessionSecurity()
    var credentials = configuredCredentials()
    credentials.allowUntrustedServerCertificates = false
    security.provideCredentials(credentials)
    let challenge = makeChallenge(
      host: "trusted.example",
      authenticationMethod: NSURLAuthenticationMethodServerTrust
    )
    XCTAssertNil(security.evaluateChallenge(challenge))
  }
}
