//
//  KeychainCredentialsTests.swift
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

@testable import SonicWaveKit
import Foundation
import XCTest

// MARK: - StubSecretsStore

/// In-memory `CredentialSecretsStoring` — deterministic migration tests without
/// depending on the host app Keychain state. `failSaves` simulates a Keychain
/// write failure to exercise the plaintext fallback / retry path; `failReads`
/// simulates a locked Keychain (e.g. `errSecInteractionNotAllowed` before first
/// unlock) so reads report `.unavailable`.
private final class StubSecretsStore: CredentialSecretsStoring {
  private let storage = Atomic<[String: LoginCredentialSecrets]>(wrappedValue: [:])
  private let failSaves: Bool
  private let failReads: Bool
  /// how often `save` was invoked — used to prove a guarded encode never
  /// attempts a store write at all
  let saveCallCount = Atomic<Int>(wrappedValue: 0)

  init(failSaves: Bool = false, failReads: Bool = false) {
    self.failSaves = failSaves
    self.failReads = failReads
  }

  @discardableResult
  func save(secrets: LoginCredentialSecrets, accountIdent: String) -> Bool {
    saveCallCount.wrappedValue += 1
    if failSaves { return false }
    storage.wrappedValue[accountIdent] = secrets
    return true
  }

  func read(accountIdent: String) -> CredentialSecretsReadResult {
    if failReads { return .unavailable }
    if let secrets = storage.wrappedValue[accountIdent] {
      return .found(secrets)
    }
    return .notFound
  }

  func delete(accountIdent: String) {
    storage.wrappedValue[accountIdent] = nil
  }
}

// MARK: - KeychainCredentialsTests

@MainActor
final class KeychainCredentialsTests: XCTestCase {  /// hosted tests inside the unsigned app can't touch the keychain
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

  private var cdHelper: CoreDataHelper!
  private var storage: PersistentStorage!
  private var savedAccountSettingsData: Data?
  private var savedSecretsStore: CredentialSecretsStoring!

  private let testCredentials = LoginCredentials(
    serverUrl: "https://keychain-test.local/ampache",
    username: "keychain-test-user",
    password: "s3cret-P@ssw0rd",
    backendApi: .ampache
  )

  private var testAccountIdent: String {
    testCredentials.accountIdent
  }

  private var accountSettingsDefaultsKey: String {
    PersistentStorage.UserDefaultsKey.SettingsAccount.rawValue
  }

  override func setUp() async throws {
    try await super.setUp()
    cdHelper = CoreDataHelper()
    storage = PersistentStorage(
      coreDataManager: MOCK_CoreDataManager(persistentContainer: cdHelper.persistentContainer)
    )
    savedAccountSettingsData = UserDefaults.standard.data(forKey: accountSettingsDefaultsKey)
    savedSecretsStore = LoginCredentials.secretsStore
  }

  override func tearDown() async throws {
    LoginCredentials.secretsStore = savedSecretsStore
    LoginCredentials.deletePersistedSecrets(accountIdent: testAccountIdent)
    KeychainHelper(service: "com.alzimerahmed.SonicWave.credentials.test")
      .delete(account: "roundtrip")
    if let savedAccountSettingsData {
      UserDefaults.standard.set(savedAccountSettingsData, forKey: accountSettingsDefaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: accountSettingsDefaultsKey)
    }
    try await super.tearDown()
  }

  private func storedAccountDataContainsPlaintextSecrets() -> Bool {
    guard let data = UserDefaults.standard.data(forKey: accountSettingsDefaultsKey)
    else { return false }
    return PersistentStorage.storedAccountSettingsContainPlaintextSecrets(data)
  }

  // MARK: KeychainHelper

  func testKeychainHelperRoundTrip()  throws {
    try requireKeychainOrSkip(KeychainHelper(service: "probe"))
    let keychain = KeychainHelper(service: "com.alzimerahmed.SonicWave.credentials.test")
    keychain.delete(account: "roundtrip")
    let secretData = Data("hunter2".utf8)

    XCTAssertEqual(keychain.save(data: secretData, account: "roundtrip"), errSecSuccess)
    XCTAssertEqual(keychain.read(account: "roundtrip"), .success(secretData))

    // update path: second save overwrites
    let updatedData = Data("hunter3".utf8)
    XCTAssertEqual(keychain.save(data: updatedData, account: "roundtrip"), errSecSuccess)
    XCTAssertEqual(keychain.read(account: "roundtrip"), .success(updatedData))

    XCTAssertEqual(keychain.delete(account: "roundtrip"), errSecSuccess)
    XCTAssertEqual(keychain.read(account: "roundtrip"), .notFound)
    // delete is idempotent — deleting a missing item reports success
    XCTAssertEqual(keychain.delete(account: "roundtrip"), errSecSuccess)
  }

  func testKeychainCredentialSecretsStoreRoundTrip()  throws {
    try requireKeychainOrSkip(KeychainHelper(service: "probe"))
    let store = KeychainCredentialSecretsStore()
    store.delete(accountIdent: testAccountIdent)
    let secrets = LoginCredentialSecrets(
      password: "s3cret",
      httpHeaders: ["CF-Access-Client-Id": "id", "CF-Access-Client-Secret": "sec"]
    )
    XCTAssertTrue(store.save(secrets: secrets, accountIdent: testAccountIdent))
    guard case let .found(loaded) = store.read(accountIdent: testAccountIdent) else {
      XCTFail("secrets must be readable after save")
      return
    }
    XCTAssertEqual(loaded.password, secrets.password)
    XCTAssertEqual(loaded.httpHeaders, secrets.httpHeaders)
    store.delete(accountIdent: testAccountIdent)
    guard case .notFound = store.read(accountIdent: testAccountIdent) else {
      XCTFail("secrets store must report notFound after delete")
      return
    }
  }

  // MARK: Codable seam

  func testEncodeOmitsSecretsWhenStoreWriteSucceeds() throws {
    LoginCredentials.secretsStore = StubSecretsStore()
    var credentials = testCredentials
    credentials.httpHeaders = ["CF-Access-Client-Secret": "sec"]

    let data = try JSONEncoder().encode(credentials)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertNil(json["password"])
    XCTAssertNil(json["httpHeaders"])

    // decode reads secrets back from the store
    let decoded = try JSONDecoder().decode(LoginCredentials.self, from: data)
    XCTAssertEqual(decoded.password, credentials.password)
    XCTAssertEqual(decoded.httpHeaders, credentials.httpHeaders)
    XCTAssertEqual(decoded.serverUrl, credentials.serverUrl)
    XCTAssertEqual(decoded.username, credentials.username)
  }

  func testEncodeKeepsPlaintextFallbackWhenStoreWriteFails() throws {
    LoginCredentials.secretsStore = StubSecretsStore(failSaves: true)
    let data = try JSONEncoder().encode(testCredentials)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    // failure fallback keeps the credentials readable — migration retries later
    XCTAssertEqual(json["password"] as? String, testCredentials.password)

    let decoded = try JSONDecoder().decode(LoginCredentials.self, from: data)
    XCTAssertEqual(decoded.password, testCredentials.password)
  }

  /// Locked-Keychain regression (read failure, e.g. BGTask before first
  /// unlock): decode marks the instance `secretsReadFailed` and a re-encode
  /// must write NEITHER a Keychain overwrite NOR empty plaintext keys — the
  /// real secrets stay preserved in the store.
  func testEncodePreservesStoredSecretsWhenReadFailed() throws {
    // stage real secrets in a healthy store and produce the migrated payload
    // form (no inline secret keys)
    let healthyStore = StubSecretsStore()
    LoginCredentials.secretsStore = healthyStore
    healthyStore.save(
      secrets: LoginCredentialSecrets(
        password: testCredentials.password,
        httpHeaders: ["CF-Access-Client-Secret": "sec"]
      ),
      accountIdent: testAccountIdent
    )
    var credentials = testCredentials
    credentials.httpHeaders = ["CF-Access-Client-Secret": "sec"]
    let migratedData = try JSONEncoder().encode(credentials)
    let migratedJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )
    XCTAssertNil(migratedJSON["password"])
    XCTAssertNil(migratedJSON["httpHeaders"])

    // now reads fail (Keychain locked) -> decode marks the instance
    let failingStore = StubSecretsStore(failReads: true)
    LoginCredentials.secretsStore = failingStore
    let decoded = try JSONDecoder().decode(LoginCredentials.self, from: migratedData)
    XCTAssertTrue(decoded.secretsReadFailed)
    XCTAssertEqual(decoded.password, "")
    XCTAssertEqual(decoded.httpHeaders, [:])

    // re-encode: no Keychain overwrite, no plaintext fallback keys
    let reencodedData = try JSONEncoder().encode(decoded)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: reencodedData) as? [String: Any]
    )
    XCTAssertNil(json["password"])
    XCTAssertNil(json["httpHeaders"])
    XCTAssertEqual(failingStore.saveCallCount.wrappedValue, 0)
  }

  // MARK: Migration

  @MainActor
  func testMigrationMovesPlaintextSecretsToStore() async {
    // write a legacy payload: store refuses saves -> plaintext lands in UserDefaults
    LoginCredentials.secretsStore = StubSecretsStore(failSaves: true)
    storage.settings.accounts.login(testCredentials)
    XCTAssertTrue(storedAccountDataContainsPlaintextSecrets())

    // secrets store back online -> migrator must scrub the JSON
    let workingStore = StubSecretsStore()
    LoginCredentials.secretsStore = workingStore
    storage.applyCredentialsKeychainMigrationIfNeeded()
    XCTAssertFalse(storedAccountDataContainsPlaintextSecrets())
    guard case let .found(migratedSecrets) = workingStore
      .read(accountIdent: testAccountIdent)
    else {
      XCTFail("migrated secrets must be readable")
      return
    }
    XCTAssertEqual(migratedSecrets.password, testCredentials.password)

    // credentials still resolve correctly after the migration
    let accountInfo = Account.createInfo(credentials: testCredentials)
    let migrated = storage.settings.accounts.getSetting(accountInfo).read.loginCredentials
    XCTAssertEqual(migrated?.password, testCredentials.password)
    XCTAssertEqual(migrated?.username, testCredentials.username)

    // idempotent: second run is a no-op and changes nothing
    storage.applyCredentialsKeychainMigrationIfNeeded()
    XCTAssertFalse(storedAccountDataContainsPlaintextSecrets())
    XCTAssertEqual(
      storage.settings.accounts.getSetting(accountInfo).read.loginCredentials?.password,
      testCredentials.password
    )
  }

  @MainActor
  func testMigrationFailureLeavesCredentialsReadable() async {
    LoginCredentials.secretsStore = StubSecretsStore(failSaves: true)
    storage.settings.accounts.login(testCredentials)
    XCTAssertTrue(storedAccountDataContainsPlaintextSecrets())

    // store still failing -> migration must not strand the account
    storage.applyCredentialsKeychainMigrationIfNeeded()
    XCTAssertTrue(storedAccountDataContainsPlaintextSecrets())
    let accountInfo = Account.createInfo(credentials: testCredentials)
    XCTAssertEqual(
      storage.settings.accounts.getSetting(accountInfo).read.loginCredentials?.password,
      testCredentials.password
    )
  }

  @MainActor
  func testMigrationIsNoOpWithoutPlaintextSecrets() async {
    LoginCredentials.secretsStore = StubSecretsStore()
    storage.settings.accounts.login(testCredentials)
    XCTAssertFalse(storedAccountDataContainsPlaintextSecrets())
    storage.applyCredentialsKeychainMigrationIfNeeded()
    XCTAssertFalse(storedAccountDataContainsPlaintextSecrets())
  }

  // MARK: Logout

  func testLogoutDeletesPersistedSecrets() {
    let store = StubSecretsStore()
    LoginCredentials.secretsStore = store
    storage.settings.accounts.login(testCredentials)
    let accountInfo = Account.createInfo(credentials: testCredentials)
    guard case .found = store.read(accountIdent: accountInfo.ident) else {
      XCTFail("secrets must exist after login")
      return
    }

    storage.settings.accounts.logout(accountInfo)
    guard case .notFound = store.read(accountIdent: accountInfo.ident) else {
      XCTFail("secrets must be deleted after logout")
      return
    }
  }
}
