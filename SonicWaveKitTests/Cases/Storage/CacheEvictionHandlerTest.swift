//
//  CacheEvictionHandlerTest.swift
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
import CoreData
import Foundation
import XCTest

@MainActor
class CacheEvictionHandlerTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var asyncStorage: AsyncCoreDataAccessWrapper!
  var requestManager: DownloadRequestManager!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    asyncStorage = AsyncCoreDataAccessWrapper(
      persistentContainer: cdHelper.persistentContainer
    )
    requestManager = DownloadRequestManager(
      accountObjectId: account.managedObject.objectID,
      accountInfo: account.info,
      storage: asyncStorage,
      getDownloadDelegateCB: { MOCK_DownloadManagerDelegate() }
    )
  }

  override func tearDown() {}

  private func song(id: String) -> Song? {
    library.getSong(for: account, id: id)
  }

  private func downloadTier(ofSongWith id: String) async throws -> PlayableDownloadTier? {
    try await asyncStorage.performAndGet { asyncCompanion in
      let asyncAccount = asyncCompanion.library.getAccount(info: TestAccountInfo.create1())
      return asyncCompanion.library.getSong(for: asyncAccount, id: id)?.downloadTier
    }
  }

  // MARK: lastUsedDate (LRU key)

  func testLastUsedDatePrefersLastTimePlayed() {
    let played = Date(timeIntervalSince1970: 1_700_000_000)
    let written = Date(timeIntervalSince1970: 1_600_000_000)
    XCTAssertEqual(
      CacheEvictionHandler.lastUsedDate(
        lastTimePlayed: played,
        fileModificationDate: written
      ),
      played
    )
  }

  func testLastUsedDateFallsBackToFileModificationDate() {
    // a never-played item counts its file write (= download) date so a
    // just-cached item is "recently used"
    let written = Date(timeIntervalSince1970: 1_600_000_000)
    XCTAssertEqual(
      CacheEvictionHandler.lastUsedDate(
        lastTimePlayed: nil,
        fileModificationDate: written
      ),
      written
    )
    XCTAssertEqual(
      CacheEvictionHandler.lastUsedDate(
        lastTimePlayed: nil,
        fileModificationDate: nil
      ),
      .distantPast
    )
  }

  // MARK: selectForEviction (pure LRU selection)

  func testSelectForEvictionIsEmptyWhenUnderLimit() throws {
    guard let songA = song(id: "36"), let songB = song(id: "38")
    else { XCTFail(); return }
    let candidates = [
      CacheEvictionCandidate(
        objectID: songA.objectID,
        lastUsedDate: .distantPast,
        fileSize: 50
      ),
      CacheEvictionCandidate(
        objectID: songB.objectID,
        lastUsedDate: Date(),
        fileSize: 50
      ),
    ]
    XCTAssertTrue(CacheEvictionHandler
      .selectForEviction(candidates: candidates, limitBytes: 100).isEmpty)
    XCTAssertTrue(CacheEvictionHandler
      .selectForEviction(candidates: candidates, limitBytes: 101).isEmpty)
  }

  func testSelectForEvictionPicksLeastRecentlyUsedFirst() throws {
    guard let songOld = song(id: "36"),
          let songMid = song(id: "38"),
          let songNew = song(id: "41")
    else { XCTFail(); return }
    let old = CacheEvictionCandidate(
      objectID: songOld.objectID,
      lastUsedDate: Date(timeIntervalSince1970: 1_000_000_000),
      fileSize: 30
    )
    let mid = CacheEvictionCandidate(
      objectID: songMid.objectID,
      lastUsedDate: Date(timeIntervalSince1970: 1_500_000_000),
      fileSize: 40
    )
    let new = CacheEvictionCandidate(
      objectID: songNew.objectID,
      lastUsedDate: Date(timeIntervalSince1970: 2_000_000_000),
      fileSize: 50
    )
    // total 120, limit 70 -> evict old (30) -> 90 still over -> evict mid
    // (40) -> 50 fits; the newest item always survives
    let evicted = CacheEvictionHandler.selectForEviction(
      candidates: [new, mid, old],
      limitBytes: 70
    )
    XCTAssertEqual(evicted.map(\.objectID), [old.objectID, mid.objectID])
  }

  func testSelectForEvictionEvictsEverythingOnlyWhenRequired() throws {
    guard let songA = song(id: "36"), let songB = song(id: "38")
    else { XCTFail(); return }
    let candidates = [
      CacheEvictionCandidate(
        objectID: songA.objectID,
        lastUsedDate: .distantPast,
        fileSize: 50
      ),
      CacheEvictionCandidate(
        objectID: songB.objectID,
        lastUsedDate: Date(),
        fileSize: 50
      ),
    ]
    // limit 0 -> every candidate must go (the handler itself guards
    // "0 = unlimited" before reaching the selection)
    let evicted = CacheEvictionHandler.selectForEviction(
      candidates: candidates,
      limitBytes: 0
    )
    XCTAssertEqual(evicted.count, 2)
  }

  func testSelectForEvictionIsDeterministicForEqualDates() throws {
    guard let songA = song(id: "36"), let songB = song(id: "38"),
          let songC = song(id: "41")
    else { XCTFail(); return }
    func makeCandidates() -> [CacheEvictionCandidate] {
      [songA, songB, songC].map {
        CacheEvictionCandidate(
          objectID: $0.objectID,
          lastUsedDate: .distantPast,
          fileSize: 10
        )
      }
    }

    let first = CacheEvictionHandler.selectForEviction(
      candidates: makeCandidates(),
      limitBytes: 10
    )
    let second = CacheEvictionHandler.selectForEviction(
      candidates: makeCandidates().reversed(),
      limitBytes: 10
    )
    // same lastUsedDate -> objectID URI is the stable tie-breaker; two of
    // the three 10-byte items must go to fit the 10-byte limit
    XCTAssertEqual(first.map(\.objectID), second.map(\.objectID))
    XCTAssertEqual(first.count, 2)
  }

  // MARK: tier marking via DownloadRequestManager

  func testRequestedTierIsPersistedOnDownloadable() async throws {
    // a .cache request keeps the default tier
    guard let song = song(id: "3"), let info = song.threadSafeInfo
    else { XCTFail(); return }
    let request = await requestManager.add(downloadInfo: info, tier: .cache)
    XCTAssertNotNil(request)
    var tier = try await downloadTier(ofSongWith: "3")
    XCTAssertEqual(tier, .cache)

    // an explicit user download promotes the item to .pinned
    let pinnedRequest = await requestManager.add(downloadInfo: info, tier: .pinned)
    XCTAssertNotNil(pinnedRequest)
    tier = try await downloadTier(ofSongWith: "3")
    XCTAssertEqual(tier, .pinned)
  }

  func testCacheRequestNeverDemotesPinnedItem() async throws {
    guard let song = song(id: "5"), let info = song.threadSafeInfo
    else { XCTFail(); return }
    await requestManager.markTier(downloadInfo: info, tier: .pinned)
    var tier = try await downloadTier(ofSongWith: "5")
    XCTAssertEqual(tier, .pinned)

    // a later auto-cache request must not strip the pin
    _ = await requestManager.add(downloadInfo: info, tier: .cache)
    tier = try await downloadTier(ofSongWith: "5")
    XCTAssertEqual(tier, .pinned)
    await requestManager.markTier(downloadInfo: info, tier: .cache)
    tier = try await downloadTier(ofSongWith: "5")
    XCTAssertEqual(tier, .pinned)
  }

  func testMarkTierPromotesCachedItemWithoutRequest() async throws {
    // seeded cached song (id "36") starts on the default .cache tier;
    // an explicit re-download of a cached item creates no download
    // request but must still pin it
    guard let song = song(id: "36"), let info = song.threadSafeInfo
    else { XCTFail(); return }
    await requestManager.markTier(downloadInfo: info, tier: .pinned)
    let tier = try await downloadTier(ofSongWith: "36")
    XCTAssertEqual(tier, .pinned)
  }

  // MARK: storage accounting (P6-D API surface)

  func testPlayableStorageUsageSplitsByTier() throws {
    let usageBefore = library.getPlayableStorageUsage(for: account)
    XCTAssertGreaterThan(usageBefore.cacheTierItemCount, 0)
    XCTAssertEqual(usageBefore.pinnedTierItemCount, 0)
    XCTAssertGreaterThan(usageBefore.cacheTierByteCount, 0)
    XCTAssertEqual(usageBefore.evictionEligibleByteCount, usageBefore.cacheTierByteCount)
    XCTAssertEqual(
      usageBefore.totalByteCount,
      usageBefore.cacheTierByteCount + usageBefore.pinnedTierByteCount
    )

    guard let song = song(id: "36") else { XCTFail(); return }
    song.downloadTier = .pinned
    library.saveContext()

    let usageAfter = library.getPlayableStorageUsage(for: account)
    XCTAssertEqual(usageAfter.pinnedTierItemCount, 1)
    XCTAssertEqual(
      usageAfter.cacheTierItemCount,
      usageBefore.cacheTierItemCount - 1
    )
    XCTAssertLessThan(
      usageAfter.evictionEligibleByteCount,
      usageBefore.evictionEligibleByteCount
    )
  }
}
