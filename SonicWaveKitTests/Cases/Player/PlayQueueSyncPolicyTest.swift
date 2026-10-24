//
//  PlayQueueSyncPolicyTest.swift
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

/// G9 queue push/pull decision logic (dirty-wins, remote-newer)
class PlayQueueSyncPolicyTest: XCTestCase {
  private let past = Date(timeIntervalSince1970: 1_700_000_000)
  private let now = Date(timeIntervalSince1970: 1_700_100_000)

  func testDirtyQueueAlwaysPushes() {
    XCTAssertEqual(
      PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: true,
        remoteChangeDate: now,
        lastSeenRemoteChangeDate: past
      ),
      .push
    )
    XCTAssertEqual(
      PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: true,
        remoteChangeDate: nil,
        lastSeenRemoteChangeDate: nil
      ),
      .push
    )
  }

  func testCleanQueueWithoutRemoteIsNoop() {
    XCTAssertEqual(
      PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: false,
        remoteChangeDate: nil,
        lastSeenRemoteChangeDate: past
      ),
      .none
    )
  }

  func testCleanQueueWithNewerRemotePulls() {
    XCTAssertEqual(
      PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: false,
        remoteChangeDate: now,
        lastSeenRemoteChangeDate: past
      ),
      .pull
    )
    // never seen a remote queue before -> first remote wins
    XCTAssertEqual(
      PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: false,
        remoteChangeDate: now,
        lastSeenRemoteChangeDate: nil
      ),
      .pull
    )
  }

  func testCleanQueueWithSeenRemoteIsNoop() {
    XCTAssertEqual(
      PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: false,
        remoteChangeDate: past,
        lastSeenRemoteChangeDate: past
      ),
      .none
    )
    XCTAssertEqual(
      PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: false,
        remoteChangeDate: past,
        lastSeenRemoteChangeDate: now
      ),
      .none
    )
  }
}
