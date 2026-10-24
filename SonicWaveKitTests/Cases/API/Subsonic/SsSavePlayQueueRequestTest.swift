//
//  SsSavePlayQueueRequestTest.swift
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

/// `savePlayQueue` request building (G9): `id` is repeated once per song
/// (order preserved), `current` carries the playing song id, `position`
/// the playback position in milliseconds.
class SsSavePlayQueueRequestTest: XCTestCase {
  private func buildComponents(
    songIds: [String],
    currentSongId: String?,
    position: Int
  )
    -> URLComponents {
    var urlComp = URLComponents(string: "https://test.local/rest/savePlayQueue.view")!
    SubsonicServerApi.appendPlayQueueQueryItems(
      to: &urlComp,
      songIds: songIds,
      currentSongId: currentSongId,
      positionInMilliseconds: position
    )
    return urlComp
  }

  func testSongIdsAreRepeatedInOrder() {
    let urlComp = buildComponents(
      songIds: ["a", "b", "c"],
      currentSongId: "b",
      position: 42_000
    )
    let idItems = urlComp.queryItems?.filter { $0.name == "id" } ?? []
    XCTAssertEqual(idItems.count, 3)
    XCTAssertEqual(idItems[0].value, "a")
    XCTAssertEqual(idItems[1].value, "b")
    XCTAssertEqual(idItems[2].value, "c")
    XCTAssertEqual(
      urlComp.queryItems?.first(where: { $0.name == "current" })?.value,
      "b"
    )
    XCTAssertEqual(
      urlComp.queryItems?.first(where: { $0.name == "position" })?.value,
      "42000"
    )
  }

  func testCurrentIsOmittedWhenNil() {
    let urlComp = buildComponents(songIds: ["x"], currentSongId: nil, position: 0)
    XCTAssertNil(urlComp.queryItems?.first(where: { $0.name == "current" }))
    XCTAssertEqual(
      urlComp.queryItems?.first(where: { $0.name == "position" })?.value,
      "0"
    )
  }

  func testEmptyQueueBuildsValidRequest() {
    let urlComp = buildComponents(songIds: [], currentSongId: nil, position: 0)
    XCTAssertEqual(urlComp.queryItems?.filter { $0.name == "id" }.count, 0)
    XCTAssertNotNil(urlComp.url)
  }
}
