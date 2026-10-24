//
//  DiscoveryTest.swift
//  SonicWaveKitTests
//
//  Created by Alzimer Ahmed on 24.02.26.
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

/// Phase-8 unit tests: `.nsp` criteria parsing, criteria → NSPredicate,
/// local evaluation, share URL rewriting, mix provider composition.
@MainActor
class DiscoveryTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  private func nspData() -> Data {
    getTestFileData(name: "smartplaylist_example_1", withExtension: "json")
  }

  // MARK: .nsp parsing

  func testNspParsingMapsRules() {
    guard let nsp = NspCriteriaParser.parse(data: nspData()) else { XCTFail(); return }
    XCTAssertEqual(nsp.name, "80s Top Songs")
    XCTAssertEqual(nsp.comment, "rated gems of the eighties")
    XCTAssertTrue(nsp.isPublic)

    let criteria = nsp.criteria
    XCTAssertEqual(criteria.combination, .matchAll)
    XCTAssertEqual(criteria.limit, 25)
    XCTAssertTrue(criteria.isImportedFromServer)
    // nested `any` inside `all` cannot be expressed by the flat model —
    // its note is recorded; isMissing (bpm) is an unsupported operator
    XCTAssertTrue(criteria.unsupportedNotes.contains { $0.contains("nested 'any'") })
    XCTAssertTrue(criteria.unsupportedNotes.contains { $0.contains("ismissing") })

    // remaining rules: inTheRange year, inTheLast lastPlayed, contains artist,
    // isNot genre — the two unrepresentable ones were dropped
    XCTAssertEqual(criteria.rules.count, 4)
    XCTAssertEqual(criteria.rules[0].field, .year)
    XCTAssertEqual(criteria.rules[0].operator, .inRange)
    XCTAssertEqual(
      criteria.rules[0].value,
      .intRange(lower: 1_981, upper: 1_990)
    )
    XCTAssertEqual(criteria.rules[1].field, .lastPlayed)
    XCTAssertEqual(criteria.rules[1].operator, .inLastDays)
    XCTAssertEqual(criteria.rules[1].value, .days(30))
    XCTAssertEqual(criteria.rules[2].field, .artist)
    XCTAssertEqual(criteria.rules[2].operator, .contains)
    XCTAssertEqual(criteria.rules[3].field, .genre)
    XCTAssertEqual(criteria.rules[3].operator, .notEqual)

    XCTAssertEqual(criteria.sort?.field, .year)
    XCTAssertEqual(criteria.sort?.ascending, false)
  }

  func testNspCodableRoundTrip() throws {
    guard let nsp = NspCriteriaParser.parse(data: nspData()) else { XCTFail(); return }
    let encoded = try JSONEncoder().encode(nsp.criteria)
    let decoded = try JSONDecoder().decode(SmartPlaylistCriteria.self, from: encoded)
    XCTAssertEqual(nsp.criteria, decoded)
  }

  // MARK: criteria → predicate

  func testPredicateBuilding() {
    var criteria = SmartPlaylistCriteria(combination: .matchAll)
    criteria.rules = [
      SmartPlaylistRule(field: .rating, operator: .greaterThan, value: .int(3)),
      SmartPlaylistRule(field: .genre, operator: .contains, value: .text("rock")),
      SmartPlaylistRule(field: .favorite, operator: .equal, value: .bool(true)),
    ]
    let predicate = criteria.predicate()
    XCTAssertTrue(predicate is NSCompoundPredicate)
    XCTAssertEqual(predicate.predicateFormat.contains("rating > 3"), true)

    // matchAny composition
    var anyCriteria = SmartPlaylistCriteria(combination: .matchAny)
    anyCriteria.rules = criteria.rules
    let anyPredicate = anyCriteria.predicate()
    XCTAssertTrue(anyPredicate.predicateFormat.contains(" OR "))

    // empty matchAll degrades to TRUEPREDICATE
    XCTAssertEqual(SmartPlaylistCriteria().predicate().predicateFormat, "TRUEPREDICATE")
    // empty matchAny degrades to FALSEPREDICATE
    let emptyAny = SmartPlaylistCriteria(combination: .matchAny)
    XCTAssertEqual(emptyAny.predicate().predicateFormat, "FALSEPREDICATE")
  }

  func testInLastDaysPredicateUsesDateField() {
    var criteria = SmartPlaylistCriteria()
    criteria.rules = [SmartPlaylistRule(
      field: .lastPlayed,
      operator: .inLastDays,
      value: .days(30)
    )]
    let predicate = criteria.predicate()
    XCTAssertTrue(predicate.predicateFormat.contains("lastPlayedDate >="))
  }

  func testUnsupportedFieldSkipped() {
    var criteria = SmartPlaylistCriteria()
    criteria.rules = [
      SmartPlaylistRule(field: .custom("bpm"), operator: .greaterThan, value: .int(120)),
      SmartPlaylistRule(field: .rating, operator: .greaterThan, value: .int(3)),
    ]
    XCTAssertEqual(criteria.rules[0].isLocallyEvaluable, false)
    XCTAssertEqual(criteria.rules[1].isLocallyEvaluable, true)
    // only the evaluable rule enters the predicate
    XCTAssertEqual(criteria.predicate().predicateFormat, "rating > 3")
  }

  // MARK: local evaluation

  func testEvaluateFavoriteCriteria() {
    var criteria = SmartPlaylistCriteria()
    criteria.rules = [SmartPlaylistRule(
      field: .favorite,
      operator: .equal,
      value: .bool(true)
    )]
    let evaluator = SmartPlaylistEvaluator(storage: makeStorage(), account: account)
    let songs = evaluator.evaluate(criteria: criteria)
    XCTAssertEqual(songs.count, library.getFavoriteSongs(for: account).count)
    XCTAssertTrue(songs.allSatisfy { $0.isFavorite })
  }

  func testEvaluateRandomPickLimit() {
    let evaluator = SmartPlaylistEvaluator(storage: makeStorage(), account: account)
    let songs = evaluator.evaluate(
      criteria: SmartPlaylistCriteria(),
      randomPickLimit: 2
    )
    XCTAssertEqual(songs.count, 2)
  }

  private func makeStorage() -> PersistentStorage {
    PersistentStorage(coreDataManager: MOCK_CoreDataManager(
      persistentContainer: cdHelper.persistentContainer
    ))
  }

  // MARK: share URL rewriting (G18 publicUrlOverride)

  func testShareUrlRewriter() {
    let original = "https://internal.example.com/share/sh1?x=1"
    let rewritten = ShareUrlRewriter.rewrite(
      urlString: original,
      publicBaseUrl: "https://public.example.com:8443"
    )
    XCTAssertEqual(rewritten, "https://public.example.com:8443/share/sh1?x=1")
    // no override → unchanged
    XCTAssertEqual(
      ShareUrlRewriter.rewrite(urlString: original, publicBaseUrl: nil),
      original
    )
    // malformed override → unchanged
    XCTAssertEqual(
      ShareUrlRewriter.rewrite(urlString: original, publicBaseUrl: "not a url"),
      original
    )
  }

  // MARK: mix provider (G7)

  func testMixProviderLocalMixes() async throws {
    let provider = MixProvider(
      account: account,
      storage: makeStorage(),
      librarySyncer: MOCK_LibrarySyncer(),
      networkMonitor: MOCK_NetworkMonitor()
    )
    let mixes = provider.availableMixes()
    // seeded storage has songs + favorites → these mixes must exist
    XCTAssertTrue(mixes.contains { $0.kind == .favoritesRadio })
    XCTAssertTrue(mixes.contains { $0.kind == .deepCuts })
    XCTAssertTrue(mixes.contains { $0.kind == .timeOfDay })

    let favoritesMix = try XCTUnwrap(mixes.first { $0.kind == .favoritesRadio })
    let songs = try await provider.resolve(mix: favoritesMix, count: 5)
    XCTAssertFalse(songs.isEmpty)
    XCTAssertLessThanOrEqual(songs.count, 5)
  }

  func testMixProviderDecadeMix() async throws {
    let provider = MixProvider(
      account: account,
      storage: makeStorage(),
      librarySyncer: MOCK_LibrarySyncer(),
      networkMonitor: MOCK_NetworkMonitor()
    )
    // seeded songs carry years — resolve a decade that exists or skip
    let yearMix = Mix(
      kind: .decadeMix,
      title: "1990s",
      subtitle: "",
      parameter: "1990"
    )
    let songs = try await provider.resolve(mix: yearMix, count: 10)
    for song in songs {
      XCTAssertTrue((1_990 ... 1_999).contains(song.year))
    }
  }

  func testMixProviderOfflineFavoritesRadio() async throws {
    // no connectivity → favorites radio must resolve locally, no server call
    let provider = MixProvider(
      account: account,
      storage: makeStorage(),
      librarySyncer: MOCK_LibrarySyncer(),
      networkMonitor: MOCK_OfflineNetworkMonitor()
    )
    let songs = try await provider.resolve(
      mix: Mix(kind: .favoritesRadio, title: "", subtitle: ""),
      count: 5
    )
    XCTAssertFalse(songs.isEmpty)
    XCTAssertTrue(songs.allSatisfy { $0.isFavorite })
  }

  // MARK: BackendFeatureResult

  func testBackendFeatureResult() {
    let supported: BackendFeatureResult<Int> = .supported(5)
    XCTAssertEqual(supported.payload, 5)
    XCTAssertTrue(supported.isSupported)
    XCTAssertEqual(supported.map { $0 * 2 }.payload, 10)

    let unsupported: BackendFeatureResult<Int> = .notSupported
    XCTAssertNil(unsupported.payload)
    XCTAssertFalse(unsupported.isSupported)
    XCTAssertEqual(unsupported.map { $0 * 2 }.payload, nil)
  }
}

// MARK: - MOCK_OfflineNetworkMonitor

final class MOCK_OfflineNetworkMonitor: NetworkMonitorFacade {
  var connectionTypeChangedCB: ConnectionTypeChangedCallack? { get { nil } set {} }
  var isConnectedToNetwork: Bool { false }
  var isCellular: Bool { false }
  var isWifiOrEthernet: Bool { false }
}
