//
//  SkipSilenceServiceTest.swift
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

// MARK: - SkipSilenceServiceTest

/// G26 skip-silence: the `SkipSilenceDecider` state machine — sustained
/// sub-threshold RMS latches the boost, the first non-silent buffer or
/// a reset drops it, and the engagement gate confines it to playing
/// podcasts.
class SkipSilenceServiceTest: XCTestCase {

  // MARK: Boost latch

  func testSustainedSilenceEngagesBoost() {
    var decider = SkipSilenceDecider()
    // the first dip only starts the silence clock — no boost yet
    XCTAssertFalse(decider.process(rms: 0.005, at: 0))
    // still inside the minimum-duration window — no boost
    XCTAssertFalse(decider.process(rms: 0.005, at: 0.3))
    // past the sustained-silence gate — boost latches on
    XCTAssertTrue(decider.process(rms: 0.005, at: 0.41))
    XCTAssertTrue(decider.isBoosting)
  }

  func testBriefSilenceNeverEngagesBoost() {
    var decider = SkipSilenceDecider()
    XCTAssertFalse(decider.process(rms: 0.005, at: 0))
    XCTAssertFalse(decider.process(rms: 0.005, at: 0.2))
    // speech resumes inside the window — the silence clock must restart
    XCTAssertFalse(decider.process(rms: 0.5, at: 0.3))
    XCTAssertNil(decider.silenceBeganUptime)
    XCTAssertFalse(decider.process(rms: 0.005, at: 0.5))
    // the minimum duration is measured from the new dip at 0.5, not 0
    XCTAssertFalse(decider.process(rms: 0.005, at: 0.8))
    XCTAssertTrue(decider.process(rms: 0.005, at: 0.91))
  }

  func testBoostStaysLatchedThroughSustainedSilence() {
    var decider = SkipSilenceDecider()
    decider.process(rms: 0.005, at: 0)
    XCTAssertTrue(decider.process(rms: 0.005, at: 1.0))
    // a latched boost must not re-fire or drop on further silent buffers
    XCTAssertTrue(decider.process(rms: 0.005, at: 5.0))
    XCTAssertTrue(decider.isBoosting)
  }

  // MARK: Restore

  func testNonSilentBufferRestoresRate() {
    var decider = SkipSilenceDecider()
    decider.process(rms: 0.005, at: 0)
    decider.process(rms: 0.005, at: 1.0)
    XCTAssertTrue(decider.isBoosting)
    XCTAssertFalse(decider.process(rms: 0.5, at: 1.1))
    XCTAssertFalse(decider.isBoosting)
  }

  func testResetRestoresRateAndClearsSilenceClock() {
    var decider = SkipSilenceDecider()
    decider.process(rms: 0.005, at: 0)
    decider.process(rms: 0.005, at: 1.0)
    XCTAssertTrue(decider.isBoosting)
    // disengage / track change — the boost and the clock must drop
    // together so the next engagement starts from a clean state
    decider.reset()
    XCTAssertFalse(decider.isBoosting)
    XCTAssertNil(decider.silenceBeganUptime)
  }

  // MARK: Engagement gate

  func testMusicModeNeverEngages() {
    // quiet intros and interludes are part of music — boosting through
    // them is wrong even with the setting on and playback running
    XCTAssertFalse(
      SkipSilenceDecider.isEngagementAllowed(
        isEnabled: true,
        playerMode: .music,
        isPlaying: true
      )
    )
  }

  func testPodcastModeEngagesWhenEnabledAndPlaying() {
    XCTAssertTrue(
      SkipSilenceDecider.isEngagementAllowed(
        isEnabled: true,
        playerMode: .podcast,
        isPlaying: true
      )
    )
  }

  func testGateRequiresSettingEnabled() {
    XCTAssertFalse(
      SkipSilenceDecider.isEngagementAllowed(
        isEnabled: false,
        playerMode: .podcast,
        isPlaying: true
      )
    )
  }

  func testGateRequiresActivePlayback() {
    XCTAssertFalse(
      SkipSilenceDecider.isEngagementAllowed(
        isEnabled: true,
        playerMode: .podcast,
        isPlaying: false
      )
    )
  }

  // MARK: Threshold edges

  func testRmsAtThresholdCountsAsNonSilent() {
    var decider = SkipSilenceDecider()
    // the comparison is strictly-below — a buffer at the threshold
    // itself must never start the silence clock
    decider.process(rms: SkipSilenceDecider.rmsThreshold, at: 0)
    XCTAssertNil(decider.silenceBeganUptime)
    XCTAssertFalse(
      decider.process(rms: SkipSilenceDecider.rmsThreshold, at: 1.0)
    )
    XCTAssertFalse(decider.isBoosting)
  }
}
