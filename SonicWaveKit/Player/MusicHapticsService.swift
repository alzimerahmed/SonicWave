//
//  MusicHapticsService.swift
//  SonicWaveKit
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

import Combine
import Foundation
import os.log
#if canImport(CoreHaptics)
  import CoreHaptics
#endif

// MARK: - MusicHapticsService

/// Beat-synced haptic feedback synthesized with Core Haptics.
///
/// This is intentionally NOT Apple Music's "Music Haptics" — that
/// accessibility feature needs proprietary beat metadata that only
/// exists for Apple Music catalog tracks; self-hosted servers do not
/// ship a beat grid. Instead the service derives the beat live from the
/// low-frequency band of the `AudioAnalyzer` FFT tap that already feeds
/// the visualizers: a bass-band energy onset above its running baseline
/// fires one soft `hapticTransient` event.
///
/// Gating (all required):
/// - `UserSettings.isMusicHapticsActive` (default off — the analyzer
///   tap costs CPU; opt-in feel feature)
/// - `MusicHapticsService.isSupported` — false on Mac Catalyst and any
///   device without a haptic engine (`CHHapticEngine` capability check)
/// - music player mode + actually playing
///
/// The service is registered as a `MusicPlayable` notifier from
/// `AmperKit.createPlayer` and self-gates per player event — toggling
/// the setting takes effect within one elapsed-time tick (1s).
@MainActor
public final class MusicHapticsService: ObservableObject {
  /// hardware gate — false on Mac Catalyst and devices without haptics
  public static var isSupported: Bool {
    #if canImport(CoreHaptics)
      return CHHapticEngine.capabilitiesForHardware().supportsHaptics
    #else
      return false
    #endif
  }

  /// true while the engine is running and beat events may fire —
  /// observable so a settings row can show live state
  @Published public private(set) var isEngaged = false

  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "MusicHapticsService"
  )
  private let player: PlayerFacade
  private let audioAnalyzer: AudioAnalyzer
  private let settings: AmperfySettings
  private var magnitudesCancellable: AnyCancellable?
  /// backoff after a failed engine create/start — a persistent failure
  /// must not retry (and re-log) on every 1s tick
  private static let engineRetryBackoffInSec: TimeInterval = 30
  private var nextEngineRetryUptime: TimeInterval = 0

  // bass-onset detector state
  /// slow exponential baseline of the bass band — onsets are short
  /// spikes above it, so the detector adapts to each track's loudness
  private var bassBaseline: Float = 0
  private var lastOnsetUptime: TimeInterval = 0
  /// refractory between two haptic events — keeps feedback a subtle
  /// pulse instead of a buzz on busy bass lines
  private static let onsetRefractoryInSec: TimeInterval = 0.3
  /// bass band ceiling — kick/bass transients live below ~160 Hz
  private static let bassBandMaxHertz: Float = 160
  /// onset must exceed baseline × factor (energy, not absolute level)
  private static let onsetRatio: Float = 1.8

  #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
  #endif

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
    let shouldEngage = Self.isSupported &&
      settings.user.isMusicHapticsActive &&
      player.playerMode == .music &&
      player.isPlaying
    if shouldEngage, !isEngaged {
      engage()
    } else if !shouldEngage, isEngaged {
      disengage()
    }
  }

  private func engage() {
    guard Self.isSupported else { return }
    #if canImport(CoreHaptics)
      let now = ProcessInfo.processInfo.systemUptime
      guard now >= nextEngineRetryUptime else { return }
      if engine == nil, !createEngine() {
        nextEngineRetryUptime = now + Self.engineRetryBackoffInSec
        return
      }
      do {
        try engine?.start()
      } catch {
        nextEngineRetryUptime = now + Self.engineRetryBackoffInSec
        engine = nil
        os_log(
          "Haptic engine start failed: %{public}@",
          log: self.log,
          type: .info,
          error.localizedDescription
        )
        return
      }
      nextEngineRetryUptime = 0
    #endif
    isEngaged = true
    bassBaseline = 0
    lastOnsetUptime = 0
    // the tap is refcounted per consumer — engaging never steals the
    // visualizer's activation and disengaging never cuts it
    audioAnalyzer.requestActivation(for: .haptics)
    magnitudesCancellable = audioAnalyzer.$magnitudes.sink { [weak self] magnitudes in
      Task { @MainActor in
        self?.processMagnitudes(magnitudes)
      }
    }
  }

  private func disengage() {
    magnitudesCancellable?.cancel()
    magnitudesCancellable = nil
    audioAnalyzer.releaseActivation(for: .haptics)
    isEngaged = false
    #if canImport(CoreHaptics)
      try? engine?.stop()
      engine = nil
    #endif
  }

  private func processMagnitudes(_ magnitudes: [Magnitude]) {
    guard isEngaged else { return }
    let bassEnergy = magnitudes
      .prefix(while: { $0.hertz <= Self.bassBandMaxHertz })
      .reduce(Float(0)) { $0 + $1.value }
    if bassBaseline == 0 {
      bassBaseline = bassEnergy
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let isOnset = bassEnergy > bassBaseline * Self.onsetRatio &&
      now - lastOnsetUptime > Self.onsetRefractoryInSec
    // slow follower — adapts to the track's own loudness so the ratio
    // threshold works across quiet and loud masters alike
    bassBaseline = bassBaseline * 0.94 + bassEnergy * 0.06
    guard isOnset else { return }
    lastOnsetUptime = now
    let onsetStrength = bassEnergy / max(bassBaseline, 0.001)
    // subtle: clamp well below full intensity — beat feel, not buzzing
    let intensity = min(max(onsetStrength * 0.3, 0.3), 0.8)
    fireTransient(intensity: intensity)
  }

  #if canImport(CoreHaptics)
    private func createEngine() -> Bool {
      do {
        let newEngine = try CHHapticEngine()
        newEngine.resetHandler = { [weak self] in
          Task { @MainActor in
            try? self?.engine?.start()
          }
        }
        newEngine.stoppedHandler = { [weak self] _ in
          Task { @MainActor in
            self?.engine = nil
          }
        }
        engine = newEngine
        return true
      } catch {
        return false
      }
    }

    private func fireTransient(intensity: Float) {
      if engine == nil, !createEngine() { return }
      guard let engine else { return }
      do {
        let event = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
          ],
          relativeTime: 0
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let patternPlayer = try engine.makePlayer(with: pattern)
        try patternPlayer.start(atTime: CHHapticTimeImmediate)
      } catch {
        // a dead engine is dropped and lazily recreated on the next onset
        self.engine = nil
      }
    }
  #else
    private func fireTransient(intensity: Float) {}
  #endif
}

// MARK: MusicPlayable

extension MusicHapticsService: MusicPlayable {
  public func didStartPlayingFromBeginning() {
    reevaluateEngagement()
  }

  public func didStartPlaying() {
    reevaluateEngagement()
  }

  public func didPause() {
    reevaluateEngagement()
  }

  public func didStopPlaying() {
    disengage()
  }

  /// 1s tick — catches `isMusicHapticsActive` setting toggles and
  /// player-mode switches without any dedicated settings observation
  public func didElapsedTimeChange() {
    reevaluateEngagement()
  }

  public func didPlaylistChange() {}
  public func didArtworkChange() {}
  public func didShuffleChange() {}
  public func didRepeatChange() {}
  public func didPlaybackRateChange() {}
}
