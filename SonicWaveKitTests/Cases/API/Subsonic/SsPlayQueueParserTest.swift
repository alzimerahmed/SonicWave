//
//  SsPlayQueueParserTest.swift
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
import XCTest

class SsPlayQueueParserTest: XCTestCase {
  var xmlData: Data!
  var xmlErrorData: Data!

  override func setUp() async throws {
    xmlData = getTestFileData(name: "playqueue_example_1")
    xmlErrorData = getTestFileData(name: "error_example_1")
  }

  func testParsing() {
    let parserDelegate = SsPlayQueueParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor()
    )
    let parser = XMLParser(data: xmlData)
    parser.delegate = parserDelegate
    parser.parse()
    XCTAssertNil(parserDelegate.error)

    guard let remoteQueue = parserDelegate.remotePlayQueue else { XCTFail(); return }
    // the isDir=true entry must be skipped
    XCTAssertEqual(remoteQueue.songIds, ["657", "748", "884", "805"])
    XCTAssertEqual(remoteQueue.currentSongId, "748")
    XCTAssertEqual(remoteQueue.positionInMilliseconds, 63_000)
    XCTAssertEqual(remoteQueue.changedBy, "sonicwave-ios")

    let expectedChanged = SubsonicDateParser.parse("2024-05-17T10:15:30.000Z")
    XCTAssertNotNil(expectedChanged)
    XCTAssertEqual(remoteQueue.changedDate, expectedChanged)
  }

  func testMissingPlayQueueElement() {
    // a plain ping response has no <playQueue> element -> nil queue
    let parserDelegate = SsPlayQueueParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor()
    )
    let parser = XMLParser(data: getTestFileData(name: "ping_example_1"))
    parser.delegate = parserDelegate
    parser.parse()
    XCTAssertNil(parserDelegate.remotePlayQueue)
  }

  func testErrorParsing() {
    let parserDelegate = SsPlayQueueParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor()
    )
    let parser = XMLParser(data: xmlErrorData)
    parser.delegate = parserDelegate
    parser.parse()
    guard let error = parserDelegate.error else { XCTFail(); return }
    XCTAssertEqual(error.statusCode, 40)
    XCTAssertEqual(error.message, "Wrong username or password")
  }

  func testDateParsingWithAndWithoutFractionalSeconds() {
    let expected = SubsonicDateParser.parse("2024-05-17T10:15:30")
    XCTAssertNotNil(expected)
    let withFraction = SubsonicDateParser.parse("2024-05-17T10:15:30.000Z")
    XCTAssertNotNil(withFraction)
    XCTAssertEqual(expected, withFraction)
    XCTAssertNil(SubsonicDateParser.parse(nil))
    XCTAssertNil(SubsonicDateParser.parse("not a date"))
  }
}
