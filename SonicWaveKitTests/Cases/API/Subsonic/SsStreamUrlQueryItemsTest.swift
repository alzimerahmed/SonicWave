//
//  SsStreamUrlQueryItemsTest.swift
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
import XCTest

/// `stream` request building (G17): `timeOffset` is emitted only for
/// transcoding format preferences (`.raw` passes the file through
/// untouched) and only when the server advertised the OpenSubsonic
/// `transcodeOffset` extension.
class SsStreamUrlQueryItemsTest: XCTestCase {
  private func buildComponents(
    maxBitrate: StreamingMaxBitratePreference = .noLimit,
    formatPreference: StreamingFormatPreference,
    timeOffset: Int?,
    isTranscodeOffsetSupported: Bool
  )
    -> URLComponents {
    var urlComp = URLComponents(string: "https://test.local/rest/stream.view")!
    SubsonicServerApi.appendStreamQueryItems(
      to: &urlComp,
      maxBitrate: maxBitrate,
      formatPreference: formatPreference,
      timeOffset: timeOffset,
      isTranscodeOffsetSupported: isTranscodeOffsetSupported
    )
    return urlComp
  }

  private func value(of name: String, in urlComp: URLComponents) -> String? {
    urlComp.queryItems?.first(where: { $0.name == name })?.value
  }

  func testTranscodedMp3WithExtensionEmitsTimeOffset() {
    let urlComp = buildComponents(
      formatPreference: .mp3,
      timeOffset: 120,
      isTranscodeOffsetSupported: true
    )
    XCTAssertEqual(value(of: "timeOffset", in: urlComp), "120")
    XCTAssertEqual(value(of: "format", in: urlComp), "mp3")
  }

  func testRawFormatNeverEmitsTimeOffset() {
    let urlComp = buildComponents(
      formatPreference: .raw,
      timeOffset: 120,
      isTranscodeOffsetSupported: true
    )
    XCTAssertNil(value(of: "timeOffset", in: urlComp))
    XCTAssertEqual(value(of: "format", in: urlComp), "raw")
  }

  func testMissingExtensionSuppressesTimeOffset() {
    let urlComp = buildComponents(
      formatPreference: .mp3,
      timeOffset: 120,
      isTranscodeOffsetSupported: false
    )
    XCTAssertNil(value(of: "timeOffset", in: urlComp))
    XCTAssertEqual(value(of: "format", in: urlComp), "mp3")
  }

  func testNilOffsetEmitsNothing() {
    let urlComp = buildComponents(
      formatPreference: .mp3,
      timeOffset: nil,
      isTranscodeOffsetSupported: true
    )
    XCTAssertNil(value(of: "timeOffset", in: urlComp))
  }

  /// `.serverConfig` is a transcoding preference (the server picks the
  /// codec) — the offset is emitted like on `.mp3`
  func testServerConfigFormatStillEmitsOffset() {
    let urlComp = buildComponents(
      formatPreference: .serverConfig,
      timeOffset: 45,
      isTranscodeOffsetSupported: true
    )
    XCTAssertEqual(value(of: "timeOffset", in: urlComp), "45")
    // serverConfig keeps the format item omitted so the server decides
    XCTAssertNil(value(of: "format", in: urlComp))
  }

  func testZeroOffsetIsEmitted() {
    let urlComp = buildComponents(
      formatPreference: .mp3,
      timeOffset: 0,
      isTranscodeOffsetSupported: true
    )
    XCTAssertEqual(value(of: "timeOffset", in: urlComp), "0")
  }

  func testMaxBitrateEmittedUnlessNoLimit() {
    let limited = buildComponents(
      maxBitrate: .limit128,
      formatPreference: .mp3,
      timeOffset: nil,
      isTranscodeOffsetSupported: false
    )
    XCTAssertEqual(value(of: "maxBitRate", in: limited), "128")

    let unlimited = buildComponents(
      maxBitrate: .noLimit,
      formatPreference: .mp3,
      timeOffset: nil,
      isTranscodeOffsetSupported: false
    )
    XCTAssertNil(value(of: "maxBitRate", in: unlimited))
  }
}
