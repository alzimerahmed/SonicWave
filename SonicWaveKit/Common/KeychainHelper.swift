//
//  KeychainHelper.swift
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
import Security

// MARK: - KeychainHelper

/// Minimal SecItem wrapper for `kSecClassGenericPassword` items.
///
/// Items are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// readable by background fetch / CarPlay after the first device unlock, never
/// migrated to other devices via backup or keychain sync.
///
/// All functions return `OSStatus` where useful so callers can log failures —
/// nothing here traps, so a broken Keychain must degrade gracefully.
public struct KeychainHelper: Sendable {
  public let service: String

  public init(service: String) {
    self.service = service
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  /// Insert-or-update the item's data. Returns the SecItem status of the write
  /// (`errSecSuccess` on success).
  @discardableResult
  public func save(data: Data, account: String) -> OSStatus {
    let query = baseQuery(account: account)
    let lookupStatus = SecItemCopyMatching(query as CFDictionary, nil)
    switch lookupStatus {
    case errSecSuccess:
      let attributes: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    case errSecItemNotFound:
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      return SecItemAdd(item as CFDictionary, nil)
    default:
      return lookupStatus
    }
  }

  /// Returns the stored data or nil on any failure (`errSecItemNotFound`
  /// included — an absent item is not an error to the caller).
  public func read(account: String) -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  /// Deletes the item. Returns the SecItem status; `errSecItemNotFound` is a
  /// successful outcome for idempotent deletes.
  @discardableResult
  public func delete(account: String) -> OSStatus {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    return status == errSecItemNotFound ? errSecSuccess : status
  }
}
