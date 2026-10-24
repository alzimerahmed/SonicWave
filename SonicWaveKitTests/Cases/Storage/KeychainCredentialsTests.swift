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
/// write failure to exercise the plaintext fallback / retry path.
private final class StubSecretsStore: CredentialSecretsStoring {
  private let storage = Atomic<[String: LoginCredentialSecrets]>(wrappedValue: [:])
  private let failSaves: Bool

  init(failSaves: Bool = false) {
    self.failSaves = failSaves
  }

  @discardableResult
  func save(secrets: LoginCredentialSecrets, accountIdent: String) -> Bool {
    if failSaves { return false }
    storage.wrappedValue[accountIdent] = secrets
    return true
  }

  func read(accountIdent: String) -> LoginCredentialSecrets? {
    storage.wrappedValue[accountIdent]
  }

  func delete(accountIdent: String) {
    storage.wrappedValue[accountIdent] = nil
  }
}

// MARK: - KeychainCredentialsTests

final class KeychainCredentialsTests: XCTestCase {
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

  func testKeychainHelperRoundTrip() {
    let keychain = KeychainHelper(service: "com.alzimerahmed.SonicWave.credentials.test")
    keychain.delete(account: "roundtrip")
    let secretData = Data("hunter2".utf8)

    XCTAssertEqual(keychain.save(data: secretData, account: "roundtrip"), errSecSuccess)
    XCTAssertEqual(keychain.read(account: "roundtrip"), secretData)

    // update path: second save overwrites
    let updatedData = Data("hunter3".utf8)
    XCTAssertEqual(keychain.save(data: updatedData, account: "roundtrip"), errSecSuccess)
    XCTAssertEqual(keychain.read(account: "roundtrip"), updatedData)

    XCTAssertEqual(keychain.delete(account: "roundtrip"), errSecSuccess)
    XCTAssertNil(keychain.read(account: "roundtrip"))
    // delete is idempotent — deleting a missing item reports success
    XCTAssertEqual(keychain.delete(account: "roundtrip"), errSecSuccess)
  }

  func testKeychainCredentialSecretsStoreRoundTrip() {
    let store = KeychainCredentialSecretsStore()
    store.delete(accountIdent: testAccountIdent)
    let secrets = LoginCredentialSecrets(
      password: "s3cret",
      httpHeaders: ["CF-Access-Client-Id": "id", "CF-Access-Client-Secret": "sec"]
    )
    XCTAssertTrue(store.save(secrets: secrets, accountIdent: testAccountIdent))
    let loaded = store.read(accountIdent: testAccountIdent)
    XCTAssertEqual(loaded?.password, secrets.password)
    XCTAssertEqual(loaded?.httpHeaders, secrets.httpHeaders)
    store.delete(accountIdent: testAccountIdent)
    XCTAssertNil(store.read(accountIdent: testAccountIdent))
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
    XCTAssertEqual(
      workingStore.read(accountIdent: testAccountIdent)?.password,
      testCredentials.password
    )

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
    XCTAssertNotNil(store.read(accountIdent: accountInfo.ident))

    storage.settings.accounts.logout(accountInfo)
    XCTAssertNil(store.read(accountIdent: accountInfo.ident))
  }
}
