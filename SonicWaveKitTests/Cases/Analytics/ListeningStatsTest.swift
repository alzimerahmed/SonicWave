//
//  ListeningStatsTest.swift
//  SonicWaveKitTests
//
//  Created by Alzimer Ahmed on 26.10.26.
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
class ListeningStatsTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  // MARK: Migration chain (v52)

  func testMigrationVersionChainReachesV52() {
    XCTAssertEqual(CoreDataMigrationVersion.current, .v52)
    XCTAssertEqual(CoreDataMigrationVersion.v51.nextVersion(), .v52)
    XCTAssertNil(CoreDataMigrationVersion.v52.nextVersion())
  }

  func testLibrarySyncVersionIsV24() {
    XCTAssertEqual(LibrarySyncVersion.newestVersion, .v24)
    XCTAssertEqual(LibrarySyncVersion.v24.rawValue, 18)
    XCTAssertTrue(LibrarySyncVersion.v23 < LibrarySyncVersion.v24)
  }

  // MARK: PlayCountingRule

  func testPlayCountingRuleThresholds() {
    // 4-minute cap for long songs, half-duration below it
    XCTAssertEqual(PlayCountingRule.thresholdSeconds(forTrackDuration: 600), 240)
    XCTAssertEqual(PlayCountingRule.thresholdSeconds(forTrackDuration: 480), 240)
    XCTAssertEqual(PlayCountingRule.thresholdSeconds(forTrackDuration: 300), 150)
    XCTAssertEqual(PlayCountingRule.thresholdSeconds(forTrackDuration: 100), 50)
    // unknown duration collapses to zero — any listen counts
    XCTAssertEqual(PlayCountingRule.thresholdSeconds(forTrackDuration: 0), 0)
  }

  func testPlayCountingRuleCountedVsSkip() {
    XCTAssertTrue(PlayCountingRule.isCountedAsPlay(secondsListened: 150, trackDuration: 300))
    XCTAssertFalse(PlayCountingRule.isCountedAsPlay(secondsListened: 149, trackDuration: 300))
    XCTAssertTrue(PlayCountingRule.isCountedAsPlay(secondsListened: 240, trackDuration: 0))
  }

  // MARK: ListeningSession accumulation

  func testSessionAccumulatesAudibleTime() {
    var session = ListeningSession()
    let t0 = fixedNow
    session.markAudible(at: t0)
    session.pause(at: t0.addingTimeInterval(30))
    session.markAudible(at: t0.addingTimeInterval(60))
    // running leg adds to the sealed total
    XCTAssertEqual(session.elapsedSeconds(until: t0.addingTimeInterval(80)), 50)
  }

  func testSessionMarkAudibleIsIdempotent() {
    var session = ListeningSession()
    let t0 = fixedNow
    session.markAudible(at: t0)
    // the FromBeginning→StartedPlaying pair and a redundant resume
    // must not reset the clock — no double counting
    session.markAudible(at: t0.addingTimeInterval(5))
    session.markAudible(at: t0.addingTimeInterval(10))
    XCTAssertEqual(session.elapsedSeconds(until: t0.addingTimeInterval(40)), 40)
  }

  func testSessionPauseWithoutAudibleIsNoOp() {
    var session = ListeningSession()
    session.pause(at: fixedNow.addingTimeInterval(10))
    XCTAssertEqual(session.elapsedSeconds(until: fixedNow.addingTimeInterval(20)), 0)
  }

  // MARK: ListeningPeriod

  func testPeriodStartDates() {
    let calendar = Calendar(identifier: .gregorian)
    XCTAssertEqual(
      ListeningPeriod.week.startDate(from: fixedNow, calendar: calendar),
      calendar.date(byAdding: .day, value: -7, to: fixedNow)
    )
    XCTAssertEqual(
      ListeningPeriod.month.startDate(from: fixedNow, calendar: calendar),
      calendar.date(byAdding: .month, value: -1, to: fixedNow)
    )
    XCTAssertEqual(
      ListeningPeriod.year.startDate(from: fixedNow, calendar: calendar),
      calendar.date(byAdding: .year, value: -1, to: fixedNow)
    )
    XCTAssertNil(ListeningPeriod.allTime.startDate(from: fixedNow, calendar: calendar))
  }

  // MARK: Aggregation

  private func event(
    seconds: Int,
    counted: Bool = true,
    title: String? = "Song",
    artist: String? = "Artist",
    album: String? = "Album",
    genre: String? = "Genre",
    playableId: String? = "id",
    daysAgo: Int = 0
  ) -> PlayEventSnapshot {
    PlayEventSnapshot(
      date: fixedNow.addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
      secondsListened: seconds,
      trackDuration: 300,
      isCountedAsPlay: counted,
      title: title,
      artistName: artist,
      albumName: album,
      genreName: genre,
      playableId: playableId
    )
  }

  func testAggregateTotalsAndSkipCounting() {
    let stats = ListeningStatsAggregator.aggregate(
      [
        event(seconds: 200, counted: true, playableId: "a"),
        event(seconds: 10, counted: false, playableId: "a"),
        event(seconds: 100, counted: true, playableId: "b"),
      ],
      period: .week
    )
    XCTAssertEqual(stats.secondsListened, 310)
    XCTAssertEqual(stats.playCount, 2)
    XCTAssertEqual(stats.skipCount, 1)
    XCTAssertEqual(stats.uniqueSongCount, 2)
  }

  func testTopSongsRankedByCountedPlays() {
    // "b" wins on play count even though "a" has more seconds — skips
    // add listening time but never chart position
    let stats = ListeningStatsAggregator.aggregate(
      [
        event(seconds: 500, counted: false, playableId: "a", title: "A"),
        event(seconds: 200, counted: true, playableId: "a", title: "A"),
        event(seconds: 100, counted: true, playableId: "b", title: "B"),
        event(seconds: 100, counted: true, playableId: "b", title: "B"),
      ],
      period: .allTime
    )
    XCTAssertEqual(stats.topSongs.map(\.name), ["B", "A"])
    XCTAssertEqual(stats.topSongs.first?.playCount, 2)
    XCTAssertEqual(stats.topSongs.first?.secondsListened, 200)
    // "a" still shows its full 700 seconds
    XCTAssertEqual(stats.topSongs.last?.secondsListened, 700)
  }

  func testOrphanEventsGroupByDenormalizedNames() {
    // playable deleted → playableId nil → grouped by title+artist, not
    // collapsed into a single "unknown" bucket
    let stats = ListeningStatsAggregator.aggregate(
      [
        event(seconds: 100, title: "Gone", artist: "X", playableId: nil),
        event(seconds: 100, title: "Gone", artist: "X", playableId: nil),
        event(seconds: 100, title: "Gone", artist: "Y", playableId: nil),
      ],
      period: .allTime
    )
    XCTAssertEqual(stats.topSongs.count, 2)
    XCTAssertEqual(stats.topSongs.first?.playCount, 2)
    XCTAssertEqual(stats.topSongs.first?.detail, "X")
  }

  func testTopArtistsAlbumsGenresGroupIndependently() {
    let stats = ListeningStatsAggregator.aggregate(
      [
        event(seconds: 100, artist: "Solo", album: "One", genre: "Rock", playableId: "1"),
        event(seconds: 100, artist: "Solo", album: "Two", genre: "Jazz", playableId: "2"),
        // same album name, different artist → two different albums
        event(seconds: 100, artist: "Other", album: "One", genre: "Rock", playableId: "3"),
      ],
      period: .allTime
    )
    XCTAssertEqual(stats.topArtists.count, 2)
    XCTAssertEqual(stats.topArtists.first?.name, "Solo")
    XCTAssertEqual(stats.topArtists.first?.playCount, 2)
    XCTAssertEqual(stats.topAlbums.count, 2)
    XCTAssertEqual(stats.topGenres.count, 2)
    XCTAssertEqual(stats.topGenres.first?.name, "Rock")
    XCTAssertEqual(stats.topGenres.first?.playCount, 2)
  }

  func testMissingNamesFallBackToUnknownBuckets() {
    let stats = ListeningStatsAggregator.aggregate(
      [event(seconds: 60, title: nil, artist: nil, album: nil, genre: nil, playableId: nil)],
      period: .allTime
    )
    XCTAssertEqual(stats.topSongs.first?.name, "Unknown Title")
    XCTAssertEqual(stats.topArtists.first?.name, "Unknown Artist")
    XCTAssertEqual(stats.topAlbums.first?.name, "Unknown Album")
    XCTAssertEqual(stats.topGenres.first?.name, "Unknown Genre")
  }

  func testTopLimitAndDeterministicOrder() {
    let events = (0..<15).map {
      event(seconds: 100, title: "T\($0)", playableId: "p\($0)")
    }
    let stats = ListeningStatsAggregator.aggregate(
      events,
      period: .allTime,
      topLimit: 10
    )
    XCTAssertEqual(stats.topSongs.count, 10)
    // equal counts → alphabetical tie-break keeps the order stable
    XCTAssertEqual(
      stats.topSongs.map(\.name),
      stats.topSongs.map(\.name).sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
    )
  }

  func testRecapTextContainsRealNumbers() {
    let stats = ListeningStatsAggregator.aggregate(
      [
        event(seconds: 3_600, artist: "Solo", album: "One", title: "Hit", playableId: "1"),
        event(seconds: 3_600, artist: "Solo", album: "One", title: "Hit", playableId: "1"),
      ],
      period: .week
    )
    let recap = ListeningStatsAggregator.recapText(for: stats)
    XCTAssertTrue(recap.contains("Last 7 Days"))
    XCTAssertTrue(recap.contains("2 plays"))
    XCTAssertTrue(recap.contains("Solo (2 plays)"))
    XCTAssertFalse(recap.isEmpty)
  }

  // MARK: Storage round-trip

  private func seedPlayEvent(
    seconds: Int,
    counted: Bool = true,
    date: Date? = nil,
    on account: Account? = nil
  ) -> PlayEvent {
    let event = library.createPlayEvent(account: account ?? self.account)
    event.date = date ?? fixedNow
    event.secondsListened = seconds
    event.trackDuration = 300
    event.isCountedAsPlay = counted
    event.title = "t"
    event.artistName = "a"
    event.albumName = "al"
    event.genreName = "g"
    return event
  }

  func testPlayEventPersistsAndFetches() {
    let event = seedPlayEvent(seconds: 120)
    event.playable = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    library.saveContext()

    let events = library.getPlayEvents(for: account, since: nil)
    XCTAssertEqual(events.count, 1)
    let fetched = events[0]
    XCTAssertEqual(fetched.secondsListened, 120)
    XCTAssertTrue(fetched.isCountedAsPlay)
    XCTAssertEqual(fetched.artistName, "a")
    XCTAssertEqual(fetched.playable?.id, cdHelper.seeder.songs[0].id)
    XCTAssertEqual(fetched.asSnapshot.playableId, cdHelper.seeder.songs[0].id)
  }

  func testGetPlayEventsSinceFiltersAndSortsNewestFirst() {
    _ = seedPlayEvent(seconds: 10, date: fixedNow.addingTimeInterval(-9 * 86_400))
    _ = seedPlayEvent(seconds: 20, date: fixedNow.addingTimeInterval(-1 * 86_400))
    library.saveContext()

    guard let weekAgo = Calendar(identifier: .gregorian)
      .date(byAdding: .day, value: -7, to: fixedNow)
    else { XCTFail(); return }
    let recent = library.getPlayEvents(for: account, since: weekAgo)
    XCTAssertEqual(recent.count, 1)
    XCTAssertEqual(recent.first?.secondsListened, 20)

    let all = library.getPlayEvents(for: account, since: nil)
    XCTAssertEqual(all.count, 2)
    XCTAssertEqual(all.map(\.secondsListened), [20, 10])
  }

  func testGetPlayEventCountAndAccountIsolation() {
    _ = seedPlayEvent(seconds: 10)
    _ = seedPlayEvent(seconds: 20)
    // getAccount(info:) is get-or-create; the seeder already made it
    let account2 = library.getAccount(info: TestAccountInfo.create2())
    _ = seedPlayEvent(seconds: 30, on: account2)
    library.saveContext()

    XCTAssertEqual(library.getPlayEventCount(for: account), 2)
    XCTAssertEqual(library.getPlayEvents(for: account, since: nil).count, 2)
    XCTAssertEqual(library.getPlayEventCount(for: account2), 1)
  }

  func testDeleteAllPlayEvents() {
    _ = seedPlayEvent(seconds: 10)
    _ = seedPlayEvent(seconds: 20)
    library.saveContext()
    XCTAssertEqual(library.getPlayEventCount(for: account), 2)

    library.deleteAllPlayEvents()
    XCTAssertEqual(library.getPlayEventCount(for: account), 0)
    XCTAssertTrue(library.getPlayEvents(for: account, since: nil).isEmpty)
  }

  // MARK: Provider pipeline

  func testStatsProviderHonorsPeriodWindow() {
    _ = seedPlayEvent(seconds: 100, date: fixedNow.addingTimeInterval(-10 * 86_400))
    _ = seedPlayEvent(seconds: 200, date: fixedNow)
    library.saveContext()

    let provider = ListeningStatsProvider(library: library)
    let week = provider.stats(for: account, period: .week, now: fixedNow)
    XCTAssertEqual(week.secondsListened, 200)
    XCTAssertEqual(week.playCount, 1)

    let all = provider.stats(for: account, period: .allTime, now: fixedNow)
    XCTAssertEqual(all.secondsListened, 300)
    XCTAssertEqual(all.playCount, 2)

    XCTAssertTrue(provider.hasAnyEvents(for: account))
  }

  func testStatsProviderEmptyLibrary() {
    let provider = ListeningStatsProvider(library: library)
    let stats = provider.stats(for: account, period: .week, now: fixedNow)
    XCTAssertTrue(stats.isEmpty)
    XCTAssertFalse(provider.hasAnyEvents(for: account))
    XCTAssertTrue(stats.topSongs.isEmpty)
  }
}
