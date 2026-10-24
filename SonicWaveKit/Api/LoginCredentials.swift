//
//  LoginCredentials.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.03.19.
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

// MARK: - LoginCredentialSecrets

/// Secret material of `LoginCredentials` that must never land inside the
/// UserDefaults-backed settings JSON: the account password and the custom
/// HTTP headers (they can carry e.g. Cloudflare Access service tokens).
struct LoginCredentialSecrets: Sendable, Codable {
  var password: String = ""
  var httpHeaders: [String: String] = [:]
}

// MARK: - CredentialSecretsStoring

/// Persistence boundary for `LoginCredentialSecrets`. Injectable in tests via
/// `LoginCredentials.secretsStore`.
protocol CredentialSecretsStoring: Sendable {
  /// Returns true when the secrets were durably stored.
  @discardableResult
  func save(secrets: LoginCredentialSecrets, accountIdent: String) -> Bool
  func read(accountIdent: String) -> LoginCredentialSecrets?
  func delete(accountIdent: String)
}

// MARK: - KeychainCredentialSecretsStore

/// Keychain-backed secrets store — one generic-password item per account,
/// value = JSON-encoded `LoginCredentialSecrets`.
struct KeychainCredentialSecretsStore: CredentialSecretsStoring {
  static let service = "com.alzimerahmed.SonicWave.credentials"
  private let keychain = KeychainHelper(service: Self.service)

  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  @discardableResult
  func save(secrets: LoginCredentialSecrets, accountIdent: String) -> Bool {
    guard let data = try? Self.encoder.encode(secrets) else { return false }
    return keychain.save(data: data, account: accountIdent) == errSecSuccess
  }

  func read(accountIdent: String) -> LoginCredentialSecrets? {
    guard let data = keychain.read(account: accountIdent) else { return nil }
    return try? Self.decoder.decode(LoginCredentialSecrets.self, from: data)
  }

  func delete(accountIdent: String) {
    keychain.delete(account: accountIdent)
  }
}

// MARK: - LoginCredentials

public struct LoginCredentials: Sendable, Codable {
  private enum CodingKeys: String, CodingKey {
    case serverUrl
    case username
    case password
    case backendApi
    case activeBackendServerUrl
    case alternativeServerURLs
    case httpHeaders
  }

  private static let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "LoginCredentials"
  )

  /// Persistence for the credential secrets (`password` + `httpHeaders`).
  /// `nonisolated(unsafe)` so tests can inject a stub store — production code
  /// always uses the Keychain-backed default.
  nonisolated(unsafe) static var secretsStore: CredentialSecretsStoring =
    KeychainCredentialSecretsStore()

  /// Stable Keychain account key — identical to the `AccountInfo` identity
  /// derived from serverUrl + username, so `AccountSettings.logout` can drop
  /// the secrets via the same key.
  var accountIdent: String {
    Account.createInfo(
      serverUrl: serverUrl,
      userName: username,
      apiType: backendApi
    ).ident
  }

  /// Drop persisted secrets for the given account identity (logout).
  static func deletePersistedSecrets(accountIdent: String) {
    secretsStore.delete(accountIdent: accountIdent)
  }

  public var serverUrl: String
  public var username: String
  public var password: String
  public var passwordHash: String
  public var backendApi: BackenApiType
  public var activeBackendServerUrl: String
  public var alternativeServerURLs: [String]
  /// Custom HTTP headers sent with every request to the server. Used e.g. to provide a
  /// Cloudflare Access service token (CF-Access-Client-Id / CF-Access-Client-Secret) so that
  /// the connection bypasses an interactive Zero Trust policy.
  public var httpHeaders: [String: String]

  public init() {
    self.serverUrl = ""
    self.username = ""
    self.password = ""
    self.passwordHash = ""
    self.backendApi = .notDetected
    self.activeBackendServerUrl = ""
    self.alternativeServerURLs = []
    self.httpHeaders = [:]
  }

  public var displayServerUrl: String {
    guard let url = URL(string: serverUrl),
          let host = url.host else {
      return ""
    }
    if let port = url.port {
      return "\(host):\(port)"
    }
    return host
  }

  public var availableServerURLs: [String] {
    var availableURLs = alternativeServerURLs
    availableURLs.insert(serverUrl, at: 0)
    return availableURLs
  }

  public init(serverUrl: String, username: String, password: String) {
    self.serverUrl = serverUrl
    self.username = username
    self.password = password
    self.passwordHash = StringHasher.sha256(dataString: password)
    self.backendApi = .notDetected
    self.activeBackendServerUrl = serverUrl
    self.alternativeServerURLs = []
    self.httpHeaders = [:]
  }

  public init(serverUrl: String, username: String, password: String, backendApi: BackenApiType) {
    self.init(serverUrl: serverUrl, username: username, password: password)
    self.backendApi = backendApi
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.serverUrl = try container.decode(String.self, forKey: .serverUrl)
    self.username = try container.decode(String.self, forKey: .username)
    self.backendApi = try container
      .decodeIfPresent(BackenApiType.self, forKey: .backendApi) ?? .notDetected
    self.activeBackendServerUrl = try container.decodeIfPresent(
      String.self,
      forKey: .activeBackendServerUrl
    ) ?? serverUrl
    self.alternativeServerURLs = try container.decodeIfPresent(
      [String].self,
      forKey: .alternativeServerURLs
    ) ?? []

    // Secrets: pre-Keychain payloads carry `password`/`httpHeaders` inline;
    // migrated payloads omit them and store them in the Keychain instead.
    // NOTE: computed from the decoded fields directly — `accountIdent` (a
    // computed property on self) can't run until `passwordHash` is set below.
    let decodedAccountIdent = Account.createInfo(
      serverUrl: serverUrl,
      userName: username,
      apiType: backendApi
    ).ident
    if container.contains(.password) || container.contains(.httpHeaders) {
      let inlineSecrets = LoginCredentialSecrets(
        password: try container.decodeIfPresent(String.self, forKey: .password) ?? "",
        httpHeaders: try container.decodeIfPresent([String: String].self, forKey: .httpHeaders)
          ?? [:]
      )
      self.password = inlineSecrets.password
      self.httpHeaders = inlineSecrets.httpHeaders
      // Lazily re-home the secrets — the next encode then drops them from JSON.
      if !Self.secretsStore.save(secrets: inlineSecrets, accountIdent: decodedAccountIdent) {
        os_log(
          "Could not move credential secrets of account %s to the Keychain yet — will retry",
          log: Self.log,
          type: .error,
          decodedAccountIdent
        )
      }
    } else if let storedSecrets = Self.secretsStore.read(accountIdent: decodedAccountIdent) {
      self.password = storedSecrets.password
      self.httpHeaders = storedSecrets.httpHeaders
    } else {
      // The account stays logged in structurally but cannot authenticate; the
      // user has to re-enter the password. Never trap here.
      self.password = ""
      self.httpHeaders = [:]
      os_log(
        "No credential secrets found in the Keychain for account %s",
        log: Self.log,
        type: .error,
        decodedAccountIdent
      )
    }
    self.passwordHash = StringHasher.sha256(dataString: password)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(serverUrl, forKey: .serverUrl)
    try container.encode(username, forKey: .username)
    try container.encode(backendApi, forKey: .backendApi)
    try container.encode(activeBackendServerUrl, forKey: .activeBackendServerUrl)
    try container.encode(alternativeServerURLs, forKey: .alternativeServerURLs)
    let secrets = LoginCredentialSecrets(password: password, httpHeaders: httpHeaders)
    if Self.secretsStore.save(secrets: secrets, accountIdent: accountIdent) {
      // Secrets live in the Keychain — keep them out of the UserDefaults JSON.
    } else {
      // Fallback: keep the legacy plaintext keys so the credentials stay
      // readable; the next encode / the launch migrator retries the move.
      os_log(
        "Could not persist credential secrets of account %s in the Keychain — keeping plaintext fallback",
        log: Self.log,
        type: .error,
        accountIdent
      )
      try container.encode(password, forKey: .password)
      try container.encode(httpHeaders, forKey: .httpHeaders)
    }
  }

  public mutating func changePasswordAndHash(password newPassword: String) {
    password = newPassword
    passwordHash = StringHasher.sha256(dataString: newPassword)
  }
}
