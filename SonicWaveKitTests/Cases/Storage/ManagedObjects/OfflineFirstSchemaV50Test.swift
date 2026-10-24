//
//  OfflineFirstSchemaV50Test.swift
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

@MainActor
class OfflineFirstSchemaV50Test: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  // MARK: Migration chain

  func testMigrationVersionChainReachesV50() {
    XCTAssertEqual(CoreDataMigrationVersion.current, .v50)
    XCTAssertEqual(CoreDataMigrationVersion.v49.nextVersion(), .v50)
    XCTAssertNil(CoreDataMigrationVersion.v50.nextVersion())
  }

  func testLibrarySyncVersionIsV22() {
    XCTAssertEqual(LibrarySyncVersion.newestVersion, .v22)
    XCTAssertEqual(LibrarySyncVersion.v22.rawValue, 16)
    XCTAssertTrue(LibrarySyncVersion.v21 < LibrarySyncVersion.v22)
  }

  // MARK: AbstractPlayable.downloadTier (G6)

  func testDownloadTierDefaultsToCache() {
    guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    XCTAssertEqual(song.downloadTier, .cache)
    XCTAssertFalse(song.isDownloadPinned)
  }

  func testDownloadTierPersists() {
    guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    song.downloadTier = .pinned
    library.saveContext()

    guard let refetched = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    XCTAssertEqual(refetched.downloadTier, .pinned)
    XCTAssertTrue(refetched.isDownloadPinned)
  }

  func testGetCachedPlayablesByTier() {
    // the seeder caches several songs for the test account; all default to .cache
    let cachedBefore = library.getCachedPlayables(for: account, downloadTier: .cache)
    XCTAssertGreaterThan(cachedBefore.count, 0)
    XCTAssertEqual(library.getCachedPlayables(for: account, downloadTier: .pinned).count, 0)

    guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    song.relFilePath = URL(string: "testSongTier")
    song.downloadTier = .pinned
    library.saveContext()

    let pinned = library.getCachedPlayables(for: account, downloadTier: .pinned)
    XCTAssertEqual(pinned.count, 1)
    XCTAssertEqual(pinned.first?.id, cdHelper.seeder.songs[0].id)
    XCTAssertEqual(
      library.getCachedPlayables(for: account, downloadTier: .cache).count,
      cachedBefore.count
    )
  }

  // MARK: Playlist.isWatchedForAutoDownload (G5)

  func testWatchedPlaylists() {
    XCTAssertEqual(library.getWatchedPlaylists(for: account).count, 0)

    let playlist = library.createPlaylist(account: account)
    playlist.id = "watched-playlist"
    playlist.isWatchedForAutoDownload = true
    library.saveContext()

    let watched = library.getWatchedPlaylists(for: account)
    XCTAssertEqual(watched.count, 1)
    XCTAssertEqual(watched.first?.id, "watched-playlist")
  }

  // MARK: Account.lastLibrarySyncDate (delta sync marker)

  func testAccountLastLibrarySyncDate() {
    XCTAssertNil(account.lastLibrarySyncDate)
    let syncDate = Date(timeIntervalSince1970: 1_700_000_000)
    account.lastLibrarySyncDate = syncDate
    library.saveContext()

    let refetched = library.getAccount(info: TestAccountInfo.create1())
    XCTAssertEqual(refetched.lastLibrarySyncDate, syncDate)
  }

  // MARK: Player play-queue sync markers (G9)

  func testPlayerPlayQueueSyncState() {
    let player = library.getPlayerData()
    XCTAssertFalse(player.isPlayQueueDirty)
    XCTAssertNil(player.playQueueLastSyncDate)
    XCTAssertNil(player.playQueueRemoteChangeDate)

    player.setPlayQueueDirty(true)
    let syncDate = Date(timeIntervalSince1970: 1_700_000_000)
    player.setPlayQueueLastSyncDate(syncDate)
    let remoteDate = Date(timeIntervalSince1970: 1_700_000_100)
    player.setPlayQueueRemoteChangeDate(remoteDate)

    let refetched = library.getPlayerData()
    XCTAssertTrue(refetched.isPlayQueueDirty)
    XCTAssertEqual(refetched.playQueueLastSyncDate, syncDate)
    XCTAssertEqual(refetched.playQueueRemoteChangeDate, remoteDate)
  }

  // MARK: Settings watch toggle (G5)

  func testAutoDownloadFavoritesSetting() throws {
    var setting = AccountSetting()
    XCTAssertFalse(setting.isAutoDownloadFavoritesActive)
    setting.isAutoDownloadFavoritesActive = true
    XCTAssertTrue(setting.isAutoDownloadFavoritesActive)

    // older persisted settings lack the key (nil optionals are omitted by
    // JSONEncoder) -> decoding must still succeed and default to false
    var legacy = AccountSetting()
    legacy.isAutoDownloadLatestSongsActive = true
    let legacyData = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(AccountSetting.self, from: legacyData)
    XCTAssertFalse(decoded.isAutoDownloadFavoritesActive)
    XCTAssertTrue(decoded.isAutoDownloadLatestSongsActive)
  }
}
