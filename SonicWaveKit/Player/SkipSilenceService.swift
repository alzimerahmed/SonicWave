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

// MARK: - SkipSilenceDecider

/// Pure decision core of `SkipSilenceService` — extracted so the
/// silence→boost state machine is unit-testable without a running
/// engine or a live `AudioAnalyzer` feed (G26).
struct SkipSilenceDecider {
  /// linear RMS below ≈ -40 dBFS counts as silence
  static let rmsThreshold: Float = 0.01
  /// boost only after a sustained silence — shorter gaps are speech rhythm
  static let minSilenceDurationInSec: TimeInterval = 0.4

  /// the engagement gate: podcast mode only — quiet intros/interludes
  /// are part of music and must never be boosted through
  static func isEngagementAllowed(
    isEnabled: Bool,
    playerMode: PlayerMode,
    isPlaying: Bool
  ) -> Bool {
    isEnabled && playerMode == .podcast && isPlaying
  }

  /// uptime when the level first dipped below threshold — the boost
  /// only engages after a sustained silence
  private(set) var silenceBeganUptime: TimeInterval?
  /// true once a sustained silence latched the boost on — stays
  /// latched until the first non-silent buffer or a `reset`
  private(set) var isBoosting = false

  /// feed one RMS sample taken at `uptime`; returns the boost state —
  /// a change versus the previous call means the engine rate must be
  /// rewritten
  @discardableResult
  mutating func process(rms: Float, at uptime: TimeInterval) -> Bool {
    if rms < Self.rmsThreshold {
      if silenceBeganUptime == nil {
        silenceBeganUptime = uptime
      } else if !isBoosting,
                uptime - silenceBeganUptime! >= Self.minSilenceDurationInSec {
        isBoosting = true
      }
    } else {
      silenceBeganUptime = nil
      isBoosting = false
    }
    return isBoosting
  }

  /// track change / disengage — drop the boost latch and the silence clock
  mutating func reset() {
    silenceBeganUptime = nil
    isBoosting = false
  }
}

// MARK: - SkipSilenceService

/// Skip-silence (G26): speeds through silent stretches of podcast
/// episodes by temporarily boosting the engine's playback rate.
///
/// The service observes `AudioAnalyzer.rms` — a linear RMS amplitude
/// published by the FFT tap that already feeds the visualizers and
/// `MusicHapticsService`. `SkipSilenceDecider` owns the state machine:
/// when the level stays below `rmsThreshold` (≈ -40 dBFS) for at least
/// `minSilenceDurationInSec`, the backend boosts the engine rate to
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
/// the setting takes effect via `UserDefaults.didChangeNotification`
/// and the next player event, not by decoding settings on the 1s tick.
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
  /// cached copy of `settings.user.isSkipSilenceEnabled` — `user` is a
  /// full UserDefaults read + JSON decode per access, far too heavy for
  /// the 1s `didElapsedTimeChange` tick; refreshed on player events and
  /// on `UserDefaults.didChangeNotification`
  private var isSkipSilenceEnabled: Bool
  /// `nonisolated(unsafe)` so `deinit` can unregister — the observer
  /// token itself is written once in `init` and `removeObserver` is
  /// thread-safe
  nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?
  /// the silence→boost state machine — `isBoosting` mirrors its latch
  private var decider = SkipSilenceDecider()

  init(
    player: PlayerFacade,
    audioAnalyzer: AudioAnalyzer,
    settings: AmperfySettings
  ) {
    self.player = player
    self.audioAnalyzer = audioAnalyzer
    self.settings = settings
    self.isSkipSilenceEnabled = settings.user.isSkipSilenceEnabled
    // any UserDefaults write (the toggle lives in `settings.user`)
    // refreshes the cached flag — paying the decode on the change
    // itself keeps the per-second tick free of JSON work while a
    // mid-episode toggle still lands promptly
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshSkipSilenceEnabled()
      }
    }
  }

  deinit {
    if let defaultsObserver {
      NotificationCenter.default.removeObserver(defaultsObserver)
    }
  }

  /// re-reads the persisted toggle into `isSkipSilenceEnabled`, then
  /// re-evaluates — the only places allowed to decode `settings.user`
  private func refreshSkipSilenceEnabled() {
    isSkipSilenceEnabled = settings.user.isSkipSilenceEnabled
    reevaluateEngagement()
  }

  private func reevaluateEngagement() {
    let shouldEngage = SkipSilenceDecider.isEngagementAllowed(
      isEnabled: isSkipSilenceEnabled,
      playerMode: player.playerMode,
      isPlaying: player.isPlaying
    )
    if shouldEngage, !isEngaged {
      engage()
    } else if !shouldEngage, isEngaged {
      disengage()
    }
  }

  private func engage() {
    isEngaged = true
    decider.reset()
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
    restoreRateIfNeeded()
    decider.reset()
  }

  private func processRms(_ rms: Float) {
    guard isEngaged else { return }
    let shouldBoost = decider.process(
      rms: rms,
      at: ProcessInfo.processInfo.systemUptime
    )
    guard shouldBoost != isBoosting else { return }
    if shouldBoost {
      os_log(
        "skip-silence boost engaged (base rate %.2fx)",
        log: self.log,
        type: .debug,
        player.playbackRate.asDouble
      )
    }
    player.setSkipSilenceBoost(isActive: shouldBoost)
    isBoosting = shouldBoost
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
    refreshSkipSilenceEnabled()
  }

  public func didStartPlaying() {
    refreshSkipSilenceEnabled()
  }

  public func didPause() {
    restoreRateIfNeeded()
    refreshSkipSilenceEnabled()
  }

  public func didStopPlaying() {
    disengage()
  }

  /// 1s tick — re-evaluates the cached flag only; the cache itself is
  /// refreshed by player events and `UserDefaults.didChangeNotification`
  /// so this path never pays the settings JSON decode
  public func didElapsedTimeChange() {
    reevaluateEngagement()
  }

  public func didPlaylistChange() {}
  public func didArtworkChange() {}
}
