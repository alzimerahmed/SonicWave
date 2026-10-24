//
//  SmartPlaylistSchemaV51Test.swift
//  SonicWaveKitTests
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

@testable import SonicWaveKit
import Foundation
import XCTest

@MainActor
class SmartPlaylistSchemaV51Test: XCTestCase {
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

  func testMigrationVersionChainReachesV51() {
    XCTAssertEqual(CoreDataMigrationVersion.current, .v51)
    XCTAssertEqual(CoreDataMigrationVersion.v50.nextVersion(), .v51)
    XCTAssertNil(CoreDataMigrationVersion.v51.nextVersion())
  }

  func testLibrarySyncVersionIsV23() {
    XCTAssertEqual(LibrarySyncVersion.newestVersion, .v23)
    XCTAssertEqual(LibrarySyncVersion.v23.rawValue, 17)
    XCTAssertTrue(LibrarySyncVersion.v22 < LibrarySyncVersion.v23)
  }

  // MARK: AbstractPlayable.isDisliked (#587)

  func testIsDislikedDefaultsToFalse() {
    guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    XCTAssertFalse(song.isDisliked)
  }

  func testIsDislikedPersists() {
    guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    song.isDisliked = true
    library.saveContext()

    guard let refetched = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    XCTAssertTrue(refetched.isDisliked)
  }

  func testGetDislikedSongsAndSetDisliked() {
    XCTAssertEqual(library.getDislikedSongs(for: account).count, 0)

    guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    library.setDisliked(true, for: song)

    let disliked = library.getDislikedSongs(for: account)
    XCTAssertEqual(disliked.count, 1)
    XCTAssertEqual(disliked.first?.id, cdHelper.seeder.songs[0].id)

    library.setDisliked(false, for: song)
    XCTAssertEqual(library.getDislikedSongs(for: account).count, 0)
  }

  // MARK: Playlist.isSmartPlaylist / isServerReadOnly (G8)

  func testPlaylistFlagsDefaultToFalse() {
    let playlist = library.createPlaylist(account: account)
    playlist.id = "regular-playlist"
    library.saveContext()

    XCTAssertFalse(playlist.isSmartPlaylist)
    XCTAssertFalse(playlist.isServerReadOnly)
    XCTAssertNil(playlist.smartCriteria)
    XCTAssertNil(playlist.managedObject.smartCriteriaJson)
  }

  func testServerReadOnlyPersists() {
    let playlist = library.createPlaylist(account: account)
    playlist.id = "readonly-playlist"
    playlist.isServerReadOnly = true
    playlist.isSmartPlaylist = true
    library.saveContext()

    guard let refetched = library.getPlaylist(for: account, id: "readonly-playlist")
    else { XCTFail(); return }
    XCTAssertTrue(refetched.isServerReadOnly)
    XCTAssertTrue(refetched.isSmartPlaylist)
  }

  /// locally-authored smart playlists keep reporting smart via the `smart_`
  /// id prefix even when the persisted flag was never set
  func testSmartPlaylistIdPrefixStillReportsSmart() {
    let playlist = library.createPlaylist(account: account)
    playlist.id = Playlist.smartPlaylistIdPrefix + "local-mix"
    library.saveContext()

    XCTAssertFalse(playlist.managedObject.isSmartPlaylist)
    XCTAssertTrue(playlist.isSmartPlaylist)
  }

  func testGetSmartPlaylists() {
    XCTAssertEqual(library.getSmartPlaylists(for: account).count, 0)

    let serverSmart = library.createPlaylist(account: account)
    serverSmart.id = "server-smart"
    serverSmart.isSmartPlaylist = true
    let localSmart = library.createPlaylist(account: account)
    localSmart.id = Playlist.smartPlaylistIdPrefix + "authored"
    let regular = library.createPlaylist(account: account)
    regular.id = "regular"
    library.saveContext()

    let smartIds = Set(library.getSmartPlaylists(for: account).map { $0.id })
    XCTAssertEqual(smartIds, ["server-smart", Playlist.smartPlaylistIdPrefix + "authored"])
  }

  // MARK: Playlist.smartCriteria Codable round-trip (G8)

  func testSmartCriteriaCodableRoundTrip() throws {
    let criteria = SmartPlaylistCriteria(
      combination: .matchAll,
      rules: [
        SmartPlaylistRule(field: .genre, operator: .equal, value: .text("Rock")),
        SmartPlaylistRule(field: .disliked, operator: .notEqual, value: .bool(true)),
        SmartPlaylistRule(
          field: .year,
          operator: .inRange,
          value: .intRange(lower: 1990, upper: 1999)
        ),
      ],
      sort: SmartPlaylistSort(field: .title, ascending: true),
      limit: 25,
      unsupportedNotes: ["bpm: not locally evaluable"],
      isImportedFromServer: true
    )

    let playlist = library.createPlaylist(account: account)
    playlist.id = "criteria-playlist"
    playlist.smartCriteria = criteria
    library.saveContext()

    guard let refetched = library.getPlaylist(for: account, id: "criteria-playlist")
    else { XCTFail(); return }
    XCTAssertTrue(refetched.isSmartPlaylist)
    XCTAssertNotNil(refetched.managedObject.smartCriteriaJson)
    XCTAssertEqual(refetched.smartCriteria, criteria)
  }

  func testSmartCriteriaClearing() {
    let playlist = library.createPlaylist(account: account)
    playlist.id = "clearing-playlist"
    playlist.smartCriteria = SmartPlaylistCriteria(
      rules: [SmartPlaylistRule(field: .rating, operator: .greaterThan, value: .int(3))]
    )
    library.saveContext()
    XCTAssertNotNil(playlist.managedObject.smartCriteriaJson)

    playlist.smartCriteria = nil
    library.saveContext()

    guard let refetched = library.getPlaylist(for: account, id: "clearing-playlist")
    else { XCTFail(); return }
    XCTAssertNil(refetched.smartCriteria)
    XCTAssertNil(refetched.managedObject.smartCriteriaJson)
  }

  /// `SmartPlaylistField.disliked` must resolve to the `isDisliked` keyPath
  /// that schema v51 adds on `AbstractPlayable` (inherited by `SongMO`) —
  /// this is the compile-time + runtime contract `songFetchRequest()` relies on
  func testDislikedCriteriaFetchRequestResolves() {
    let criteria = SmartPlaylistCriteria(
      rules: [SmartPlaylistRule(field: .disliked, operator: .equal, value: .bool(true))]
    )
    let fetchRequest = criteria.songFetchRequest()
    XCTAssertEqual(fetchRequest.entityName, "Song")

    guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    else { XCTFail(); return }
    library.setDisliked(true, for: song)

    let matches = (try? cdHelper.persistentContainer.viewContext.fetch(fetchRequest)) ?? []
    XCTAssertTrue(matches.contains { $0.id == cdHelper.seeder.songs[0].id })
  }
}
