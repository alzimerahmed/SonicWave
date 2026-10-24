//
//  AlbumDeduplicationTest.swift
//  SonicWaveKitTests
//
//  Created by Alzimer Ahmed on 15.02.26.
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
import XCTest

/// Regression for "duplicate albums after resync": duplicate resolution
/// must key on the server id (`AlbumMO.id`) and must reparent songs to
/// the surviving album — the old inline dedupe deleted copies without
/// `passOwnership`, orphaning songs that later spawned stub albums.
@MainActor
class AlbumDeduplicationTest: XCTestCase {
  var context: NSManagedObjectContext!
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    context = cdHelper.createInMemoryManagedObjectContext()
    cdHelper.clearContext(context: context)
    library = LibraryStorage(context: context)
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  private func createAlbum(id: String, name: String) -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    album.name = name
    return album
  }

  func testDuplicateAlbumsAreDetectedByServerId() {
    _ = createAlbum(id: "album-1", name: "Same")
    _ = createAlbum(id: "album-1", name: "Same")
    _ = createAlbum(id: "album-2", name: "Other")
    library.saveContext()

    let duplicates = library.findDuplicates(
      for: Album.typeName,
      keyPathString: #keyPath(AlbumMO.id),
      account: account
    )
    XCTAssertEqual(duplicates.count, 1)
    XCTAssertEqual(duplicates.first?.id, "album-1")
    XCTAssertEqual(duplicates.first?.count, 2)
  }

  func testResolveMergesDuplicatesAndReparentsSongs() {
    let first = createAlbum(id: "album-1", name: "Same")
    let second = createAlbum(id: "album-1", name: "Same")
    let song = library.createSong(account: account)
    song.id = "song-1"
    song.title = "Attached"
    song.album = second
    library.saveContext()

    let duplicates = library.findDuplicates(
      for: Album.typeName,
      keyPathString: #keyPath(AlbumMO.id),
      account: account
    )
    library.resolveAlbumsDuplicates(account: account, duplicates: duplicates)
    library.saveContext()

    let survivors = library.getAlbums(for: account).filter { $0.id == "album-1" }
    XCTAssertEqual(survivors.count, 1)
    // whichever copy survived must now own the song (no orphans)
    XCTAssertEqual(survivors.first?.songs.map { $0.id }, ["song-1"])
    XCTAssertEqual(song.album?.managedObject, survivors.first?.managedObject)
    XCTAssertTrue(first.managedObject.isDeleted || second.managedObject.isDeleted)
  }

  func testNoDuplicatesForDistinctIds() {
    _ = createAlbum(id: "a", name: "Same Name")
    _ = createAlbum(id: "b", name: "Same Name")
    library.saveContext()

    // identical names must NOT collapse — dedupe is by server id only
    let duplicates = library.findDuplicates(
      for: Album.typeName,
      keyPathString: #keyPath(AlbumMO.id),
      account: account
    )
    XCTAssertTrue(duplicates.isEmpty)
    XCTAssertEqual(library.getAlbums(for: account).count, 2)
  }
}
