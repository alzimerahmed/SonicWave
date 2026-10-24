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

// MARK: - CredentialSecretsReadResult

/// Result of reading credential secrets from the secrets store.
enum CredentialSecretsReadResult: Sendable {
  /// Secrets were read successfully.
  case found(LoginCredentialSecrets)
  /// The store is intact but holds no secrets for this account — a legitimate
  /// empty state (e.g. the user never completed a login).
  case notFound
  /// The read itself failed (e.g. `errSecInteractionNotAllowed` while the
  /// Keychain is locked before first unlock). Secrets may still exist in the
  /// store — they must be preserved, never overwritten with empty values.
  case unavailable
}

// MARK: - CredentialSecretsStoring

/// Persistence boundary for `LoginCredentialSecrets`. Injectable in tests via
/// `LoginCredentials.secretsStore`.
protocol CredentialSecretsStoring: Sendable {
  /// Returns true when the secrets were durably stored.
  @discardableResult
  func save(secrets: LoginCredentialSecrets, accountIdent: String) -> Bool
  func read(accountIdent: String) -> CredentialSecretsReadResult
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

  func read(accountIdent: String) -> CredentialSecretsReadResult {
    switch keychain.read(account: accountIdent) {
    case let .success(data):
      guard let secrets = try? Self.decoder.decode(LoginCredentialSecrets.self, from: data)
      else {
        // Undecodable blob -> corrupt data; do not pretend the store is empty,
        // overwriting it with empty secrets would destroy what is stored.
        return .unavailable
      }
      return .found(secrets)
    case .notFound:
      return .notFound
    case .failure:
      return .unavailable
    }
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
    case allowUntrustedServerCertificates
  }

  private static let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "LoginCredentials"
  )

  /// Persistence for the credential secrets (`password` + `httpHeaders`).
  /// `nonisolated(unsafe)` so tests can inject a stub store — production code
  /// always uses the Keychain-backed default.
  /// WARNING: test seam only. Reassigning this outside tests while credential
  /// instances are alive can split secrets across stores or strand writes —
  /// never mutate in production code.
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

  /// Drop persisted secrets and TLS material for the given account identity
  /// (logout): credential secrets, imported client certificate and all pinned
  /// self-signed server certificates.
  static func deletePersistedSecrets(accountIdent: String) {
    secretsStore.delete(accountIdent: accountIdent)
    ClientCertificateStore().delete(accountIdent: accountIdent)
    ServerCertificatePinStore().deleteAll(accountIdent: accountIdent)
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
  /// Opt-in: allow server certificates that fail the default system validation
  /// (e.g. self-signed). Not a trust-all switch — the leaf public key is pinned
  /// on first contact (TOFU) via `ServerCertificatePinStore` and a later
  /// mismatch rejects the connection until the user resets the pin.
  public var allowUntrustedServerCertificates: Bool
  /// True when a client certificate (.p12/.pfx for mTLS) is installed for this
  /// account — read live from the Keychain so it can never go stale.
  public var isClientCertificateInstalled: Bool {
    ClientCertificateStore().isInstalled(accountIdent: accountIdent)
  }

  /// Transient flag — never persisted (not part of `CodingKeys`): set when
  /// decoding could not READ the secrets store (e.g. `errSecInteractionNotAllowed`
  /// while the Keychain is locked before first unlock during a BGTask or
  /// background-URLSession launch). While set, `encode(to:)` writes neither a
  /// Keychain overwrite nor plaintext fallback keys, so the secrets that may
  /// still exist in the store are preserved until a healthy decode.
  var secretsReadFailed = false

  public init() {
    self.serverUrl = ""
    self.username = ""
    self.password = ""
    self.passwordHash = ""
    self.backendApi = .notDetected
    self.activeBackendServerUrl = ""
    self.alternativeServerURLs = []
    self.httpHeaders = [:]
    self.allowUntrustedServerCertificates = false
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
    self.allowUntrustedServerCertificates = false
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
    self.allowUntrustedServerCertificates = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowUntrustedServerCertificates
    ) ?? false

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
    } else {
      switch Self.secretsStore.read(accountIdent: decodedAccountIdent) {
      case let .found(storedSecrets):
        self.password = storedSecrets.password
        self.httpHeaders = storedSecrets.httpHeaders
      case .notFound:
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
      case .unavailable:
        // Transient store failure (e.g. Keychain locked before first unlock):
        // secrets may still exist in the store. Keep them empty in memory but
        // mark the instance so encode() preserves the stored blob instead of
        // overwriting it with empty secrets or writing empty plaintext.
        self.password = ""
        self.httpHeaders = [:]
        self.secretsReadFailed = true
        os_log(
          "Credential secrets of account %s could not be read (store unavailable) — preserving stored secrets",
          log: Self.log,
          type: .error,
          decodedAccountIdent
        )
      }
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
    try container.encode(
      allowUntrustedServerCertificates,
      forKey: .allowUntrustedServerCertificates
    )
    // Transient read failure at decode left no usable secrets in memory —
    // saving would overwrite a possibly intact Keychain blob with empty
    // secrets and the fallback would write empty plaintext into UserDefaults.
    // Skip both so the stored secrets survive until a healthy decode.
    if !secretsReadFailed {
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
  }

  public mutating func changePasswordAndHash(password newPassword: String) {
    password = newPassword
    passwordHash = StringHasher.sha256(dataString: newPassword)
    // a fresh in-memory secret exists again -> normal persistence applies
    secretsReadFailed = false
  }
}
