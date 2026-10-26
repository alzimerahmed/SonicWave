//
//  BackendAudioPlayer.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

import AudioStreaming
import AVFoundation
import Foundation
import os.log
import UIKit

// MARK: - BackendAudioPlayerNotifiable

@MainActor
protocol BackendAudioPlayerNotifiable {
  func didElapsedTimeChange()
  func didLyricsTimeChange(time: CMTime) // high refresh count
  func stop()
  func playPrevious()
  func playNext()
  func didItemFinishedPlaying()
  func notifyItemPreparationFinished()
  func notifyErrorOccurred(error: Error)
  func didReadStreamMetadata(_ metadata: [String: String])
}

// MARK: - AudioStreamingPlayer

public class AudioStreamingPlayer: AudioStreaming.AudioPlayer {
  public func elapsedTime() -> Double {
    progress
  }

  public func getState() -> AudioStreaming.AudioPlayerState {
    state
  }
}

// MARK: - PlayType

public enum PlayType {
  case stream
  case cache
}

public typealias CreateAudioStreamingPlayerCallback = () -> AudioStreamingPlayer
public typealias TriggerReinsertPlayableCallback = @MainActor () -> ()
typealias NextPlayablePreloadCallback = () -> AbstractPlayable?

// MARK: - BackendAudioQueueType

enum BackendAudioQueueType {
  case play
  case queue
  /// G3 crossfade — plays on the spare engine immediately at zero volume;
  /// shares the `.queue` bookkeeping lane (perloaded*/nextPreloaded*) so
  /// the existing preloaded-match branch adopts it
  case crossfade
}

// MARK: - BackendAudioPlayer

@MainActor
class BackendAudioPlayer: NSObject {
  private let getPlayableDownloaderCB: GetPlayableDownloadManagerCallback
  private let cacheProxy: PlayableFileCachable
  private let getBackendApiCB: GetBackendApiCallback
  private let userStatistics: UserStatistics
  private let createAudioStreamingPlayerCB: CreateAudioStreamingPlayerCallback
  private let eventLogger: EventLogger
  private let networkMonitor: NetworkMonitorFacade
  private let updateElapsedTimeInterval = CMTime(
    seconds: 1.0,
    preferredTimescale: CMTimeScale(NSEC_PER_SEC)
  )
  private let updateLyricsTimeInterval = CMTime(
    seconds: 0.1,
    preferredTimescale: CMTimeScale(NSEC_PER_SEC)
  )
  private let fileManager = CacheFileManager.shared
  private var audioSessionHandler: AudioSessionHandler
  private var isTriggerReinsertPlayableAllowed = true
  private var wasPlayingBeforeErrorOccurred: Bool = false
  private var userDefinedPlaybackRate: PlaybackRate = .one
  private var currentPreparedUrl: String = ""
  private var currentPlayUrl: String = ""
  private var nextPreloadedPlayable: AbstractPlayable?
  private var nextPreloadedUrl: String = ""
  /// a stream preload was resolved but its async `insertStreamPlayable`
  /// (generateUrl may re-authenticate) has not queued the entry yet —
  /// `nextPreloadedPlayable` is only assigned once the insert completes so
  /// an early `playNext` takes the normal branch instead of adopting a
  /// not-yet-queued entry
  private var isPreloadInsertPending = false
  /// set by every queue mutation that can change which playable is next —
  /// a queued preload goes stale the moment the queue it was resolved
  /// from is mutated, so adoption must be refused
  private var isPreloadedNextStale = false
  private var isPreviousPlaylableFinshed = true
  private var isAutoStartPlayback = true
  private var seekTimeWhenStarted: Double?
  private var timerElapsedTimeInterval: Timer?
  private var timerLyricsTimeInterval: Timer?
  private var volumePlayer: Float = 1.0

  private var player: AudioStreamingPlayer?
  private var equalizer: AVAudioUnitEQ?
  private var replayGainNode: AVAudioMixerNode?
  public private(set) var audioAnalyzer: AudioAnalyzer
  /// node the analyzer tap is currently installed on — tracks which
  /// engine's EQ owns the tap so it can follow the crossfade winner
  private var analyzerTapNode: AVAudioNode?

  // MARK: Crossfade (G3) — a second AudioStreaming engine so entries
  // overlap; `player`/`equalizer`/`replayGainNode` always describe the
  // ACTIVE engine, `spare*` the other one. The roles swap on adoption:
  // before the adopt `spare` is the incoming track, afterwards it is the
  // draining tail. `fadeOutPlayerRef`/`fadeInPlayerRef` pin concrete
  // engine instances for the whole fade so the swap cannot confuse the
  // volume ramp.
  private var sparePlayer: AudioStreamingPlayer?
  private var spareEqualizer: AVAudioUnitEQ?
  private var spareReplayGainNode: AVAudioMixerNode?
  /// ReplayGain of the playable loaded on the spare engine (the active
  /// engine's gain lives in `currentReplayGainValue`)
  private var spareReplayGainValue: Float = 0.0
  /// crossfade length in seconds; 0 disables crossfading entirely and the
  /// engine falls back to the classic gapless queue preload
  var crossfadeDurationInSec: Double = 0.0 {
    didSet { if crossfadeDurationInSec <= 0 { abortCrossfade() } }
  }
  /// next-track stream insert for a crossfade is in flight (async)
  private var isCrossfadePreparing = false
  /// a fade is running: outgoing ramps to 0, incoming to `volumePlayer`
  private var isCrossfading = false
  private var fadeOutPlayerRef: AudioStreamingPlayer?
  private var fadeInPlayerRef: AudioStreamingPlayer?
  private var fadeOutFactor: Float = 1.0
  private var fadeInFactor: Float = 1.0
  private var crossfadeTimer: Timer?
  private var crossfadeStartUptime: TimeInterval = 0
  private var crossfadeActiveDurationInSec: Double = 0
  /// ~30 Hz is enough to keep the equal-power ramps zipper-free
  private static let crossfadeUpdateIntervalInSec: TimeInterval = 1.0 / 30.0

  /// true while a crossfade is being prepared or is fading — used by
  /// `PlayerFacade.isCrossfadeActive`
  var isCrossfadeActive: Bool {
    isCrossfadePreparing || isCrossfading
  }

  // ReplayGain Settings
  private var isReplayGainEnabled: Bool = true
  private var currentReplayGainValue: Float = 0.0 // ReplayGain in dB
  // EQ Settings
  private var equalizerVolumeCompensation: Float = 1.0
  private var isEqualizerEnabled: Bool = true
  private var currentEqualizerSetting: EqualizerSetting = .off

  public var isOfflineMode: Bool = false
  public var isAutoCachePlayedItems: Bool = true
  public var nextPlayablePreloadCB: NextPlayablePreloadCallback?
  public var triggerReinsertPlayableCB: TriggerReinsertPlayableCallback?
  public private(set) var isPlaying: Bool = false
  public private(set) var isErrorOccurred: Bool = false
  public private(set) var playType: PlayType?
  private var perloadedPlayType: PlayType?
  public private(set) var activeStreamingBitrate: StreamingMaxBitratePreference?
  private var perloadedStreamingBitrate: StreamingMaxBitratePreference?
  public private(set) var activeTranscodingFormat: StreamingFormatPreference?
  private var preloadTranscodingFormat: StreamingFormatPreference?
  public private(set) var streamingMaxBitrates = StreamingMaxBitrates()
  public func setStreamingMaxBitrates(to: StreamingMaxBitrates) {
    let oldBitrate = streamingMaxBitrates.getActive(networkMonitor: networkMonitor)
    let newBitrate = to.getActive(networkMonitor: networkMonitor)

    os_log(
      .default,
      "Update Streaming Max Bitrate: %s -> %s (for next stream)",
      oldBitrate.description,
      newBitrate.description
    )
    // Update the stored bitrates
    streamingMaxBitrates = to
  }

  public private(set) var streamingTranscodings = StreamingTranscodings()
  public func setStreamingTranscodings(to: StreamingTranscodings) {
    os_log(
      .default,
      "Update Streaming Transcoding: <Wifi: %s, Cellular: %s> -> <Wifi: %s, Cellular: %s> (for next stream)",
      streamingTranscodings.wifi.description,
      streamingTranscodings.cellular.description,
      to.wifi.description,
      to.cellular.description
    )
    // Update the stored bitrates
    streamingTranscodings = to
  }

  var responder: BackendAudioPlayerNotifiable?
  var volume: Float {
    get {
      volumePlayer
    }
    set {
      volumePlayer = newValue
      applyVolumes()
    }
  }

  /// user volume × fade factors; mid-fade the fixed fade refs carry the
  /// ramps so a volume change during a crossfade scales both engines
  private func applyVolumes() {
    if let fadeOutPlayerRef, let fadeInPlayerRef {
      fadeOutPlayerRef.volume = volumePlayer * fadeOutFactor
      fadeInPlayerRef.volume = volumePlayer * fadeInFactor
    } else {
      player?.volume = volumePlayer
    }
  }

  var isStopped: Bool {
    playType == nil
  }

  var elapsedTime: Double {
    player?.elapsedTime() ?? 0.0
  }

  var duration: Double {
    player?.duration ?? 0.0
  }

  var playbackRate: PlaybackRate {
    userDefinedPlaybackRate
  }

  var canBeContinued: Bool {
    currentPlayUrl != "" &&
      (
        player?.getState() == .paused || player?.getState() == .playing || player?
          .getState() == .bufferring
      )
  }

  init(
    createAudioStreamingPlayerCB: @escaping CreateAudioStreamingPlayerCallback,
    audioSessionHandler: AudioSessionHandler,
    eventLogger: EventLogger,
    getBackendApiCB: @escaping GetBackendApiCallback,
    networkMonitor: NetworkMonitorFacade,
    getPlayableDownloaderCB: @escaping GetPlayableDownloadManagerCallback,
    cacheProxy: PlayableFileCachable,
    userStatistics: UserStatistics
  ) {
    self.createAudioStreamingPlayerCB = createAudioStreamingPlayerCB
    self.audioSessionHandler = audioSessionHandler
    self.getBackendApiCB = getBackendApiCB
    self.networkMonitor = networkMonitor
    self.eventLogger = eventLogger
    self.getPlayableDownloaderCB = getPlayableDownloaderCB
    self.cacheProxy = cacheProxy
    self.userStatistics = userStatistics
    self.audioAnalyzer = AudioAnalyzer()

    super.init()

    initAudioStreamingPlayerAndNodes()
  }

  private func startTimers() {
    stopTimers()
    timerElapsedTimeInterval = Timer.scheduledTimer(
      withTimeInterval: updateElapsedTimeInterval.seconds,
      repeats: true
    ) { [weak self] timer in
      Task { @MainActor in
        guard let self = self else { return }
        self.checkForPreloadNextPlayerItem()
        self.responder?.didElapsedTimeChange()
      }
    }
    timerLyricsTimeInterval = Timer.scheduledTimer(
      withTimeInterval: updateLyricsTimeInterval.seconds,
      repeats: true
    ) { [weak self] timer in
      Task { @MainActor in
        guard let self = self else { return }
        let cmTime = CMTime(value: Int64(self.elapsedTime * 1_000), timescale: 1_000)
        self.responder?.didLyricsTimeChange(time: cmTime)
      }
    }
  }

  private func stopTimers() {
    timerElapsedTimeInterval?.invalidate()
    timerLyricsTimeInterval?.invalidate()
  }

  private func checkForPreloadNextPlayerItem() {
    guard isAutoStartPlayback else { return }
    guard nextPreloadedPlayable == nil, !isPreloadInsertPending, !isCrossfadeActive,
          elapsedTime.isFinite, elapsedTime > 0, duration.isFinite, duration > 0
    else { return }
    let remainingTime = duration - elapsedTime
    guard remainingTime > 0 else { return }
    if crossfadeDurationInSec > 0 {
      // G3 — crossfade supersedes the gapless queue preload: the incoming
      // track renders on the spare engine so both overlap
      if remainingTime <= crossfadeDurationInSec {
        beginCrossfade()
      }
      return
    }
    if remainingTime < 10 {
      guard let nextPlayable = nextPlayablePreloadCB?() else { return }
      isPreloadedNextStale = false
      os_log(.default, "Preloading: %s", nextPlayable.displayString)
      if nextPlayable.isCached,
         cacheProxy.getFileURL(forPlayable: nextPlayable) != nil {
        insertCachedPlayable(playable: nextPlayable, queueType: .queue)
        nextPreloadedPlayable = nextPlayable
      } else if !isOfflineMode, !nextPlayable.isCached {
        isPreloadInsertPending = true
        Task { @MainActor in
          do {
            try await insertStreamPlayable(playable: nextPlayable, queueType: .queue)
            self.isPreloadInsertPending = false
            if self.isPreloadedNextStale {
              // the queue mutated during the async insert — the just-
              // queued entry is already stale; drop it from the engine
              // queue instead of adopting it at the boundary
              self.invalidatePreloadedNext()
            } else {
              self.nextPreloadedPlayable = nextPlayable
            }
            if self.isAutoCachePlayedItems, nextPlayable.isDownloadAvailable,
               let accountInfo = nextPlayable.account?.info {
              self.getPlayableDownloaderCB(accountInfo)
                .download(object: nextPlayable, asTier: .cache)
            }
          } catch {
            self.isPreloadInsertPending = false
            self.eventLogger.report(topic: "Player", error: error)
          }
        }
      }
    }
  }

  // MARK: - Crossfade Implementation

  /// Resolves the next playable and starts it on the spare engine at
  /// zero volume. Stream inserts are async, so the fade itself only
  /// begins once the incoming entry is actually queued-and-playing on
  /// the spare engine (`startCrossfadeFade`).
  private func beginCrossfade() {
    guard !isCrossfadeActive, let nextPlayable = nextPlayablePreloadCB?(),
          // radios have no duration to blend over and their insert path
          // does not carry bitrate/transcoding bookkeeping — skip them
          !nextPlayable.isRadio
    else { return }
    let isCachedInsert = nextPlayable.isCached &&
      cacheProxy.getFileURL(forPlayable: nextPlayable) != nil
    // an uncached next track cannot be fetched in offline mode — bail
    // before touching any state so the boundary falls back to the
    // regular (non-gapless) play path
    guard isCachedInsert || !isOfflineMode else { return }
    isPreloadedNextStale = false
    os_log(.default, "Crossfade preparing: %s", nextPlayable.displayString)
    ensureSparePlayer()
    spareReplayGainValue = nextPlayable.replayGainTrackGain
    applyReplayGain()
    sparePlayer?.volume = 0
    if isCachedInsert {
      insertCachedPlayable(playable: nextPlayable, queueType: .crossfade)
      nextPreloadedPlayable = nextPlayable
      startCrossfadeFade()
    } else {
      isCrossfadePreparing = true
      Task { @MainActor in
        do {
          try await insertStreamPlayable(playable: nextPlayable, queueType: .crossfade)
          // the pending insert landed after an abort (pause/stop/manual
          // skip cleared the flag) or on a stale queue — drop it instead
          // of fading it in
          let wasAborted = !self.isCrossfadePreparing
          self.isCrossfadePreparing = false
          guard !wasAborted, !self.isPreloadedNextStale else {
            self.discardSpareInsert()
            return
          }
          self.nextPreloadedPlayable = nextPlayable
          if self.isAutoCachePlayedItems, nextPlayable.isDownloadAvailable,
             let accountInfo = nextPlayable.account?.info {
            self.getPlayableDownloaderCB(accountInfo)
              .download(object: nextPlayable, asTier: .cache)
          }
          self.startCrossfadeFade()
        } catch {
          self.isCrossfadePreparing = false
          self.discardSpareInsert()
          self.eventLogger.report(topic: "Player", error: error)
        }
      }
    }
  }

  /// The fade and the logical track change start together: the queue
  /// advance goes through the normal `didItemFinishedPlaying` path so Now
  /// Playing, scrobble and notifier semantics fire at fade-start (the
  /// moment the incoming track becomes audible), and `handleRequest`
  /// adopts the spare engine via the preloaded-match branch.
  private func startCrossfadeFade() {
    guard let sparePlayer, nextPreloadedPlayable != nil else { return }
    isCrossfading = true
    fadeOutPlayerRef = player
    fadeInPlayerRef = sparePlayer
    fadeOutFactor = 1.0
    fadeInFactor = 0.0
    // the visualizer/haptics tap follows the incoming track — it is on
    // the EQ node (before the output-volume ramp), so it sees the new
    // track at full level for the whole fade
    moveAnalyzerTap(to: spareEqualizer)
    let remainingTime = max(0.05, duration - elapsedTime)
    crossfadeActiveDurationInSec = min(crossfadeDurationInSec, remainingTime)
    crossfadeStartUptime = ProcessInfo.processInfo.systemUptime
    crossfadeTimer?.invalidate()
    crossfadeTimer = Timer.scheduledTimer(
      withTimeInterval: Self.crossfadeUpdateIntervalInSec,
      repeats: true
    ) { [weak self] _ in
      Task { @MainActor in
        self?.crossfadeTick()
      }
    }
    // the outgoing entry is logically finished now — required by the
    // preloaded-match branch; its real finish callback is ignored because
    // `currentPlayUrl` already moved to the incoming entry
    isPreviousPlaylableFinshed = true
    responder?.didItemFinishedPlaying()
  }

  private func crossfadeTick() {
    guard isCrossfading else { return }
    let elapsed = ProcessInfo.processInfo.systemUptime - crossfadeStartUptime
    let progress = min(1.0, elapsed / crossfadeActiveDurationInSec)
    // equal-power ramp keeps perceived loudness constant mid-fade
    fadeOutFactor = Float(cos(progress * .pi / 2.0))
    fadeInFactor = Float(sin(progress * .pi / 2.0))
    applyVolumes()
    if progress >= 1.0 {
      finishCrossfade()
    }
  }

  private func finishCrossfade() {
    crossfadeTimer?.invalidate()
    crossfadeTimer = nil
    fadeOutPlayerRef?.stop()
    fadeOutPlayerRef = nil
    fadeInPlayerRef = nil
    fadeOutFactor = 1.0
    fadeInFactor = 1.0
    isCrossfading = false
    applyVolumes()
  }

  /// Hard-cut out of any in-flight crossfade: stops whatever sits on the
  /// spare engine (incoming pre-adopt, draining post-adopt), restores the
  /// active engine to full volume and moves the analyzer tap back.
  /// Must no-op outside a crossfade — the markers it clears belong to the
  /// spare engine, while the same slots double as the normal preload
  /// bookkeeping of the active engine's queue.
  private func abortCrossfade() {
    guard isCrossfadePreparing || isCrossfading ||
          fadeOutPlayerRef != nil || fadeInPlayerRef != nil
    else { return }
    crossfadeTimer?.invalidate()
    crossfadeTimer = nil
    isCrossfading = false
    isCrossfadePreparing = false
    sparePlayer?.stop()
    if let fadeOutPlayerRef, fadeOutPlayerRef !== player {
      fadeOutPlayerRef.stop()
    }
    fadeOutPlayerRef = nil
    fadeInPlayerRef = nil
    fadeOutFactor = 1.0
    fadeInFactor = 1.0
    moveAnalyzerTap(to: equalizer)
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    applyVolumes()
  }

  /// drops an incoming-track insert that finished after the crossfade was
  /// already aborted — the spare engine must not keep playing it silently
  private func discardSpareInsert() {
    sparePlayer?.stop()
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    perloadedPlayType = nil
    perloadedStreamingBitrate = nil
    preloadTranscodingFormat = nil
  }

  @MainActor
  private func itemFinishedPlaying() {
    isTriggerReinsertPlayableAllowed = true
    isPreviousPlaylableFinshed = true
    if nextPreloadedPlayable != nil {
      isPlaying = true
      startTimers()
    } else {
      isPlaying = false
      stopTimers()
    }
    responder?.didItemFinishedPlaying()
  }

  private func handleError(error: Error) {
    abortCrossfade()
    isErrorOccurred = true
    wasPlayingBeforeErrorOccurred = isPlaying
    pause()
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    isPreloadedNextStale = true
    isPreviousPlaylableFinshed = true
    activeStreamingBitrate = nil
    perloadedStreamingBitrate = nil
    activeTranscodingFormat = nil
    preloadTranscodingFormat = nil
    restartPlayer()
    eventLogger.report(topic: "Player Status", error: error)
    responder?.notifyErrorOccurred(error: error)
    if isTriggerReinsertPlayableAllowed {
      isTriggerReinsertPlayableAllowed = false
      triggerReinsertPlayableCB?()
    }
  }

  func continuePlay() {
    isPlaying = true
    player?.resume()
    startTimers()
    player?.rate = Float(userDefinedPlaybackRate.asDouble)
    // re-assert the user volume — a leftover fade gain must not leak
    applyVolumes()
    audioAnalyzer.play()
  }

  func pause() {
    // a pause hard-cuts an in-flight crossfade — the draining tail must
    // not keep bleeding audio while the player is paused
    abortCrossfade()
    isPlaying = false
    player?.pause()
    stopTimers()
    audioAnalyzer.stop()
  }

  func stop() {
    isPlaying = false
    clearPlayer()
    audioAnalyzer.stop()
  }

  func setPlaybackRate(_ newValue: PlaybackRate) {
    userDefinedPlaybackRate = newValue
    player?.rate = Float(newValue.asDouble)
  }

  /// false while the playing entry does not support seeking (Ogg Vorbis
  /// streams, live radio) — engine-side seeks on those silently no-op
  var isSeekable: Bool {
    player?.isSeekable ?? true
  }

  /// skip-silence (G26) — `SkipSilenceService` drives this: a temporary
  /// engine-rate boost that never touches the persisted `PlaybackRate`
  public private(set) var isSkipSilenceBoostActive = false
  /// `AVAudioUnitTimePitch` accepts up to 32x, but past ~4x the resume
  /// back to speech stops being intelligible and the stream buffer
  /// drains faster than it refills
  private static let skipSilenceBoostFactor: Float = 3.0
  private static let skipSilenceBoostMaxRate: Float = 4.0

  func setSkipSilenceBoost(isActive: Bool) {
    isSkipSilenceBoostActive = isActive
    let base = Float(userDefinedPlaybackRate.asDouble)
    let rate = isActive
      ? min(base * Self.skipSilenceBoostFactor, Self.skipSilenceBoostMaxRate)
      : base
    player?.rate = rate
    sparePlayer?.rate = rate
  }

  func seek(toSecond: Double) {
    if currentPlayUrl != "", let player, !player.isSeekable {
      os_log(.default, "Seek ignored: current entry is not seekable")
      return
    }
    // a seek cancels any in-flight fade — the incoming track (already
    // the active engine after adoption) jumps straight to full volume
    if isCrossfadeActive {
      abortCrossfade()
    }
    if currentPlayUrl != "", player?.getState() == .playing || player?.getState() == .paused {
      seekTimeWhenStarted = nil
      player?.seek(to: toSecond)
    } else {
      seekTimeWhenStarted = toSecond
    }
  }

  private func restartPlayer() {
    player = nil
    initAudioStreamingPlayerAndNodes()
  }

  /// one engine plus its EQ and ReplayGain mixer — nodes cannot span
  /// engines, so each of the two crossfade players owns its own set
  private func buildPlayerWithNodes() -> (
    player: AudioStreamingPlayer, equalizer: AVAudioUnitEQ, replayGain: AVAudioMixerNode
  ) {
    let player = createAudioStreamingPlayerCB()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    let replayGain = AVAudioMixerNode()

    player.volume = volumePlayer
    player.delegate = self
    // a fresh engine (init + restartPlayer after handleError) resets to
    // rate 1.0 — re-apply the user rate so the engine and the UI stay
    // in sync
    player.rate = Float(userDefinedPlaybackRate.asDouble)

    player.attach(nodes: [eq, replayGain])
    setupEqualizerBands(on: eq)
    applyEqualizerSetting(eqSetting: currentEqualizerSetting, to: eq)
    return (player, eq, replayGain)
  }

  private func initAudioStreamingPlayerAndNodes() {
    guard player == nil else { return }
    audioAnalyzer = AudioAnalyzer()

    let nodes = buildPlayerWithNodes()
    player = nodes.player
    equalizer = nodes.equalizer
    replayGainNode = nodes.replayGain

    moveAnalyzerTap(to: equalizer)
    applyReplayGain()
    os_log(.debug, "Player setup completed with EQ and ReplayGain support")
  }

  /// lazily builds the second engine when a crossfade actually needs it —
  /// no crossfade setting means zero extra engine cost
  private func ensureSparePlayer() {
    guard sparePlayer == nil else { return }
    let nodes = buildPlayerWithNodes()
    sparePlayer = nodes.player
    spareEqualizer = nodes.equalizer
    spareReplayGainNode = nodes.replayGain
    sparePlayer?.volume = 0
    applyReplayGain()
  }

  /// moves the analyzer tap between engines' EQ nodes — the tap cannot
  /// span engines, so it follows whichever engine wins the fade
  private func moveAnalyzerTap(to node: AVAudioNode?) {
    guard let node, analyzerTapNode !== node else { return }
    analyzerTapNode?.removeTap(onBus: 0)
    audioAnalyzer.install(on: node)
    analyzerTapNode = node
  }

  var shouldPlaybackStart: Bool {
    (!isErrorOccurred && isAutoStartPlayback) || (isErrorOccurred && wasPlayingBeforeErrorOccurred)
  }

  func requestToPlay(
    playable: AbstractPlayable,
    playbackRate: PlaybackRate,
    autoStartPlayback: Bool
  ) {
    userDefinedPlaybackRate = playbackRate
    player?.rate = Float(userDefinedPlaybackRate.asDouble)
    isAutoStartPlayback = autoStartPlayback
    handleRequest(playable: playable)
  }

  /// G-1a — the engine queue may still hold a preloaded entry that went
  /// stale (queue mutation, sleep-timer toggle, repeat-mode flip). Drop
  /// the engine-side entry via `removeFromQueue` and refuse adoption.
  /// `removeFromQueue` also stops playback when the entry is already the
  /// playing one, so it is skipped while the preloaded URL is still the
  /// playing URL (repeat-single queues the same URL).
  func invalidatePreloadedNext() {
    isPreloadedNextStale = true
    if !nextPreloadedUrl.isEmpty, nextPreloadedUrl != currentPlayUrl,
       let url = URL(string: nextPreloadedUrl) {
      player?.removeFromQueue(url: url)
    }
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
  }

  private func handleRequest(playable: AbstractPlayable) {
    if isPreviousPlaylableFinshed, !isPreloadedNextStale,
       let nextPreloadedPlayable = nextPreloadedPlayable,
       nextPreloadedPlayable == playable {
      // Do nothing next preloaded playable has already been queued to player
      os_log(.default, "Play Preloaded: %s", nextPreloadedPlayable.displayString)
      currentPreparedUrl = ""
      currentPlayUrl = nextPreloadedUrl
      playType = perloadedPlayType
      perloadedPlayType = nil
      activeStreamingBitrate = perloadedStreamingBitrate
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = preloadTranscodingFormat
      preloadTranscodingFormat = nil
      isPreviousPlaylableFinshed = false
      if isCrossfading {
        // G3 — the incoming track already renders on the spare engine;
        // promote spare to active. The outgoing engine keeps fading to
        // silence on the crossfade timer and is stopped at its end.
        spareReplayGainValue = currentReplayGainValue
        swap(&player, &sparePlayer)
        swap(&equalizer, &spareEqualizer)
        swap(&replayGainNode, &spareReplayGainNode)
      }
      currentReplayGainValue = nextPreloadedPlayable.replayGainTrackGain
      applyReplayGain()
      self.nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      responder?.notifyItemPreparationFinished()
    } else if let relFilePath = playable.relFilePath,
              fileManager.fileExits(relFilePath: relFilePath) {
      // an explicit play request hard-cuts any in-flight crossfade and
      // any still-queued preload is superseded by this explicit request
      abortCrossfade()
      invalidatePreloadedNext()
      currentPlayUrl = ""
      activeStreamingBitrate = nil
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = nil
      preloadTranscodingFormat = nil
      guard playable.isPlayableOniOS else {
        reactToIncompatibleContentType(
          contentType: playable.fileContentType ?? "",
          playableDisplayTitle: playable.displayString
        )
        return
      }
      currentReplayGainValue = playable.replayGainTrackGain
      applyReplayGain()
      insertCachedPlayable(playable: playable)
      isPlaying = shouldPlaybackStart
      responder?.notifyItemPreparationFinished()
    } else if !isOfflineMode {
      // an explicit play request hard-cuts any in-flight crossfade and
      // any still-queued preload is superseded by this explicit request
      abortCrossfade()
      invalidatePreloadedNext()
      currentPlayUrl = ""
      activeStreamingBitrate = nil
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = nil
      preloadTranscodingFormat = nil
      guard playable.isPlayableOniOS || streamingTranscodings
        .isTranscodingActive(networkMonitor: networkMonitor) else {
        reactToIncompatibleContentType(
          contentType: playable.fileContentType ?? "",
          playableDisplayTitle: playable.displayString
        )
        return
      }
      if let radio = playable.asRadio {
        // radios must have a valid URL
        guard let urlString = radio.url,
              URL(string: urlString) != nil
        else {
          reactToInvalidRadioUrl(playableDisplayTitle: playable.displayString)
          return
        }
      }

      Task { @MainActor in
        do {
          currentReplayGainValue = playable.replayGainTrackGain
          applyReplayGain()
          try await insertStreamPlayable(playable: playable)
          isPlaying = shouldPlaybackStart
          if self.isAutoCachePlayedItems, !playable.isRadio,
             let accountInfo = playable.account?.info {
            self.getPlayableDownloaderCB(accountInfo).download(object: playable, asTier: .cache)
          }
          self.responder?.notifyItemPreparationFinished()
        } catch {
          self.responder?.notifyErrorOccurred(error: error)
          self.responder?.notifyItemPreparationFinished()
          self.eventLogger.report(topic: "Player", error: error)
        }
      }
    } else {
      clearPlayer()
      responder?.notifyItemPreparationFinished()
    }
  }

  private func reactToIncompatibleContentType(contentType: String, playableDisplayTitle: String) {
    clearPlayer()
    eventLogger.info(
      topic: "Player Info",
      statusCode: .playerError,
      message: "Content type \"\(contentType)\" of \"\(playableDisplayTitle)\" is not playable via SonicWave. Activating transcoding in Settings could resolve this issue.",
      displayPopup: true
    )
    responder?.notifyItemPreparationFinished()
  }

  private func reactToInvalidRadioUrl(playableDisplayTitle: String) {
    clearPlayer()
    eventLogger.info(
      topic: "Player Info",
      statusCode: .playerError,
      message: "Radio \"\(playableDisplayTitle)\" has an invalid stream URL.",
      displayPopup: true
    )
    responder?.notifyItemPreparationFinished()
  }

  private func clearPlayer() {
    abortCrossfade()
    isPreviousPlaylableFinshed = true
    currentPreparedUrl = ""
    currentPlayUrl = ""
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    isPreloadInsertPending = false
    isPreloadedNextStale = true
    playType = nil
    perloadedPlayType = nil
    activeStreamingBitrate = nil
    perloadedStreamingBitrate = nil
    activeTranscodingFormat = nil
    preloadTranscodingFormat = nil
    seekTimeWhenStarted = nil
    isPlaying = false
    playType = nil

    stopTimers()
    audioAnalyzer.stop()
    player?.stop()
  }

  private func insertCachedPlayable(
    playable: AbstractPlayable,
    queueType: BackendAudioQueueType = .play
  ) {
    guard let fileURL = cacheProxy.getFileURL(forPlayable: playable) else {
      return
    }
    if queueType == .play {
      playType = .cache
      perloadedPlayType = nil
      os_log(.default, "Play Cache: %s (%s)", playable.displayString, fileURL.absoluteString)
    } else {
      perloadedPlayType = .cache
      os_log(.default, "Insert Cache: %s (%s)", playable.displayString, fileURL.absoluteString)
    }
    if playable.isSong { userStatistics.playedSong(isPlayedFromCache: true) }
    insert(playable: playable, withUrl: fileURL, queueType: queueType)
  }

  @MainActor
  private func insertStreamPlayable(
    playable: AbstractPlayable,
    queueType: BackendAudioQueueType = .play
  ) async throws {
    let streamingMaxBitrate = streamingMaxBitrates.getActive(networkMonitor: networkMonitor)
    let streamingTranscodingFormat = streamingTranscodings.getActive(networkMonitor: networkMonitor)
    var httpHeaders: [String: String] = [:]
    @MainActor
    func provideUrl() async throws -> URL {
      if let radio = playable.asRadio {
        guard let streamUrlString = radio.url,
              let streamUrl = URL(string: streamUrlString)
        else {
          throw BackendError.invalidUrl
        }
        if queueType == .play {
          playType = .stream
          perloadedPlayType = nil
        } else {
          perloadedPlayType = .stream
        }
        return streamUrl
      } else {
        if queueType == .play {
          playType = .stream
          perloadedPlayType = nil
          activeStreamingBitrate = streamingMaxBitrate
          perloadedStreamingBitrate = nil
          activeTranscodingFormat = streamingTranscodingFormat
          preloadTranscodingFormat = nil
        } else {
          perloadedPlayType = .stream
          perloadedStreamingBitrate = streamingMaxBitrate
          preloadTranscodingFormat = streamingTranscodingFormat
        }
        guard let accountInfo = playable.account?.info else {
          throw BackendError.noCredentials
        }
        let backendApi = getBackendApiCB(accountInfo)
        httpHeaders = backendApi.httpHeaders
        return try await backendApi.generateUrl(
          forStreamingPlayable: playable.info,
          maxBitrate: streamingMaxBitrate,
          formatPreference: streamingTranscodingFormat
        )
      }
    }
    let streamUrl = try await provideUrl()

    if queueType == .play {
      os_log(
        .default,
        "Play Stream: %s (%s)",
        playable.displayString,
        streamingMaxBitrate.description
      )
    } else {
      os_log(
        .default,
        "Insert Stream: %s (%s)",
        playable.displayString,
        streamingMaxBitrate.description
      )
    }
    if playable.isSong { userStatistics.playedSong(isPlayedFromCache: false) }
    insert(
      playable: playable,
      withUrl: streamUrl,
      streamingMaxBitrate: streamingMaxBitrate,
      queueType: queueType,
      httpHeaders: httpHeaders
    )
  }

  private func insert(
    playable: AbstractPlayable,
    withUrl url: URL,
    streamingMaxBitrate: StreamingMaxBitratePreference = .noLimit,
    queueType: BackendAudioQueueType,
    httpHeaders: [String: String] = [:]
  ) {
    if queueType == .play {
      seekTimeWhenStarted = nil
      player?.pause()
      audioSessionHandler.configureBackgroundPlayback()
    }

    var asset: AVURLAsset?
    if let mimeType = playable.iOsCompatibleContentType {
      asset = AVURLAsset(url: url, options: ["AVURLAssetOutOfBandMIMETypeKey": mimeType])
    } else {
      asset = AVURLAsset(url: url)
    }
    playInPlayer(asset: asset, queueType: queueType, httpHeaders: httpHeaders)
  }

  private func playInPlayer(
    asset: AVURLAsset?,
    queueType: BackendAudioQueueType,
    httpHeaders: [String: String] = [:]
  ) {
    guard let asset = asset else {
      clearPlayer()
      return
    }

    switch queueType {
    case .play:
      currentPreparedUrl = asset.url.absoluteString
      if httpHeaders.isEmpty {
        player?.play(url: asset.url)
      } else {
        player?.play(url: asset.url, headers: httpHeaders)
      }
    case .queue:
      nextPreloadedUrl = asset.url.absoluteString
      if httpHeaders.isEmpty {
        player?.queue(url: asset.url)
      } else {
        player?.queue(url: asset.url, headers: httpHeaders)
      }
    case .crossfade:
      // the incoming track plays on the spare engine immediately —
      // silent until the fade ramps its volume in
      nextPreloadedUrl = asset.url.absoluteString
      sparePlayer?.rate = Float(userDefinedPlaybackRate.asDouble)
      sparePlayer?.volume = 0
      if httpHeaders.isEmpty {
        sparePlayer?.play(url: asset.url)
      } else {
        sparePlayer?.play(url: asset.url, headers: httpHeaders)
      }
    }
  }

  // MARK: - EQ Implementation

  func updateEqualizerEnabled(isEnabled: Bool) {
    isEqualizerEnabled = isEnabled
    os_log(.debug, "Equalizer enabled: %s", isEnabled.description)
    applyEqualizerToActiveContent()
  }

  func updateEqualizerSetting(eqSetting: EqualizerSetting) {
    let oldSetting = currentEqualizerSetting
    currentEqualizerSetting = eqSetting
    os_log(
      .debug,
      "Equalizer changed from %s to %s",
      oldSetting.description,
      eqSetting.description
    )
    applyEqualizerToActiveContent()
  }

  private func applyEqualizerToActiveContent() {
    let effectiveSetting = isEqualizerEnabled ? currentEqualizerSetting : .off
    // apply to both engines so a crossfade-incoming track starts with
    // the same curve the outgoing one had
    applyEqualizerSetting(eqSetting: effectiveSetting, to: equalizer)
    applyEqualizerSetting(eqSetting: effectiveSetting, to: spareEqualizer)
    applyReplayGain()
  }

  private func setupEqualizerBands(on eq: AVAudioUnitEQ) {
    for (index, frequency) in EqualizerSetting.frequencies.enumerated() {
      guard index < eq.bands.count else { break }

      let band = eq.bands[index]
      band.frequency = frequency
      band.bandwidth = 1.0
      band.filterType = .parametric
      band.gain = 0.0
      band.bypass = false
    }
  }

  private func applyEqualizerSetting(eqSetting: EqualizerSetting, to eq: AVAudioUnitEQ?) {
    guard let eq else { return }

    // EQ band gains
    for (index, gain) in eqSetting.gains.enumerated() {
      guard index < eq.bands.count else { break }

      let band = eq.bands[index]

      band.filterType = .parametric
      band.bandwidth = 1.0
      band.gain = gain
      band.bypass = false
    }

    equalizerVolumeCompensation = isEqualizerEnabled ? eqSetting.compensatedVolume : 1.0

    os_log(.debug, "   EQ '%s'", eqSetting.description)
    os_log(
      .debug,
      "   EQ Gains: [%@] dB",
      eqSetting.gains.map { String(format: "%.1f", $0) }.joined(separator: ", ")
    )
    os_log(.debug, "   EQ Gain Compensation: %.1f dB", eqSetting.gainCompensation)
    os_log(.debug, "   EQ linear Volume Compensation: %.2f", eqSetting.compensatedVolume)
    os_log(.debug, "   Active EQ linear Volume Compensation: %.2f", equalizerVolumeCompensation)
  }

  // MARK: - ReplayGain Implementation

  func updateReplayGainEnabled(isEnabled: Bool) {
    isReplayGainEnabled = isEnabled
    applyReplayGain()
  }

  /// applies each engine's own gain — the active node gets the active
  /// track's gain, the spare node the incoming track's
  private func applyReplayGain() {
    applyReplayGain(to: replayGainNode, gainDb: currentReplayGainValue)
    applyReplayGain(to: spareReplayGainNode, gainDb: spareReplayGainValue)
  }

  private func applyReplayGain(to replayGain: AVAudioMixerNode?, gainDb: Float) {
    guard let replayGain = replayGain else { return }

    let eqCompensation = isEqualizerEnabled ? equalizerVolumeCompensation : 1.0

    if isReplayGainEnabled, gainDb != 0.0 {
      // Convert dB to linear scale: gain = pow(10, dB / 20)
      let linearGain = pow(10.0, gainDb / 20.0)
      replayGain.outputVolume = linearGain * eqCompensation
      os_log(
        .debug,
        "ReplayGain: %.2f dB → %.3f linear gain (EQ Compensation: %.2f)",
        gainDb,
        linearGain,
        eqCompensation
      )
    } else {
      replayGain.outputVolume = eqCompensation
      os_log(
        .debug,
        "ReplayGain: disabled or no gain data (EQ Compensation: %.2f)",
        eqCompensation
      )
    }
  }
}

// MARK: AudioStreaming.AudioPlayerDelegate

extension BackendAudioPlayer: AudioStreaming.AudioPlayerDelegate {
  nonisolated func audioPlayerDidStartPlaying(
    player: AudioStreaming.AudioPlayer,
    with entryId: AudioStreaming.AudioEntryId
  ) {
    let entryID = entryId.id
    // capture the mixer rate on the delegate's engine — with the
    // crossfade pair two engines feed this delegate and `self.player`
    // may still point at the outgoing one
    let sampleRate = player.mainMixerNode.outputFormat(forBus: 0).sampleRate
    Task { @MainActor in
      didStartPlaying(url: entryID, sampleRate: Float(sampleRate))
    }
  }

  @MainActor
  public func didStartPlaying(url: String, sampleRate: Float) {
    if currentPreparedUrl == url {
      audioAnalyzer.playing(sampleRate: sampleRate)

      currentPreparedUrl = ""
      currentPlayUrl = url
      if shouldPlaybackStart {
        continuePlay()
        audioAnalyzer.play()
      } else {
        pause()
        audioAnalyzer.stop()
      }

      if let seekTimeWhenStarted {
        player?.seek(to: seekTimeWhenStarted)
        self.seekTimeWhenStarted = nil
      }
    } else if url == currentPlayUrl || url == nextPreloadedUrl {
      // G-1d — a gapless-queued (or crossfade-incoming) entry reached the
      // speakers without going through `currentPreparedUrl`; refresh the
      // analyzer's sample-rate mapping so the FFT tap does not run on the
      // previous entry's rate
      audioAnalyzer.playing(sampleRate: sampleRate)
    }
  }

  nonisolated func audioPlayerDidFinishBuffering(
    player: AudioStreaming.AudioPlayer,
    with entryId: AudioStreaming.AudioEntryId
  ) {}

  nonisolated func audioPlayerStateChanged(
    player: AudioStreaming.AudioPlayer,
    with newState: AudioStreaming.AudioPlayerState,
    previous: AudioStreaming.AudioPlayerState
  ) {}

  nonisolated func audioPlayerDidFinishPlaying(
    player: AudioStreaming.AudioPlayer,
    entryId: AudioStreaming.AudioEntryId,
    stopReason: AudioStreaming.AudioPlayerStopReason,
    progress: Double,
    duration: Double
  ) {
    let entryID = entryId.id
    Task { @MainActor in
      // finish callbacks from the draining (spare) engine must not drive
      // the state machine — after a same-URL fade (repeat-single, or the
      // same song queued twice) the outgoing entry's id equals
      // `currentPlayUrl` and would double-advance the queue
      guard player === self.player else { return }
      if self.currentPlayUrl == entryID {
        self.currentPlayUrl = ""
        self.itemFinishedPlaying()
      }
    }
  }

  nonisolated func audioPlayerUnexpectedError(
    player: AudioStreaming.AudioPlayer,
    error: AudioStreaming.AudioPlayerError
  ) {
    Task { @MainActor in
      if player === self.player || self.player == nil {
        self.handleError(error: error)
      } else {
        // a failing spare engine must not tear down active playback —
        // drop just the crossfade it was prepared for
        os_log(.default, "Spare player error: %s", error.localizedDescription)
        self.abortCrossfade()
        self.eventLogger.report(topic: "Player", error: error)
      }
    }
  }

  nonisolated func audioPlayerDidCancel(
    player: AudioStreaming.AudioPlayer,
    queuedItems: [AudioStreaming.AudioEntryId]
  ) {
    Task { @MainActor in
      // only the active engine's queue maps to `currentPlayUrl` — a
      // cancelled spare-engine entry must not clear the playing track
      guard player === self.player else { return }
      self.currentPlayUrl = ""
    }
  }

  nonisolated func audioPlayerDidReadMetadata(
    player: AudioStreaming.AudioPlayer,
    metadata: [String: String]
  ) {
    Task { @MainActor in
      self.responder?.didReadStreamMetadata(metadata)
    }
  }
}
