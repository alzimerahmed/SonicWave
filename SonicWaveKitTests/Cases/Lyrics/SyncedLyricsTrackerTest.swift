//
//  SyncedLyricsTrackerTest.swift
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

import Combine
import CoreMedia
@testable import SonicWaveKit
import XCTest

// MARK: - SyncedLyricsTrackerTest

/// `SyncedLyricsTracker` (G4 playback tracker): resolution on track
/// change, active line/word computation off the lyrics tick, seek
/// recompute (incl. paused seeks), unsynced/no-lyrics degradation and
/// stop clearing. The lyrics provider is a stub closure — the source
/// chain itself is covered by `SyncedLyricsLookupTest`.
@MainActor
class SyncedLyricsTrackerTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var song: Song!
  var otherSong: Song!

  var currentPlayable: AbstractPlayable?
  var elapsedSeconds = 0.0
  var providerCalls = 0
  var providerResult: LyricsResult = .none
  var providerCallExpectation: XCTestExpectation?
  var tracker: SyncedLyricsTracker!
  var cancellables = Set<AnyCancellable>()

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    song = library.getSong(for: account, id: "36")
    otherSong = library.getSong(for: account, id: "38")
    currentPlayable = nil
    elapsedSeconds = 0
    providerCalls = 0
    providerResult = .none
    providerCallExpectation = nil
    tracker = SyncedLyricsTracker(
      currentlyPlayingCB: { self.currentPlayable },
      elapsedTimeCB: { self.elapsedSeconds },
      lyricsProvider: { _ in
        self.providerCalls += 1
        self.providerCallExpectation?.fulfill()
        return self.providerResult
      }
    )
    cancellables = []
  }

  // MARK: fixtures

  /// synced lyrics at 0s / 10s / 20s — line 1 carries two word timings
  /// at 10.0s and 10.5s for word-index assertions
  func makeSyncedLyrics() -> SyncedLyrics {
    var lyrics = SyncedLyrics()
    lyrics.synced = true
    lyrics.lines = [
      LyricLine(start: 0, value: "one"),
      LyricLine(start: 10_000, value: "two", words: [
        LyricWord(start: 10_000, value: "tw"),
        LyricWord(start: 10_500, value: "o"),
      ]),
      LyricLine(start: 20_000, value: "three"),
    ]
    return lyrics
  }

  func waitForProviderCall() {
    providerCallExpectation = expectation(description: "lyrics resolved")
    wait(for: [providerCallExpectation!], timeout: 2.0)
  }

  // MARK: resolution

  func testTrackStart_ResolvesAndPublishesSyncedLyrics() {
    providerResult = .synced(makeSyncedLyrics())
    currentPlayable = song

    tracker.didStartPlaying()
    waitForProviderCall()

    XCTAssertEqual(providerCalls, 1)
    guard case .synced(let lyrics) = tracker.update.result else {
      XCTFail("expected synced lyrics, got \(tracker.update.result)")
      return
    }
    XCTAssertEqual(lyrics.lines.count, 3)
    XCTAssertEqual(tracker.currentLyrics, lyrics)
  }

  func testTrackStart_NoLyrics_StaysNone() {
    providerResult = .none
    currentPlayable = song

    tracker.didStartPlaying()
    waitForProviderCall()

    XCTAssertEqual(providerCalls, 1)
    XCTAssertEqual(tracker.update.result, .none)
    XCTAssertNil(tracker.update.activeLine)
  }

  func testTrackChange_RefetchesAndResets() {
    providerResult = .synced(makeSyncedLyrics())
    currentPlayable = song
    tracker.didStartPlaying()
    waitForProviderCall()
    XCTAssertEqual(providerCalls, 1)

    currentPlayable = otherSong
    tracker.didStartPlaying()
    waitForProviderCall()

    XCTAssertEqual(providerCalls, 2)
    guard case .synced = tracker.update.result else {
      XCTFail("expected synced lyrics after track change")
      return
    }
  }

  // MARK: line & word tracking

  func testLyricsTick_ComputesActiveLineAndWord() {
    providerResult = .synced(makeSyncedLyrics())
    currentPlayable = song
    tracker.didStartPlaying()
    waitForProviderCall()

    tracker.didLyricsTimeChange(time: CMTime(seconds: 5, preferredTimescale: 1_000))
    XCTAssertEqual(tracker.update.activeLine?.index, 0)

    tracker.didLyricsTimeChange(time: CMTime(seconds: 15, preferredTimescale: 1_000))
    XCTAssertEqual(tracker.update.activeLine?.index, 1)
    // 15s is past both word timestamps (10.0s / 10.5s) -> last word
    XCTAssertEqual(tracker.update.activeWordIndex, 1)

    tracker.didLyricsTimeChange(time: CMTime(seconds: 10.2, preferredTimescale: 1_000))
    XCTAssertEqual(tracker.update.activeLine?.index, 1)
    XCTAssertEqual(tracker.update.activeWordIndex, 0)

    tracker.didLyricsTimeChange(time: CMTime(seconds: 25, preferredTimescale: 1_000))
    XCTAssertEqual(tracker.update.activeLine?.index, 2)
  }

  func testSeek_RecomputesIndexImmediately() {
    providerResult = .synced(makeSyncedLyrics())
    currentPlayable = song
    tracker.didStartPlaying()
    waitForProviderCall()

    tracker.didLyricsTimeChange(time: CMTime(seconds: 25, preferredTimescale: 1_000))
    XCTAssertEqual(tracker.update.activeLine?.index, 2)

    // paused seek — no tick fires, so the UI calls the position API
    tracker.updatePlaybackPosition(seconds: 5)
    XCTAssertEqual(tracker.update.activeLine?.index, 0)
    XCTAssertNil(tracker.update.activeWordIndex)
  }

  func testLyricsOffset_ShiftsActiveLine() {
    var lyrics = makeSyncedLyrics()
    lyrics.offset = 5_000 // lines become active 5s earlier
    providerResult = .synced(lyrics)
    currentPlayable = song
    tracker.didStartPlaying()
    waitForProviderCall()

    // raw 6s + 5s offset = 11s -> line 1 (starts 10s)
    tracker.didLyricsTimeChange(time: CMTime(seconds: 6, preferredTimescale: 1_000))
    XCTAssertEqual(tracker.update.activeLine?.index, 1)
    // word timing uses the same adjusted position: 11s > 10.5s -> word 1
    XCTAssertEqual(tracker.update.activeWordIndex, 1)
  }

  // MARK: degradation

  func testUnsyncedResult_PublishesPlainTextWithoutTicking() {
    providerResult = .plain(SyncedLyrics(plainText: "a\nb", source: .ampache))
    currentPlayable = song
    tracker.didStartPlaying()
    waitForProviderCall()

    guard case .plain = tracker.update.result else {
      XCTFail("expected plain lyrics")
      return
    }
    tracker.didLyricsTimeChange(time: CMTime(seconds: 15, preferredTimescale: 1_000))
    XCTAssertNil(tracker.update.activeLine)
    XCTAssertNil(tracker.update.activeWordIndex)
  }

  func testStop_ClearsPublishedState() {
    providerResult = .synced(makeSyncedLyrics())
    currentPlayable = song
    tracker.didStartPlaying()
    waitForProviderCall()
    tracker.didLyricsTimeChange(time: CMTime(seconds: 15, preferredTimescale: 1_000))
    XCTAssertNotNil(tracker.update.activeLine)

    currentPlayable = nil
    tracker.didStopPlaying()
    XCTAssertEqual(tracker.update.result, .none)
    XCTAssertNil(tracker.update.activeLine)
    XCTAssertNil(tracker.update.activeWordIndex)
  }

  func testNonSongPlayable_ResolvesAsNone() {
    providerResult = .none
    guard let radio = library.getRadios(for: account).first else {
      XCTFail("seeded radio missing")
      return
    }
    currentPlayable = radio
    tracker.didStartPlaying()
    waitForProviderCall()

    XCTAssertEqual(tracker.update.result, .none)
  }
}
