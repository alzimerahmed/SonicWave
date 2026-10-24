//
//  LrcParserTest.swift
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

class LrcParserTest: XCTestCase {
  func testStandardSyncedLines() {
    let lyrics = LrcParser.parse(getTestFileString(name: "lrc_example_1"))
    XCTAssertTrue(lyrics.synced)
    XCTAssertEqual(lyrics.title, "Sonic Wave")
    XCTAssertEqual(lyrics.artist, "The Testers")
    XCTAssertEqual(lyrics.album, "Parser Sessions")
    XCTAssertEqual(lyrics.lang, "en")
    XCTAssertEqual(lyrics.offset, -100)

    let timed = lyrics.lines.filter { $0.start != nil }
    XCTAssertEqual(timed.count, 6) // 4 unique lines + 2 multi-timestamp repeats
    XCTAssertEqual(timed[0].start, 4_000)
    XCTAssertEqual(timed[0].value, "First synced line")
    XCTAssertEqual(timed[1].start, 8_500)
    XCTAssertEqual(timed[1].value, "Second synced line")
    XCTAssertEqual(timed[2].start, 12_340)
    XCTAssertEqual(timed[2].value, "Third synced line (ms precision)")
    // multi-timestamp line duplicates into two entries sharing the text
    XCTAssertEqual(timed[3].start, 20_000)
    XCTAssertEqual(timed[3].value, "Repeated chorus")
    XCTAssertEqual(timed[4].start, 40_000)
    XCTAssertEqual(timed[4].value, "Repeated chorus")
    // sorted by start, not by appearance order
    XCTAssertEqual(timed[5].start, 60_000)
    XCTAssertEqual(timed[5].value, "Outro")
  }

  func testMalformedLinesAreSkippedOrKeptUnsynced() {
    let lrc = """
    [ti:Song]
    [00:01.00]Good line
    [broken]also not a timestamp
    [00:xx.00]Bad timestamp
    [00:02.50]
    untimed plain text
    """
    let lyrics = LrcParser.parse(lrc)
    XCTAssertEqual(lyrics.title, "Song")
    // [broken] and [00:xx.00] are swallowed as unknown tags -> their line
    // text becomes an unsynced line; empty-timestamp line yields a blank line
    let timed = lyrics.lines.filter { $0.start != nil }
    XCTAssertEqual(timed.count, 2)
    XCTAssertEqual(timed[0].start, 1_000)
    XCTAssertEqual(timed[0].value, "Good line")
    XCTAssertEqual(timed[1].start, 2_500)
    XCTAssertEqual(timed[1].value, "")
    XCTAssertTrue(lyrics.synced)
    let unsynced = lyrics.lines.filter { $0.start == nil }
    XCTAssertEqual(unsynced.count, 3)
    XCTAssertEqual(unsynced[0].value, "also not a timestamp")
    XCTAssertEqual(unsynced[1].value, "Bad timestamp")
    XCTAssertEqual(unsynced[2].value, "untimed plain text")
    // unsynced lines sort after timed lines
    XCTAssertEqual(lyrics.lines.last?.start, nil)
  }

  func testEnhancedWordLevelTimestamps() {
    let lyrics = LrcParser.parse(getTestFileString(name: "lrc_enhanced_example_1"))
    XCTAssertTrue(lyrics.synced)
    let timed = lyrics.lines.filter { $0.start != nil }
    XCTAssertEqual(timed.count, 2)

    let first = timed[0]
    XCTAssertEqual(first.start, 10_000)
    XCTAssertEqual(first.value, "word one two")
    XCTAssertEqual(first.words.count, 3)
    XCTAssertEqual(first.words[0].start, 10_120)
    XCTAssertEqual(first.words[0].value, "word")
    XCTAssertEqual(first.words[1].start, 10_450)
    XCTAssertEqual(first.words[1].value, "one")
    XCTAssertEqual(first.words[2].start, 10_800)
    XCTAssertEqual(first.words[2].value, "two")

    // plain text without word stamps stays untouched
    XCTAssertEqual(timed[1].words.count, 0)
    XCTAssertEqual(timed[1].value, "line level only")
  }

  func testPlainTextDegradesToUnsynced() {
    let lyrics = LrcParser.parse("line one\nline two\nline three")
    XCTAssertFalse(lyrics.synced)
    XCTAssertEqual(lyrics.lines.count, 3)
    XCTAssertEqual(lyrics.lines[0].value, "line one")
    XCTAssertNil(lyrics.lines[0].start)
  }

  func testTimestampContent() {
    XCTAssertEqual(LrcParser.parseTimestampContent("00:12.34"), 12_340)
    XCTAssertEqual(LrcParser.parseTimestampContent("01:02.345"), 62_345)
    XCTAssertEqual(LrcParser.parseTimestampContent("02:00"), 120_000)
    XCTAssertEqual(LrcParser.parseTimestampContent("00:59.5"), 59_500)
    XCTAssertNil(LrcParser.parseTimestampContent("ti:Title"))
    XCTAssertNil(LrcParser.parseTimestampContent("offset:-100"))
    XCTAssertNil(LrcParser.parseTimestampContent("mm:ss.xx"))
    XCTAssertNil(LrcParser.parseTimestampContent(""))
  }

  func testOffsetMetadataAppliesToActiveLine() {
    let lyrics = LrcParser.parse("[offset:-2000]\n[00:05.00]line")
    XCTAssertEqual(lyrics.offset, -2_000)
    // line.start is raw — offset is applied in activeLine, so the line is
    // only active once time + offset >= start (5.0s + (-2.0s) = 3.0s? no:
    // positive offset shifts earlier, negative later -> active at 7.0s)
    XCTAssertNil(lyrics.activeLine(atSeconds: 5.5))
    XCTAssertNotNil(lyrics.activeLine(atSeconds: 7.0))
  }

  private func getTestFileString(name: String) -> String {
    String(data: getTestFileData(name: name, withExtension: "lrc"), encoding: .utf8)!
  }
}
