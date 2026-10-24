//
//  SyncedLyricsLookupTest.swift
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
import XCTest

/// `SyncedLyrics.activeLine` binary search + `StructuredLyrics` conversion,
/// including the `getLyricsBySongId` parser-delegate fixture path.
class SyncedLyricsLookupTest: XCTestCase {
  private func makeSyncedLyrics() -> SyncedLyrics {
    var lyrics = SyncedLyrics()
    lyrics.synced = true
    lyrics.lines = [
      LyricLine(start: 0, value: "line zero"),
      LyricLine(start: 2_000, value: "line two"),
      LyricLine(start: 4_000, value: "line four"),
      LyricLine(start: 6_000, value: "line six"),
      LyricLine(start: nil, value: "unsynced tail"),
    ]
    return lyrics
  }

  func testActiveLineBinarySearch() {
    let lyrics = makeSyncedLyrics()
    // before the first line
    XCTAssertNil(lyrics.activeLine(atMilliseconds: -1))
    // exact boundary + inside line
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 0)?.index, 0)
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 1_999)?.index, 0)
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 2_000)?.index, 1)
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 5_999)?.index, 2)
    // past the last timed line stays on it (never falls through to the
    // unsynced tail)
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 99_000)?.index, 3)
  }

  func testActiveLineProgress() {
    let lyrics = makeSyncedLyrics()
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 2_000)?.progress ?? -1, 0.0, accuracy: 0.001)
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 3_000)?.progress ?? -1, 0.5, accuracy: 0.001)
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 4_000)?.progress ?? -1, 0.0, accuracy: 0.001)
    // last timed line has no next start -> progress 0
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 8_000)?.progress ?? -1, 0.0, accuracy: 0.001)
  }

  func testActiveLineAppliesOffset() {
    var lyrics = makeSyncedLyrics()
    // positive offset -> lines appear earlier (line at 2000ms active at 1500ms)
    lyrics.offset = 500
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 1_500)?.index, 1)
    // raw start stays untouched
    XCTAssertEqual(lyrics.lines[1].start, 2_000)
  }

  func testActiveLineRejectsUnsynced() {
    var lyrics = makeSyncedLyrics()
    lyrics.synced = false
    XCTAssertNil(lyrics.activeLine(atMilliseconds: 3_000))
  }

  func testActiveWord() {
    let line = LyricLine(
      start: 1_000,
      value: "a b c",
      words: [
        LyricWord(start: 1_000, value: "a"),
        LyricWord(start: 1_500, value: "b"),
        LyricWord(start: 1_700, value: "c"),
      ]
    )
    XCTAssertNil(line.activeWord(atMilliseconds: 999))
    XCTAssertEqual(line.activeWord(atMilliseconds: 1_000)?.index, 0)
    XCTAssertEqual(line.activeWord(atMilliseconds: 1_250)?.progress ?? -1, 0.5, accuracy: 0.001)
    XCTAssertEqual(line.activeWord(atMilliseconds: 1_900)?.index, 2)
    // line without word timings
    XCTAssertNil(LyricLine(start: 0, value: "x").activeWord(atMilliseconds: 0))
  }

  /// `getLyricsBySongId` fixture -> `SsLyricsParserDelegate` ->
  /// `SyncedLyrics` conversion — the Subsonic source of the G4 chain.
  func testSubsonicStructuredLyricsConversion() {
    let xmlData = getTestFileData(name: "getLyricsBySongId_example_1")
    let parserDelegate = SsLyricsParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let parser = XMLParser(data: xmlData)
    parser.delegate = parserDelegate
    parser.parse()
    XCTAssertNil(parserDelegate.error)

    guard let lyricsList = parserDelegate.lyricsList,
          let structured = lyricsList.getFirstSyncedLyricsOrUnsyncedAsDefault()
    else { XCTFail(); return }

    let lyrics = SyncedLyrics(from: structured, source: .subsonic)
    XCTAssertTrue(lyrics.synced)
    XCTAssertEqual(lyrics.source, .subsonic)
    XCTAssertEqual(lyrics.lang, "en")
    XCTAssertEqual(lyrics.offset, -100)
    XCTAssertEqual(lyrics.title, "Hysteria")
    XCTAssertEqual(lyrics.artist, "Muse")
    XCTAssertEqual(lyrics.lines.count, 3)
    XCTAssertEqual(lyrics.lines[1].start, 2_000)
    XCTAssertEqual(lyrics.lines[1].value, "Grating me")
    XCTAssertEqual(lyrics.lines[1].words.count, 0)

    // LyricsResult wrapping + back-conversion to the legacy model
    guard case .synced = LyricsResult(wrapping: lyrics) else { XCTFail(); return }
    let roundTrip = lyrics.asStructuredLyrics
    XCTAssertTrue(roundTrip.synced)
    XCTAssertEqual(roundTrip.line.count, 3)
    XCTAssertEqual(roundTrip.line[2].start, 3_001)

    // offset -100 -> line at 0ms already active at playback start? No:
    // negative offset shifts lyrics later (active at start + 100ms)
    XCTAssertNil(lyrics.activeLine(atMilliseconds: 50))
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 100)?.index, 0)
    XCTAssertEqual(lyrics.activeLine(atMilliseconds: 2_100)?.index, 1)
  }

  func testPlainLyricsWrapsAsPlain() {
    let lyrics = SyncedLyrics(plainText: "a\nb", source: .embeddedTag, lang: "eng")
    XCTAssertFalse(lyrics.synced)
    guard case .plain(let wrapped) = LyricsResult(wrapping: lyrics) else {
      XCTFail()
      return
    }
    XCTAssertEqual(wrapped.source, .embeddedTag)
    XCTAssertEqual(wrapped.lines.count, 2)
  }

  /// Codable round-trip — the disk cache stores `SyncedLyrics` verbatim.
  func testCodableRoundTrip() throws {
    let lyrics = makeSyncedLyrics()
    let data = try JSONEncoder().encode(lyrics)
    let decoded = try JSONDecoder().decode(SyncedLyrics.self, from: data)
    XCTAssertEqual(decoded, lyrics)
  }
}
