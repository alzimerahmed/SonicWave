//
//  LrclibResponseParserTest.swift
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

/// LRCLIB `GET /api/get` JSON -> `LrclibTrack` decode -> `LrcParser`.
class LrclibResponseParserTest: XCTestCase {
  func testDecodeGetResponse() throws {
    let data = getTestFileData(name: "lrclib_get_example_1", withExtension: "json")
    let track = try JSONDecoder().decode(LrclibTrack.self, from: data)

    XCTAssertEqual(track.id, 3_396_226)
    XCTAssertEqual(track.trackName, "I Want to Live")
    XCTAssertEqual(track.artistName, "Borislav Slavov")
    XCTAssertEqual(track.albumName, "Baldur's Gate 3 (Original Game Soundtrack)")
    XCTAssertEqual(track.duration, 233.0)
    XCTAssertEqual(track.instrumental, false)
    XCTAssertNotNil(track.plainLyrics)
    XCTAssertNotNil(track.syncedLyrics)
  }

  func testSyncedLyricsFieldParsesToSynced() throws {
    let data = getTestFileData(name: "lrclib_get_example_1", withExtension: "json")
    let track = try JSONDecoder().decode(LrclibTrack.self, from: data)
    guard let syncedLyrics = track.syncedLyrics else { XCTFail(); return }

    var lyrics = LrcParser.parse(syncedLyrics)
    lyrics.source = .lrclib
    XCTAssertTrue(lyrics.synced)
    XCTAssertEqual(lyrics.lines.count, 3)
    XCTAssertEqual(lyrics.lines[0].start, 10_240)
    XCTAssertEqual(lyrics.lines[0].value, "I feel your breath upon my neck")
    XCTAssertEqual(lyrics.lines[1].start, 22_080)
    XCTAssertEqual(lyrics.lines[2].start, 35_500)

    guard case .synced = LyricsResult(wrapping: lyrics) else { XCTFail(); return }
  }

  func testMissingFieldsDecodeAsNil() throws {
    // LRCLIB omits/nulls lyrics fields for instrumental tracks
    let json = """
    {"id": 1, "trackName": "T", "artistName": "A", "albumName": "B", \
    "duration": 60.0, "instrumental": true, "plainLyrics": null, "syncedLyrics": null}
    """
    let track = try JSONDecoder().decode(LrclibTrack.self, from: Data(json.utf8))
    XCTAssertEqual(track.instrumental, true)
    XCTAssertNil(track.plainLyrics)
    XCTAssertNil(track.syncedLyrics)
  }
}
