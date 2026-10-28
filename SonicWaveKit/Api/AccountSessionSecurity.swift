//
//  AccountSessionSecurity.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 25.10.26.
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
import CryptoKit
import Foundation
import os.log
import Security

// MARK: - ClientCertificateImportResult

/// Outcome of importing a PKCS#12 client certificate for an account.
public enum ClientCertificateImportResult: Sendable {
  /// The .p12/.pfx was valid (identity importable) and got stored in the Keychain.
  case success
  /// The file could not be opened as PKCS#12 or the passphrase was wrong.
  case invalidPassphraseOrData
  /// The Keychain refused to persist the blob.
  case keychainFailure
  /// The caller could not determine which account the certificate belongs to.
  case unknownAccount
}

// MARK: - ClientCertificateStore

/// Persists a per-account PKCS#12 client certificate (mTLS) in the Keychain.
///
/// The raw .p12/.pfx blob plus its passphrase are stored as one JSON payload in
/// a `kSecClassGenericPassword` item under a dedicated service (sibling to the
/// credential secrets store introduced with the Keychain migration). The
/// `SecIdentity` is imported on demand via `SecPKCS12Import` whenever a server
/// issues a client-certificate challenge — the identity is never imported into
/// the system identity keychain and never lands in UserDefaults.
public struct ClientCertificateStore: Sendable {
  static let service = "com.alzimerahmed.SonicWave.clientcert"
  private let keychain = KeychainHelper(service: Self.service)

  private struct Payload: Codable {
    var pkcs12: Data
    var passphrase: String
  }

  public init() {}

  public func isInstalled(accountIdent: String) -> Bool {
    if case .success = keychain.read(account: accountIdent) {
      return true
    }
    return false
  }

  /// Validates the PKCS#12 container + passphrase, then persists them.
  /// Returns `invalidPassphraseOrData` without touching the Keychain when the
  /// identity cannot be imported, so a wrong password never clobbers a working
  /// certificate.
  @discardableResult
  public func save(
    pkcs12Data: Data,
    passphrase: String,
    accountIdent: String
  ) -> ClientCertificateImportResult {
    guard Self.importIdentity(pkcs12Data: pkcs12Data, passphrase: passphrase) != nil else {
      return .invalidPassphraseOrData
    }
    guard let blob = try? JSONEncoder()
      .encode(Payload(pkcs12: pkcs12Data, passphrase: passphrase))
    else { return .keychainFailure }
    return keychain.save(data: blob, account: accountIdent) == errSecSuccess
      ? .success
      : .keychainFailure
  }

  public func delete(accountIdent: String) {
    keychain.delete(account: accountIdent)
  }

  /// Imports the stored identity for one challenge. `SecPKCS12Import` is marked
  /// deprecated but remains the only public PKCS#12 import API on iOS
  /// (`SecItemImport` is macOS-only) — the deprecation is cosmetic.
  func identity(accountIdent: String) -> (SecIdentity, [SecCertificate])? {
    guard case let .success(data) = keychain.read(account: accountIdent),
          let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return nil }
    return Self.importIdentity(pkcs12Data: payload.pkcs12, passphrase: payload.passphrase)
  }

  static func importIdentity(
    pkcs12Data: Data,
    passphrase: String
  ) -> (SecIdentity, [SecCertificate])? {
    var items: CFArray?
    let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
    let status = SecPKCS12Import(pkcs12Data as CFData, options, &items)
    guard status == errSecSuccess,
          let item = (items as? [[String: Any]])?.first,
          item[kSecImportItemIdentity as String] != nil
    else { return nil }
    // SecPKCS12Import guarantees a SecIdentity value at this key
    let identity = item[kSecImportItemIdentity as String] as! SecIdentity
    let chain = item[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
    return (identity, chain)
  }
}

// MARK: - ServerCertificatePinStore

/// Trust-on-first-use (TOFU) store for leaf public-key hashes of server
/// certificates that fail default validation (self-signed / private CA).
///
/// One `kSecClassGenericPassword` item per account holds a JSON dictionary of
/// `host -> SHA-256(SPKI)` hex. Keyed by host so accounts with alternative
/// server URLs (e.g. home + remote) pin each endpoint independently. Pins are
/// not secrets, but Keychain keeps them scoped per device and deletable
/// together with the rest of the account's trust material.
public final class ServerCertificatePinStore: @unchecked Sendable {
  static let service = "com.alzimerahmed.SonicWave.servercertpins"
  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "ServerCertificatePinStore"
  )
  private let keychain = KeychainHelper(service: ServerCertificatePinStore.service)
  private let lock = NSLock()

  public init() {}

  /// Read-modify-write helper — always call while `lock` is held.
  private func loadPins(accountIdent: String) -> [String: String] {
    guard case let .success(data) = keychain.read(account: accountIdent),
          let pins = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return pins
  }

  /// Returns false when the pins could not be persisted — the caller must
  /// fail closed (reject the connection) instead of silently degrading TOFU
  /// into trust-everything.
  @discardableResult
  private func savePins(_ pins: [String: String], accountIdent: String) -> Bool {
    guard let data = try? JSONEncoder().encode(pins) else { return false }
    let status = keychain.save(data: data, account: accountIdent)
    if status != errSecSuccess {
      os_log(
        "Could not persist server certificate pins for account %s (OSStatus %i)",
        log: log,
        type: .error,
        accountIdent,
        status
      )
    }
    return status == errSecSuccess
  }

  public func pinnedHash(accountIdent: String, host: String) -> String? {
    lock.withLock { loadPins(accountIdent: accountIdent)[host.lowercased()] }
  }

  /// Returns false when the pin could not be persisted durably.
  @discardableResult
  public func setPinnedHash(accountIdent: String, host: String, hash: String) -> Bool {
    lock.withLock {
      var pins = loadPins(accountIdent: accountIdent)
      pins[host.lowercased()] = hash
      return savePins(pins, accountIdent: accountIdent)
    }
  }

  /// Drops all pinned certificates of an account (e.g. server rotated its
  /// self-signed certificate, or the user wants to re-trust from scratch).
  /// Takes the same lock as `setPinnedHash` so a delete can never interleave
  /// with a concurrent read-modify-write.
  public func deleteAll(accountIdent: String) {
    lock.withLock {
      keychain.delete(account: accountIdent)
    }
  }
}

// MARK: - AccountSessionSecurity

/// Per-account TLS policy shared by every session that talks to the account's
/// server: the Alamofire sessions of the Ampache/Subsonic APIs, the artwork and
/// playable `DownloadManager` URLSessions and the reachability probes of
/// `BackendProxy`.
///
/// Responsibilities:
/// - **Server trust** — default (system) validation always wins. Only when it
///   fails AND the failure is purely an untrusted root
///   (`isOnlyAnchorTrustFailure` re-evaluates the chain with the leaf as its
///   own anchor — hostname mismatch, expiry, revocation or weak crypto still
///   reject outright) AND the account opted into
///   `allowUntrustedServerCertificates` AND the challenged host is one of the
///   account's configured server URLs does the trust-on-first-use path run:
///   the leaf public-key hash is compared to the pin recorded on first
///   contact; a mismatch rejects the connection (possible MITM or rotated
///   self-signed cert — user must reset trust in settings). Never a blanket
///   trust-all.
/// - **Client certificate (mTLS)** — answers
///   `NSURLAuthenticationMethodClientCertificate` with the identity stored in
///   the Keychain, but only for configured server hosts (never leaked to
///   redirected foreign hosts).
///
/// Read-only after `provideCredentials`; challenges are evaluated from whatever
/// queue URLSession calls in on, so all state access goes through `Atomic` or
/// the lock-guarded pin store.
///
/// Known limitation: `AudioStreaming`'s internal `NetworkingClient` creates its
/// own non-injectable `URLSession`, so live *audio streaming* does not honor
/// this policy — API calls, reachability probes, artwork and playable
/// downloads do. mTLS-locked servers should download/cached playback.
public final class AccountSessionSecurity: Sendable {
  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "SessionSecurity"
  )
  private let credentials = Atomic<LoginCredentials?>(wrappedValue: nil)
  private let clientCertificateStore: ClientCertificateStore
  private let certificatePinStore: ServerCertificatePinStore

  init(
    clientCertificateStore: ClientCertificateStore = ClientCertificateStore(),
    certificatePinStore: ServerCertificatePinStore = ServerCertificatePinStore()
  ) {
    self.clientCertificateStore = clientCertificateStore
    self.certificatePinStore = certificatePinStore
  }

  /// Latest credentials for the account — called by `BackendProxy` whenever
  /// the credentials change (login, header edits, URL failover) so challenges
  /// always see the current server URL set.
  func provideCredentials(_ newCredentials: LoginCredentials) {
    credentials.wrappedValue = newCredentials
  }

  /// Evaluates a URL authentication challenge for this account.
  /// Returns nil when the caller should fall back to the default
  /// URLSession/Alamofire behavior for this challenge.
  func evaluateChallenge(_ challenge: URLAuthenticationChallenge)
    -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      return evaluateServerTrust(protectionSpace: challenge.protectionSpace)
    case NSURLAuthenticationMethodClientCertificate:
      return evaluateClientCertificate(protectionSpace: challenge.protectionSpace)
    default:
      return nil
    }
  }

  /// True when `host` belongs to the account's known server URLs (primary +
  /// active + alternatives). Prevents sending client certs — or extending
  /// untrusted-cert trust — to foreign hosts reached via redirects.
  private func isConfiguredServerHost(_ host: String, credentials: LoginCredentials) -> Bool {
    var candidates = credentials.availableServerURLs
    if !credentials.activeBackendServerUrl.isEmpty {
      candidates.append(credentials.activeBackendServerUrl)
    }
    return candidates
      .compactMap { URLComponents(string: $0)?.host?.lowercased() }
      .contains(host.lowercased())
  }

  /// SHA-256 of the leaf certificate's public key (SPKI) — pinning the key
  /// instead of the whole certificate survives a re-issue with the same key
  /// and matches the common `PublicKeysTrustEvaluator` semantics.
  static func leafPublicKeyHash(trust: SecTrust) -> String? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let leaf = chain.first,
          let key = SecCertificateCopyKey(leaf)
    else { return nil }
    var error: Unmanaged<CFError>?
    guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data?
    else { return nil }
    return SHA256.hash(data: keyData)
      .map { String(format: "%02hhx", $0) }
      .joined()
  }

  /// Per-certificate `TrustResultDetails` flags (from `SecTrustCopyResult`)
  /// that make a failed trust evaluation ineligible for TOFU even when the
  /// leaf-anchor re-evaluation below would pass.
  private static let tofuBlockingTrustDetailKeys: Set<String> = [
    "Revoked",
    "RevokedNetworkRequired",
    "BlackListedKey",
    "BlackListedLeaf",
    "GrayListedLeaf",
  ]

  /// True when the ONLY reason `trust` failed system validation is that its
  /// chain anchors at an untrusted root (self-signed / private CA).
  ///
  /// How it is decided: the same chain is re-evaluated with the leaf
  /// certificate as its own trust anchor while the SSL hostname policy,
  /// BasicX509 (temporal validity, signature strength, ...) checks still
  /// apply. A chain that then validates failed before ONLY because no
  /// trusted anchor was found — the TOFU-eligible class. A hostname
  /// mismatch, expired or weak certificate still fails the re-evaluation;
  /// revocation/blocklist flags from the original evaluation's
  /// `TrustResultDetails` additionally disqualify the chain.
  static func isOnlyAnchorTrustFailure(trust: SecTrust, host: String) -> Bool {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let leaf = chain.first
    else { return false }
    let policies = [
      SecPolicyCreateSSL(true, host as CFString),
      SecPolicyCreateBasicX509(),
    ]
    var anchoredTrust: SecTrust?
    guard SecTrustCreateWithCertificates(
      chain as CFTypeRef,
      policies as CFTypeRef,
      &anchoredTrust
    ) == errSecSuccess,
      let anchoredTrust,
      SecTrustSetAnchorCertificates(anchoredTrust, [leaf] as CFArray) == errSecSuccess,
      SecTrustSetAnchorCertificatesOnly(anchoredTrust, true) == errSecSuccess
    else { return false }
    guard SecTrustEvaluateWithError(anchoredTrust, nil) else { return false }
    return !hasTofuBlockingTrustDetail(trust: trust)
  }

  /// Scans the original evaluation's per-certificate detail flags for
  /// revocation/blocklist failures — those must never reach the pin store.
  private static func hasTofuBlockingTrustDetail(trust: SecTrust) -> Bool {
    guard let result = SecTrustCopyResult(trust) as? [String: Any],
          let details = result["TrustResultDetails"] as? [[String: Any]]
    else { return false }
    return details.contains { certDetails in
      certDetails.keys.contains { tofuBlockingTrustDetailKeys.contains($0) }
    }
  }

  private func evaluateServerTrust(protectionSpace: URLProtectionSpace)
    -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
    guard let credentials = credentials.wrappedValue,
          credentials.allowUntrustedServerCertificates,
          isConfiguredServerHost(protectionSpace.host, credentials: credentials),
          let trust = protectionSpace.serverTrust
    else {
      // not our account's server or the user never opted in -> default handling
      // (system validation decides; self-signed certs are rejected as usual)
      return nil
    }

    // Default (system) validation first: a publicly valid certificate always
    // passes untouched and never interacts with the pin store.
    if SecTrustEvaluateWithError(trust, nil) {
      return (.useCredential, URLCredential(trust: trust))
    }

    // Only anchor-trust failures are TOFU-eligible: a self-signed or
    // private-CA / unknown-root chain passes re-evaluation when its leaf is
    // treated as the trust anchor, while hostname, temporal validity,
    // signature strength and revocation checks still apply. Anything else —
    // hostname mismatch, expired, revoked, weak crypto — is rejected
    // outright: an attacked or misconfigured certificate must never be
    // pinned.
    guard Self.isOnlyAnchorTrustFailure(trust: trust, host: protectionSpace.host) else {
      os_log(
        "Certificate for host %s failed validation beyond an untrusted root (hostname mismatch, expiry, revocation or weak crypto) -> rejecting",
        log: log,
        type: .error,
        protectionSpace.host
      )
      return (.rejectProtectionSpace, nil)
    }

    // The certificate failed system validation only because its root is
    // untrusted (self-signed / private CA) and the account opted into
    // untrusted certs -> TOFU policy:
    guard let leafHash = Self.leafPublicKeyHash(trust: trust) else {
      os_log(
        "Cannot read leaf public key of untrusted certificate for host %s -> rejecting",
        log: log,
        type: .error,
        protectionSpace.host
      )
      return (.rejectProtectionSpace, nil)
    }
    let accountIdent = credentials.accountIdent
    if let pinnedHash = certificatePinStore.pinnedHash(
      accountIdent: accountIdent,
      host: protectionSpace.host
    ) {
      if pinnedHash == leafHash {
        return (.useCredential, URLCredential(trust: trust))
      }
      os_log(
        "Pinned server certificate changed for host %s -> rejecting (possible MITM or rotated certificate; user must reset trusted certificates)",
        log: log,
        type: .error,
        protectionSpace.host
      )
      return (.rejectProtectionSpace, nil)
    }
    // first contact: pin the observed leaf key (trust-on-first-use); if the
    // pin cannot be persisted, fail closed — trusting without a durable pin
    // would silently degrade TOFU into trust-everything on each connection
    if certificatePinStore.setPinnedHash(
      accountIdent: accountIdent,
      host: protectionSpace.host,
      hash: leafHash
    ) {
      os_log(
        "TOFU: pinned public key of self-signed certificate for host %s",
        log: log,
        type: .info,
        protectionSpace.host
      )
      return (.useCredential, URLCredential(trust: trust))
    }
    os_log(
      "Could not persist the TOFU pin for host %s -> rejecting",
      log: log,
      type: .error,
      protectionSpace.host
    )
    return (.rejectProtectionSpace, nil)
  }

  private func evaluateClientCertificate(protectionSpace: URLProtectionSpace)
    -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
    guard let credentials = credentials.wrappedValue,
          isConfiguredServerHost(protectionSpace.host, credentials: credentials),
          let identity = clientCertificateStore.identity(accountIdent: credentials.accountIdent)
    else { return nil }
    os_log(
      "Providing client certificate (mTLS) for host %s",
      log: log,
      type: .info,
      protectionSpace.host
    )
    return (
      .useCredential,
      URLCredential(
        identity: identity.0,
        certificates: identity.1,
        persistence: .forSession
      )
    )
  }
}

// MARK: - AccountSessionDelegate

/// Alamofire session delegate that routes authentication challenges through
/// the account's `AccountSessionSecurity`. Anything the policy does not claim
/// falls back to Alamofire's default implementation (which performs the
/// standard system trust evaluation).
final class AccountSessionDelegate: SessionDelegate, @unchecked Sendable {
  private let security: AccountSessionSecurity

  init(security: AccountSessionSecurity) {
    self.security = security
    super.init()
  }

  nonisolated func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if let evaluation = security.evaluateChallenge(challenge) {
      completionHandler(evaluation.0, evaluation.1)
      return
    }
    completionHandler(.performDefaultHandling, nil)
  }

  override func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if let evaluation = security.evaluateChallenge(challenge) {
      completionHandler(evaluation.0, evaluation.1)
      return
    }
    super
      .urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
  }
}

// MARK: - AccountSessionChallengeHandler

/// `URLSessionDelegate` adapter for plain `URLSession`s (reachability probes in
/// `BackendProxy`, and reused by the `DownloadManager` session extension).
final class AccountSessionChallengeHandler: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
  @unchecked Sendable {
  private let security: AccountSessionSecurity

  init(security: AccountSessionSecurity) {
    self.security = security
    super.init()
  }

  private func evaluate(_ challenge: URLAuthenticationChallenge)
    -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    security.evaluateChallenge(challenge) ?? (.performDefaultHandling, nil)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let evaluation = evaluate(challenge)
    completionHandler(evaluation.0, evaluation.1)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let evaluation = evaluate(challenge)
    completionHandler(evaluation.0, evaluation.1)
  }
}
