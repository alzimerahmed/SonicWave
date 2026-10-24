//
//  SsDiscoveryParserTest.swift
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
import XCTest

/// Phase-8 fixture tests for the new DTO parser delegates
/// (G18 shares, G20 artistInfo2/topSongs).
class SsDiscoveryParserTest: XCTestCase {
  var xmlErrorData: Data!

  override func setUp() async throws {
    xmlErrorData = getTestFileData(name: "error_example_1")
  }

  private func parse<Delegate: SsXmlParser>(
    data: Data,
    delegate: Delegate
  ) -> Delegate {
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate
  }

  // MARK: getShares

  func testSharesParsing() {
    let delegate = parse(
      data: getTestFileData(name: "shares_example_1"),
      delegate: SsSharesParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    )
    XCTAssertNil(delegate.error)
    XCTAssertEqual(delegate.shares.count, 2)

    let first = delegate.shares[0]
    XCTAssertEqual(first.id, "sh1")
    XCTAssertEqual(first.url, "https://internal.example.com/share/sh1")
    XCTAssertEqual(first.description, "for bob")
    XCTAssertEqual(first.username, "alice")
    XCTAssertEqual(first.visitCount, 3)
    XCTAssertEqual(first.sharedObjectIds, ["657", "748"])
    XCTAssertNotNil(first.created)
    XCTAssertNotNil(first.expires)

    let second = delegate.shares[1]
    XCTAssertEqual(second.id, "sh2")
    XCTAssertNil(second.expires)
    XCTAssertEqual(second.sharedObjectIds, [])
  }

  func testSharesErrorParsing() {
    let delegate = parse(
      data: xmlErrorData,
      delegate: SsSharesParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    )
    XCTAssertEqual(delegate.error?.statusCode, 40)
  }

  // MARK: getArtistInfo2

  func testArtistInfo2Parsing() {
    let delegate = parse(
      data: getTestFileData(name: "artistInfo2_example_1"),
      delegate: SsArtistInfoParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    )
    XCTAssertNil(delegate.error)
    let info = delegate.artistInfo
    XCTAssertEqual(info.biography, "A fine band.")
    XCTAssertEqual(info.musicBrainzId, "mb-123")
    XCTAssertEqual(info.lastFmUrl, "https://last.fm/x")
    XCTAssertEqual(info.largeImageUrl, "https://i/l.png")
    XCTAssertEqual(info.similarArtists.count, 2)
    XCTAssertEqual(info.similarArtists[0], ArtistStub(id: "a1", name: "Band One"))
    XCTAssertEqual(info.similarArtists[1], ArtistStub(id: nil, name: "Band Two"))
  }

  // MARK: getTopSongs

  func testTopSongsParsing() {
    let delegate = parse(
      data: getTestFileData(name: "topSongs_example_1"),
      delegate: SsTopSongsParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    )
    XCTAssertNil(delegate.error)
    XCTAssertEqual(delegate.topSongs.count, 2)
    XCTAssertEqual(delegate.topSongs[0].id, "s1")
    XCTAssertEqual(delegate.topSongs[0].title, "Hit One")
    XCTAssertEqual(delegate.topSongs[0].artistName, "The Act")
    XCTAssertEqual(delegate.topSongs[0].duration, 210)
    XCTAssertEqual(delegate.topSongs[0].year, 1999)
    XCTAssertEqual(delegate.topSongs[0].coverArtId, "al-9")
    XCTAssertNil(delegate.topSongs[1].coverArtId)
  }

  // MARK: server type detection

  func testServerTypeDetectionFromSharesFixture() {
    let delegate = parse(
      data: getTestFileData(name: "shares_example_1"),
      delegate: SsPingParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    )
    XCTAssertEqual(delegate.serverType, "navidrome")
    XCTAssertEqual(delegate.serverProductVersion, "0.52.5")
  }
}
