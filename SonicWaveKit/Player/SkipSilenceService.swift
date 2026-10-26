//
//  SkipSilenceService.swift
//  SonicWaveKit
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

import Combine
import Foundation
import os.log

// MARK: - SkipSilenceService

/// Skip-silence (G26): speeds through silent stretches of podcast
/// episodes by temporarily boosting the engine's playback rate.
///
/// The service observes `AudioAnalyzer.rms` — a linear RMS amplitude
/// published by the FFT tap that already feeds the visualizers and
/// `MusicHapticsService`. When the level stays below
/// `silenceRmsThreshold` (≈ -40 dBFS) for at least
/// `silenceMinDurationInSec`, the backend boosts the engine rate to
/// `min(userRate * 3, 4.0)`; the first non-silent buffer restores the
/// user's configured rate.
///
/// Design decisions:
/// - Podcast-mode only: quiet intros/interludes are part of music —
///   boosting them is wrong. The setting therefore defaults ON but the
///   service only engages while `playerMode == .podcast`.
/// - The boost goes through `PlayerFacade.setSkipSilenceBoost`, which
///   writes `player.rate` directly on the engine and never touches the
///   persisted per-mode `PlaybackRate` — a boost is session state, not
///   a user preference. The boost factor lives in the backend so a
///   restore always lands on the user's configured rate.
/// - The analyzer tap is refcounted per consumer
///   (`AudioAnalyzerConsumer.skipSilence`), so engaging never steals the
///   visualizer's activation and disengaging never cuts it.
///
/// The service is registered as a `MusicPlayable` notifier from
/// `AmperKit.createPlayer` and self-gates per player event — toggling
/// the setting takes effect within one elapsed-time tick (1s).
@MainActor
public final class SkipSilenceService: ObservableObject {
  /// true while the rate boost is applied — observable so a settings row
  /// can show live state
  @Published public private(set) var isBoosting = false

  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "SkipSilenceService"
  )
  private let player: PlayerFacade
  private let audioAnalyzer: AudioAnalyzer
  private let settings: AmperfySettings
  private var rmsCancellable: AnyCancellable?
  private var isEngaged = false
  /// uptime when the level first dipped below threshold — the boost only
  /// engages after a sustained silence so brief pauses in speech are kept
  private var silenceBeganUptime: TimeInterval?

  /// linear RMS below ≈ -40 dBFS counts as silence
  private static let silenceRmsThreshold: Float = 0.01
  /// boost only after a sustained silence — shorter gaps are speech rhythm
  private static let silenceMinDurationInSec: TimeInterval = 0.4

  init(
    player: PlayerFacade,
    audioAnalyzer: AudioAnalyzer,
    settings: AmperfySettings
  ) {
    self.player = player
    self.audioAnalyzer = audioAnalyzer
    self.settings = settings
  }

  private func reevaluateEngagement() {
    let shouldEngage = settings.user.isSkipSilenceEnabled &&
      player.playerMode == .podcast &&
      player.isPlaying
    if shouldEngage, !isEngaged {
      engage()
    } else if !shouldEngage, isEngaged {
      disengage()
    }
  }

  private func engage() {
    isEngaged = true
    silenceBeganUptime = nil
    audioAnalyzer.requestActivation(for: .skipSilence)
    rmsCancellable = audioAnalyzer.$rms.sink { [weak self] rms in
      Task { @MainActor in
        self?.processRms(rms)
      }
    }
  }

  private func disengage() {
    rmsCancellable?.cancel()
    rmsCancellable = nil
    audioAnalyzer.releaseActivation(for: .skipSilence)
    isEngaged = false
    silenceBeganUptime = nil
    restoreRateIfNeeded()
  }

  private func processRms(_ rms: Float) {
    guard isEngaged else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if rms < Self.silenceRmsThreshold {
      if silenceBeganUptime == nil {
        silenceBeganUptime = now
      } else if !isBoosting,
                now - silenceBeganUptime! >= Self.silenceMinDurationInSec {
        os_log(
          "skip-silence boost engaged (base rate %.2fx)",
          log: self.log,
          type: .debug,
          player.playbackRate.asDouble
        )
        player.setSkipSilenceBoost(isActive: true)
        isBoosting = true
      }
    } else {
      silenceBeganUptime = nil
      restoreRateIfNeeded()
    }
  }

  private func restoreRateIfNeeded() {
    guard isBoosting else { return }
    player.setSkipSilenceBoost(isActive: false)
    isBoosting = false
  }
}

// MARK: MusicPlayable

extension SkipSilenceService: MusicPlayable {
  public func didStartPlayingFromBeginning() {
    // a track change must drop any leftover boost immediately
    restoreRateIfNeeded()
    reevaluateEngagement()
  }

  public func didStartPlaying() {
    reevaluateEngagement()
  }

  public func didPause() {
    restoreRateIfNeeded()
    reevaluateEngagement()
  }

  public func didStopPlaying() {
    disengage()
  }

  /// 1s tick — catches `isSkipSilenceEnabled` toggles and player-mode
  /// switches without any dedicated settings observation
  public func didElapsedTimeChange() {
    reevaluateEngagement()
  }

  public func didPlaylistChange() {}
  public func didArtworkChange() {}
}
