//
//  SpotlightIndexingTest.swift
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
import CoreData
import CoreSpotlight
import XCTest

// MARK: - MOCK_SearchableIndex

final class MOCK_SearchableIndex: SearchableIndexing, @unchecked Sendable {
  private(set) var indexedItems = [CSSearchableItem]()
  private(set) var deletedIdentifiers = [String]()
  private(set) var deletedDomains = [String]()
  private(set) var deleteAllCallCount = 0

  func indexItems(_ items: [CSSearchableItem]) async throws {
    indexedItems.append(contentsOf: items)
  }

  func deleteItems(identifiers: [String]) async throws {
    deletedIdentifiers.append(contentsOf: identifiers)
  }

  func deleteItems(domainIdentifiers: [String]) async throws {
    deletedDomains.append(contentsOf: domainIdentifiers)
  }

  func deleteAllItems() async throws {
    deleteAllCallCount += 1
  }
}

// MARK: - SpotlightIndexingTest

@MainActor
class SpotlightIndexingTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var mockIndex: MOCK_SearchableIndex!
  var settings: AmperfySettings!

  override func setUp() async throws {
    try await super.setUp()
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    mockIndex = MOCK_SearchableIndex()
    settings = AmperfySettings()
    settings.user.isSpotlightIndexingEnabled = true
    settings.app.isLibrarySynced = true
    settings.accounts.switchActiveAccount(TestAccountInfo.create1())
  }

  private func makeIndexer() -> SpotlightIndexer {
    SpotlightIndexer(
      asyncStorage: AsyncCoreDataAccessWrapper(
        persistentContainer: cdHelper.persistentContainer
      ),
      settings: settings,
      searchableIndex: mockIndex,
      performanceMonitor: MOCK_PerformanceMonitor(),
      drainDebounceNanoseconds: 0
    )
  }

  // MARK: identifier codec

  func testIdentifierRoundTrip() {
    for type in SpotlightItemType.allCases {
      let identifier = SpotlightItemIdentifier(type: type, accountIdent: "a1b2-c3d4", id: "42")
      XCTAssertEqual(
        SpotlightItemIdentifier(encoded: identifier.encoded),
        identifier
      )
    }
  }

  /// server ids are opaque — `:`/`-` inside them must survive because only
  /// the first two separators split type and accountIdent
  func testIdentifierDecodesIdContainingSeparators() {
    let identifier = SpotlightItemIdentifier(
      type: .song,
      accountIdent: "a1b2-c3d4",
      id: "x:y-z:w"
    )
    let decoded = SpotlightItemIdentifier(encoded: identifier.encoded)
    XCTAssertEqual(decoded, identifier)
  }

  func testIdentifierDecodeRejectsMalformed() {
    XCTAssertNil(SpotlightItemIdentifier(encoded: ""))
    XCTAssertNil(SpotlightItemIdentifier(encoded: "song"))
    XCTAssertNil(SpotlightItemIdentifier(encoded: "song:acc"))
    XCTAssertNil(SpotlightItemIdentifier(encoded: "bogus:acc:id"))
    XCTAssertNil(SpotlightItemIdentifier(encoded: "song::id"))
    XCTAssertNil(SpotlightItemIdentifier(encoded: "song:acc:"))
  }

  func testDomainIdentifierIsAccount() {
    let identifier = SpotlightItemIdentifier(type: .album, accountIdent: "srv-usr", id: "9")
    XCTAssertEqual(identifier.domainIdentifier, "srv-usr")
    XCTAssertEqual(identifier.encoded, "album:srv-usr:9")
  }

  // MARK: attributeSet construction

  func testDescriptorProducesExpectedItem() {
    let identifier = SpotlightItemIdentifier(type: .song, accountIdent: "a-b", id: "7")
    let lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)
    let descriptor = SpotlightEntityDescriptor(
      identifier: identifier,
      title: "Song Title",
      contentDescription: "Artist – Album",
      keywords: ["Song Title", "Artist", "Album"],
      textContent: "lorem ipsum",
      rating: 4,
      playCount: 12,
      lastUsedDate: lastPlayed,
      thumbnailFileURL: URL(fileURLWithPath: "/tmp/art.png"),
      isAudioContent: true
    )
    let item = descriptor.makeSearchableItem()
    XCTAssertEqual(item.uniqueIdentifier, "song:a-b:7")
    XCTAssertEqual(item.domainIdentifier, "a-b")
    XCTAssertEqual(item.attributeSet.title, "Song Title")
    XCTAssertEqual(item.attributeSet.contentDescription, "Artist – Album")
    XCTAssertEqual(item.attributeSet.keywords as? [String], ["Song Title", "Artist", "Album"])
    XCTAssertEqual(item.attributeSet.textContent, "lorem ipsum")
    XCTAssertEqual(item.attributeSet.rating, NSNumber(value: 4))
    XCTAssertEqual(item.attributeSet.playCount, NSNumber(value: 12))
    XCTAssertEqual(item.attributeSet.lastUsedDate, lastPlayed)
    XCTAssertEqual(item.attributeSet.thumbnailURL, URL(fileURLWithPath: "/tmp/art.png"))
  }

  // MARK: opt-out gating

  func testStartWithIndexingDisabledDeletesIndex() async {
    settings.user.isSpotlightIndexingEnabled = false
    let indexer = makeIndexer()
    await indexer.start()
    XCTAssertEqual(mockIndex.deleteAllCallCount, 1)
    XCTAssertFalse(AmperfySettings().app.hasCompletedInitialSpotlightIndex)
  }

  // MARK: delta pipeline

  func testDrainAppliesDeletes() async {
    let indexer = makeIndexer()
    let identifier = SpotlightItemIdentifier(type: .album, accountIdent: "a-b", id: "7")
    await indexer.enqueue([.delete(identifier: identifier.encoded)])
    await indexer.drainPending()
    XCTAssertEqual(mockIndex.deletedIdentifiers, [identifier.encoded])
  }

  func testUpsertIndexesSeededSong() async {
    let indexer = makeIndexer()
    guard let account = library.getAccount(ident: TestAccountInfo.create1().ident),
          let song = library.getSong(for: account, id: "36")
    else { XCTFail(); return }
    let objectUri = song.objectID.uriRepresentation().absoluteString

    await indexer.enqueue([.upsert(objectUri: objectUri)])
    await indexer.drainPending()

    let expected = SpotlightItemIdentifier(type: .song, accountIdent: account.ident, id: "36")
    guard let item = mockIndex.indexedItems
      .first(where: { $0.uniqueIdentifier == expected.encoded })
    else { XCTFail("song not indexed"); return }
    XCTAssertEqual(item.domainIdentifier, account.ident)
    XCTAssertEqual(item.attributeSet.title, "son")
    XCTAssertEqual(item.attributeSet.contentDescription, "She or He – Du Hast")
  }

  func testFullReindexIndexesSeededLibrary() async {
    let indexer = makeIndexer()
    await indexer.start(forceFullReindex: true)
    await indexer.awaitFullReindex()
    XCTAssertFalse(mockIndex.indexedItems.isEmpty)
    XCTAssertTrue(AmperfySettings().app.hasCompletedInitialSpotlightIndex)
    // seeder: 21 songs + 6 albums + 5 artists + 6 playlists
    XCTAssertTrue(mockIndex.indexedItems.contains {
      $0.uniqueIdentifier == "song:\(TestAccountInfo.create1().ident):36"
    })
  }

  // MARK: token extraction

  func testExtractChangeTokensClassifiesObjects() {
    let account = library.getAccount(ident: TestAccountInfo.create1().ident)!
    let song = library.createSong(account: account)
    song.id = "newSong42"
    song.title = "fresh"
    let notification = Notification(
      name: .NSManagedObjectContextDidSave,
      object: nil,
      userInfo: [NSInsertedObjectsKey: Set([song.managedObject])]
    )
    let tokens = SpotlightIndexer.extractChangeTokens(from: notification)
    guard tokens.count == 1, case .upsert(let uri) = tokens[0] else {
      XCTFail()
      return
    }
    XCTAssertEqual(uri, song.objectID.uriRepresentation().absoluteString)
  }

  func testDeleteIdentifierForDeletedObject() {
    let account = library.getAccount(ident: TestAccountInfo.create1().ident)!
    let song = library.getSong(for: account, id: "36")!
    let identifier = SpotlightIndexer.deleteIdentifier(for: song.managedObject)
    XCTAssertEqual(
      identifier,
      SpotlightItemIdentifier(type: .song, accountIdent: account.ident, id: "36")
    )
  }
}
