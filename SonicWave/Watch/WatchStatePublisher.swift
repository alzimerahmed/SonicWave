//
//  WatchStatePublisher.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 28.10.26.
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

import Foundation
import os.log
import SonicWaveKit
import UIKit
#if canImport(WatchConnectivity)
  import WatchConnectivity

  // MARK: - WatchStatePublisher

  /// Pushes the now-playing snapshot to a paired Apple Watch (G15).
  /// Latest-state semantics: `updateApplicationContext` overwrites — only
  /// the newest snapshot matters and the system delivers it when the
  /// watch next wakes. Player events are coalesced through the same short
  /// debounce `WidgetStatePublisher` uses (track changes fire
  /// start/playlist/artwork callbacks in one burst).
  ///
  /// Artwork travels separately via `transferFile` — a downscaled JPEG
  /// tagged with the playable id, re-sent only when the track changes
  /// (`lastArtworkTrackId` dedupe).
  @MainActor
  final class WatchStatePublisher: MusicPlayable {
    private let player: PlayerFacade
    private let storage: PersistentStorage
    private var publishTask: Task<Void, Never>?
    private var lastArtworkTrackId: String?

    private static let publishDebounceNanos: UInt64 = 300_000_000
    /// watch-side Now Playing renders at ~this many points — 2x for the
    /// largest Ultra display, then JPEG'd at moderate quality
    private static let artworkPixelSize: CGFloat = 480
    private static let artworkJPEGQuality: CGFloat = 0.7

    init(player: PlayerFacade, storage: PersistentStorage) {
      self.player = player
      self.storage = storage
    }

    private lazy var log = {
      OSLog(
        subsystem: "com.alzimerahmed.SonicWave",
        category: "WatchStatePublisher"
      )
    }()

    // MARK: MusicPlayable

    func didStartPlayingFromBeginning() { schedulePublish() }
    func didStartPlaying() { schedulePublish() }
    func didPause() { schedulePublish() }
    func didStopPlaying() { schedulePublish() }
    func didPlaylistChange() { schedulePublish() }
    func didArtworkChange() { schedulePublish() }
    func didNowPlayingInfoChange() { schedulePublish() }
    func didPlaybackRateChange() { schedulePublish() }
    /// elapsed ticks are deliberately ignored — the watch advances
    /// progress locally from the `capturedAt` anchor
    func didElapsedTimeChange() {}
    func didShuffleChange() {}
    func didRepeatChange() {}

    // MARK: publishing

    private func schedulePublish() {
      publishTask?.cancel()
      publishTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: Self.publishDebounceNanos)
        guard let self, !Task.isCancelled else { return }
        publishNow()
      }
    }

    /// immediate publish — called once at bridge start so a watch opened
    /// while the app is already playing shows content without waiting
    /// for the next player event
    func publishNow() {
      guard WCSession.isSupported(),
            WCSession.default.activationState == .activated else { return }
      let state = buildState()
      do {
        try WCSession.default.updateApplicationContext(state.asDictionary)
      } catch {
        os_log(
          "Watch state publish failed: %s",
          log: log,
          type: .error,
          error.localizedDescription
        )
      }
      publishArtwork(for: state)
    }

    func buildState() -> WatchNowPlaying {
      guard let playable = player.currentlyPlaying else {
        return WatchNowPlaying()
      }
      let radioInfo = playable.isRadio ? player.currentRadioNowPlaying : nil
      let upNext = player
        .getNextQueueItems(from: 0, to: WatchNowPlaying.maxUpNextItems)
        .map { WatchQueueItem(title: $0.title, artist: $0.creatorName) }
      return WatchNowPlaying(
        hasNowPlaying: true,
        trackId: playable.id,
        title: radioInfo?.title ?? playable.title,
        artist: playable.isRadio
          ? (radioInfo?.artist ?? "")
          : playable.creatorName,
        album: playable.asSong?.album?.name ?? "",
        isPlaying: player.isPlaying,
        isRadio: playable.isRadio,
        isSeekable: player.isSeekable,
        elapsed: player.elapsedTime,
        duration: player.duration,
        volume: Double(player.volume),
        contextName: player.contextName,
        capturedAt: Date(),
        upNext: upNext
      )
    }

    // MARK: artwork transfer

    /// transfers a downscaled JPEG of the current artwork — once per
    /// track; a `nil` artwork path just leaves the watch on its
    /// placeholder (which is honest, not a hollow surface)
    private func publishArtwork(for state: WatchNowPlaying) {
      guard state.hasNowPlaying,
            state.trackId != lastArtworkTrackId else { return }
      let preference = storage.settings.accounts
        .getSetting(
          player.currentlyPlaying?.account?.info
        )
        .read.artworkDisplayPreference
      guard let sourcePath = player.currentlyPlaying?
        .imagePath(setting: preference),
        let transferURL = makeArtworkTransferFile(
          sourcePath: sourcePath,
          trackId: state.trackId
        ) else {
        // nothing to send — mark so we don't re-probe on every event
        lastArtworkTrackId = state.trackId
        return
      }
      lastArtworkTrackId = state.trackId
      WCSession.default.transferFile(
        transferURL,
        metadata: [WatchKey.artworkTrackId: state.trackId]
      )
    }

    /// renders the cached artwork file down to watch size and writes it
    /// to a temp JPEG — `transferFile` requires a file URL
    private func makeArtworkTransferFile(
      sourcePath: String,
      trackId: String
    ) -> URL? {
      guard let image = UIImage(contentsOfFile: sourcePath) else { return nil }
      let targetSize = min(
        Self.artworkPixelSize,
        max(image.size.width, image.size.height)
      )
      let scale = targetSize / max(image.size.width, image.size.height)
      let size = CGSize(
        width: image.size.width * scale,
        height: image.size.height * scale
      )
      let renderer = UIGraphicsImageRenderer(size: size)
      let data = renderer.jpegData(
        withCompressionQuality: Self.artworkJPEGQuality
      ) { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("watch-art-\(trackId.hashValue).jpg")
      do {
        try data.write(to: url, options: .atomic)
        return url
      } catch {
        os_log(
          "Watch artwork transfer file write failed: %s",
          log: log,
          type: .error,
          error.localizedDescription
        )
        return nil
      }
    }
  }
#endif
