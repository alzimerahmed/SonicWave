//
//  CredentialsKeychainMigration.swift
//  SonicWaveKit
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

import Foundation
import os.log

// MARK: - PersistentStorage + CredentialsKeychainMigration

extension PersistentStorage {
  /// One-time migration: moves plaintext credential secrets (`password` +
  /// `httpHeaders`) out of the UserDefaults-backed account settings JSON into
  /// the Keychain.
  ///
  /// Works together with `LoginCredentials`' Codable implementation:
  /// - decoding re-homes legacy inline secrets into the Keychain (best-effort)
  /// - re-encoding writes the scrubbed payload back to UserDefaults; if the
  ///   Keychain write failed, the encode falls back to plaintext so the
  ///   credentials stay readable and the next launch retries — the user is
  ///   never stranded logged-out by a failed migration.
  ///
  /// Accounts whose secrets store could not be READ during decode (Keychain
  /// locked before first unlock — `secretsReadFailed`) are effectively
  /// skipped: their encode writes neither a Keychain overwrite nor plaintext
  /// keys, so their existing Keychain blob survives untouched and a later
  /// healthy launch resolves them normally.
  ///
  /// Idempotent: runs only while the stored JSON still contains secret keys.
  /// Called once at launch (AppDelegate) next to
  /// `applyMultiAccountSettingsUpdateIfNeeded`.
  @MainActor
  public func applyCredentialsKeychainMigrationIfNeeded() {
    let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "CredentialsMigration")
    guard let storedData = UserDefaults.standard
      .data(forKey: UserDefaultsKey.SettingsAccount.rawValue)
    else { return }
    guard Self.storedAccountSettingsContainPlaintextSecrets(storedData) else { return }

    os_log("Migrating plaintext credential secrets to the Keychain", log: log, type: .info)
    let migratedAccounts = settings.accounts
    settings.accounts = migratedAccounts

    if let storedDataAfter = UserDefaults.standard
      .data(forKey: UserDefaultsKey.SettingsAccount.rawValue),
      Self.storedAccountSettingsContainPlaintextSecrets(storedDataAfter) {
      os_log(
        "Credential secrets could not be fully migrated to the Keychain — will retry at next launch",
        log: log,
        type: .error
      )
    } else {
      os_log("Credential secrets migrated to the Keychain", log: log, type: .info)
    }
  }

  /// True when the raw `settings.account` JSON still contains an inline
  /// `password` or `httpHeaders` key — i.e. a pre-Keychain payload.
  static func storedAccountSettingsContainPlaintextSecrets(_ data: Data) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return false }
    return containsPlaintextSecretKey(root)
  }

  private static func containsPlaintextSecretKey(_ value: Any) -> Bool {
    if let dict = value as? [String: Any] {
      if dict.keys.contains("password") || dict.keys.contains("httpHeaders") {
        return true
      }
      return dict.values.contains(where: { containsPlaintextSecretKey($0) })
    }
    if let array = value as? [Any] {
      return array.contains(where: { containsPlaintextSecretKey($0) })
    }
    return false
  }
}
