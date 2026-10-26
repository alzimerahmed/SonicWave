//
//  MimeFileConverterTest.swift
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

/// `iOSIncompatibleMimeTypes` (G2): Opus has no decoder in
/// AudioStreaming and must route to the transcode path, while Ogg
/// Vorbis and the common playable types keep the direct engine path.
class MimeFileConverterTest: XCTestCase {
  func testOpusMimeTypesAreNotPlayableOniOS() {
    let opusTypes = [
      "audio/opus",
      "application/opus",
      "audio/ogg;codecs=opus",
      // parameter whitespace varies between servers
      "audio/ogg; codecs=opus",
      "application/ogg;codecs=opus",
      "application/ogg; codecs=opus",
      "Audio/Opus",
      "audio/OGG; CODECS=OPUS",
    ]
    for mimeType in opusTypes {
      XCTAssertFalse(
        MimeFileConverter.isMimeTypePlayableOniOS(mimeType: mimeType),
        "\(mimeType) should be routed to the transcode path"
      )
    }
  }

  func testOggVorbisStaysPlayableOniOS() {
    XCTAssertTrue(MimeFileConverter.isMimeTypePlayableOniOS(mimeType: "audio/ogg"))
    XCTAssertTrue(MimeFileConverter.isMimeTypePlayableOniOS(mimeType: "application/ogg"))
    // Vorbis is the default codec of an unparameterized ogg type
    XCTAssertTrue(MimeFileConverter.isMimeTypePlayableOniOS(mimeType: "audio/ogg;codecs=vorbis"))
  }

  func testCommonTypesStayPlayableOniOS() {
    for mimeType in [
      "audio/mpeg",
      "audio/flac",
      "audio/x-flac",
      "audio/mp4",
      "audio/wav",
      "audio/aac",
    ] {
      XCTAssertTrue(
        MimeFileConverter.isMimeTypePlayableOniOS(mimeType: mimeType),
        "\(mimeType) should stay playable"
      )
    }
  }

  func testExistingBlocklistStillBlocked() {
    XCTAssertFalse(MimeFileConverter.isMimeTypePlayableOniOS(mimeType: "audio/x-ms-wma"))
    XCTAssertFalse(
      MimeFileConverter.isMimeTypePlayableOniOS(mimeType: "application/octet-stream")
    )
  }
}
