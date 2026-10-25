//
//  WidgetStatePublisher.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 25.10.26.
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

import CryptoKit
import Foundation
import os.log
import SonicWaveKit
#if canImport(WidgetKit)
  import WidgetKit
#endif

// MARK: - WidgetStatePublisher

/// Publishes `WidgetState.json` + artwork copies into the App Group
/// container so home/lock-screen widgets (G12) always have a now-playing
/// snapshot, then asks WidgetKit to reload timelines.
///
/// `WidgetCenter` is imported directly here rather than routed through an
/// AppDelegate notification — the call is self-contained (reloads are a
/// pure function of the published state) and this keeps AppDelegate's
/// wiring down to a single `widgetBridge.start()`.
///
/// Player events are coalesced through a short debounce — a track change
/// fires start/playlist/artwork callbacks in one burst.
@MainActor
final class WidgetStatePublisher: MusicPlayable {
  private let player: PlayerFacade
  private let storage: PersistentStorage
  private var publishTask: Task<Void, Never>?

  private static let maxRecentItems = 10
  private static let publishDebounceNanos: UInt64 = 300_000_000

  init(player: PlayerFacade, storage: PersistentStorage) {
    self.player = player
    self.storage = storage
  }

  private lazy var log = {
    OSLog(
      subsystem: "com.alzimerahmed.SonicWave",
      category: "WidgetStatePublisher"
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
  /// elapsed ticks are deliberately ignored — widgets derive progress
  /// from the `elapsedAnchor` Date in the snapshot
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

  /// immediate publish — called once at bridge start so a widget added
  /// while the app is already playing shows content without waiting for
  /// the next player event
  func publishNow() {
    let state = buildState()
    do {
      try pruneArtworkDirectory(keeping: state)
      try WidgetStore.writeState(state)
      reloadWidgetTimelines()
    } catch {
      os_log(
        "Widget state publish failed: %s",
        log: log,
        type: .error,
        error.localizedDescription
      )
    }
  }

  private func buildState() -> WidgetState {
    var nowPlaying: WidgetNowPlaying?
    if let playable = player.currentlyPlaying {
      let radioInfo = playable.isRadio ? player.currentRadioNowPlaying : nil
      nowPlaying = WidgetNowPlaying(
        id: playable.id,
        libraryElementType: Self.libraryElementType(of: playable),
        title: radioInfo?.title ?? playable.title,
        artist: playable.isRadio
          ? (radioInfo?.artist ?? "")
          : playable.creatorName,
        album: playable.asSong?.album?.name ?? "",
        artworkFileName: Self
          .copyArtworkIntoGroupContainer(
            for: playable,
            storage: storage
          ),
        isPlaying: player.isPlaying,
        isCached: playable.isCached,
        contextName: player.contextName,
        elapsedAnchor: Date(),
        elapsedSeconds: player.elapsedTime,
        duration: player.duration,
        playbackRate: player.playbackRate.asDouble,
        themeName: themeName(for: playable),
        updatedAt: Date()
      )
    }

    let prevCount = player.prevQueueCount
    let recentlyPlayed = player
      .getPrevQueueItems(
        from: max(0, prevCount - Self.maxRecentItems),
        to: nil
      )
      .reversed()
      .map { playable in
        WidgetRecentItem(
          id: playable.id,
          libraryElementType: Self.libraryElementType(of: playable),
          title: playable.title,
          artist: playable.creatorName,
          artworkFileName: Self
            .copyArtworkIntoGroupContainer(
              for: playable,
              storage: storage
            )
        )
      }

    return WidgetState(
      nowPlaying: nowPlaying,
      recentlyPlayed: recentlyPlayed
    )
  }

  private static func libraryElementType(
    of playable: AbstractPlayable
  ) -> WidgetLibraryElementType {
    switch playable.derivedType {
    case .song:
      return .song
    case .podcastEpisode:
      return .podcastEpisode
    case .radio:
      return .radio
    }
  }

  private func themeName(for playable: AbstractPlayable?) -> String {
    storage.settings.accounts.getSetting(playable?.account?.info)
      .read.themePreference.description.lowercased()
  }

  private func reloadWidgetTimelines() {
    #if canImport(WidgetKit)
      WidgetCenter.shared
        .reloadTimelines(ofKind: WidgetSharedConfig.kindNowPlaying)
      WidgetCenter.shared
        .reloadTimelines(ofKind: WidgetSharedConfig.kindRecentlyPlayed)
      WidgetCenter.shared
        .reloadTimelines(ofKind: WidgetSharedConfig.kindLockScreenNowPlaying)
    #endif
  }

  // MARK: artwork sync

  /// Copies the playable's artwork into `widget-art/` (content key derived
  /// from the playable id so re-publishes don't duplicate files) and
  /// returns the container-relative file name for `WidgetState`.
  /// Shared with `LiveActivityManager`, which publishes the same names.
  static func copyArtworkIntoGroupContainer(
    for playable: AbstractPlayable,
    storage: PersistentStorage
  ) -> String? {
    let preference = storage.settings.accounts
      .getSetting(playable.account?.info)
      .read.artworkDisplayPreference
    guard let sourcePath = playable.imagePath(setting: preference),
          let directory = WidgetStore.artworkDirectoryURL else { return nil }
    let fileName = artworkFileName(
      forPlayableId: playable.id,
      sourcePath: sourcePath
    )
    let destination = directory.appendingPathComponent(fileName)
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.copyItem(
          atPath: sourcePath,
          toPath: destination.path
        )
      }
      return fileName
    } catch {
      return nil
    }
  }

  /// stable, filesystem-safe artwork key: 128-bit SHA-256 of the playable
  /// id + the source extension (jpeg/png both load via `UIImage`)
  private static func artworkFileName(
    forPlayableId id: String,
    sourcePath: String
  ) -> String {
    let pathExtension = (sourcePath as NSString).pathExtension
    let digest = SHA256.hash(data: Data(id.utf8))
    let hex = digest.prefix(16)
      .map { String(format: "%02x", $0) }
      .joined()
    return pathExtension.isEmpty ? hex : "\(hex).\(pathExtension)"
  }

  /// drops `widget-art/` files no longer referenced by the state
  private func pruneArtworkDirectory(keeping state: WidgetState) throws {
    guard let directory = WidgetStore.artworkDirectoryURL,
          FileManager.default.fileExists(atPath: directory.path) else { return }
    var keep = Set<String>()
    if let name = state.nowPlaying?.artworkFileName {
      keep.insert(name)
    }
    for item in state.recentlyPlayed {
      if let name = item.artworkFileName {
        keep.insert(name)
      }
    }
    let files = try FileManager.default
      .contentsOfDirectory(atPath: directory.path)
    for file in files where !keep.contains(file) {
      try? FileManager.default
        .removeItem(at: directory.appendingPathComponent(file))
    }
  }
}
