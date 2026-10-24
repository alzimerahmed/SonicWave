//
//  CacheEvictionHandler.swift
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

import CoreData
import Foundation
import os.log

// MARK: - CacheEvictionCandidate

/// One eviction-eligible `.cache`-tier playable with its resolved LRU key
/// and on-disk file size. `lastUsedDate` is produced by
/// `CacheEvictionHandler.lastUsedDate(lastTimePlayed:fileModificationDate:)`.
public struct CacheEvictionCandidate: Hashable, Sendable {
  public let objectID: NSManagedObjectID
  public let lastUsedDate: Date
  public let fileSize: Int64

  public init(objectID: NSManagedObjectID, lastUsedDate: Date, fileSize: Int64) {
    self.objectID = objectID
    self.lastUsedDate = lastUsedDate
    self.fileSize = fileSize
  }
}

// MARK: - CacheEvictionHandler

/// Two-tier storage (G6): trims the evictable `.cache` download tier of one
/// account to a configurable size cap using LRU eviction.
///
/// - Only `PlayableDownloadTier.cache` items are ever touched — `.pinned`
///   (explicit user downloads) are permanently excluded from eviction.
/// - The LRU key is `max(lastTimePlayed, file modification date)`. The file
///   modification date doubles as the download date, so a just-cached item
///   is "recently used" even before its first play.
/// - Eviction reuses `LibraryStorage.deleteCache(ofPlayable:)` — the file is
///   removed via `CacheFileManager` (size accounting stays correct) and all
///   cache bookkeeping (`relFilePath`, container `isCached` flags, download
///   tier reset) runs through the existing delete path.
/// - The `.cache`-only cap (`AccountSetting.cacheSizeLimitBytes`) is
///   independent from the legacy global `UserSettings.cacheLimit`, which
///   still acts as a hard stop for *new* downloads of any tier.
final class CacheEvictionHandler: Sendable {
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "CacheEvictionHandler")
  private let storage: AsyncCoreDataAccessWrapper
  private let fileManager: CacheFileManager
  private let accountObjectId: NSManagedObjectID
  private let accountInfo: AccountInfo
  /// resolves the account's current `.cache` tier cap in bytes (0 = unlimited)
  private let cacheSizeLimitBytesProvider: @Sendable (AccountInfo) -> Int64

  init(
    storage: AsyncCoreDataAccessWrapper,
    accountObjectId: NSManagedObjectID,
    accountInfo: AccountInfo,
    cacheSizeLimitBytesProvider: @escaping @Sendable (AccountInfo) -> Int64,
    fileManager: CacheFileManager = .shared
  ) {
    self.storage = storage
    self.accountObjectId = accountObjectId
    self.accountInfo = accountInfo
    self.cacheSizeLimitBytesProvider = cacheSizeLimitBytesProvider
    self.fileManager = fileManager
  }

  /// LRU key: last play wins, file modification date (= download date) as
  /// floor. A never-played item cached seconds ago counts as recently used.
  static func lastUsedDate(lastTimePlayed: Date?, fileModificationDate: Date?) -> Date {
    max(lastTimePlayed ?? .distantPast, fileModificationDate ?? .distantPast)
  }

  /// Pure LRU selection — picks the least-recently-used candidates until
  /// `total fileSize - evicted fileSize <= limitBytes`. Deterministic:
  /// `objectID` URI is the tie-breaker for equal `lastUsedDate`s.
  static func selectForEviction(
    candidates: [CacheEvictionCandidate],
    limitBytes: Int64
  ) -> [CacheEvictionCandidate] {
    let sorted = candidates.sorted {
      if $0.lastUsedDate != $1.lastUsedDate {
        return $0.lastUsedDate < $1.lastUsedDate
      }
      return $0.objectID.uriRepresentation().absoluteString < $1.objectID
        .uriRepresentation().absoluteString
    }
    var totalFileSize = sorted.reduce(Int64(0)) { $0 + $1.fileSize }
    var evicted = [CacheEvictionCandidate]()
    for candidate in sorted {
      guard totalFileSize > limitBytes else { break }
      evicted.append(candidate)
      totalFileSize -= candidate.fileSize
    }
    return evicted
  }

  /// LRU-evicts `.cache`-tier files until the tier fits the configured cap.
  /// Fast path: when the whole playable directory (both tiers) already fits,
  /// no fetch/stat work happens at all — keeps the per-download trigger cheap.
  /// Returns the number of evicted items.
  @discardableResult
  func trimToLimit() async -> Int {
    let limitBytes = cacheSizeLimitBytesProvider(accountInfo)
    guard limitBytes > 0 else { return 0 }
    // fast path: cache+pinned together fit the cap -> .cache cannot exceed it
    guard fileManager.getPlayableCacheSize(for: accountInfo) > limitBytes else { return 0 }

    let evictedCount = try? await storage.performAndGet { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let cached = asyncCompanion.library.getCachedPlayables(
        for: account,
        downloadTier: .cache
      )
      var playablesByObjectID = [NSManagedObjectID: AbstractPlayable]()
      var candidates = [CacheEvictionCandidate]()
      candidates.reserveCapacity(cached.count)
      for playable in cached {
        guard let relFilePath = playable.relFilePath else { continue }
        playablesByObjectID[playable.objectID] = playable
        candidates.append(CacheEvictionCandidate(
          objectID: playable.objectID,
          lastUsedDate: Self.lastUsedDate(
            lastTimePlayed: playable.lastTimePlayed,
            fileModificationDate: self.fileManager
              .getFileModificationDate(relFilePath: relFilePath)
          ),
          fileSize: self.fileManager.getFileSize(relFilePath: relFilePath) ?? 0
        ))
      }
      let evicted = Self.selectForEviction(candidates: candidates, limitBytes: limitBytes)
      guard !evicted.isEmpty else { return 0 }
      for candidate in evicted {
        guard let playable = playablesByObjectID[candidate.objectID] else { continue }
        asyncCompanion.library.deleteCache(ofPlayable: playable)
      }
      asyncCompanion.saveContext()
      return evicted.count
    }

    if let evictedCount, evictedCount > 0 {
      os_log(
        "Cache trim: evicted %i LRU .cache item(s) to fit %{iec-bytes}lld cap",
        log: log,
        type: .info,
        evictedCount,
        limitBytes
      )
    }
    return evictedCount ?? 0
  }
}
