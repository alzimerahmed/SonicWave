//
//  SyncedLyricsTracker.swift
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
import CoreData
import CoreMedia
import Foundation

// MARK: - LyricsTrackingUpdate

/// Snapshot published by `SyncedLyricsTracker` — the resolved lyrics
/// result for the current track plus the playback position inside it.
/// `activeLine`/`activeWordIndex` stay nil for unsynced or missing lyrics.
public struct LyricsTrackingUpdate: Sendable, Equatable {
  /// resolution outcome for the currently playing track
  /// (`.none` while resolving and when no source produced lyrics)
  public var result: LyricsResult
  /// the lyric line active at the current playback position
  /// (only for `.synced` results)
  public var activeLine: ActiveLyricLine?
  /// index into `activeLine.line.words` for word-level karaoke
  /// highlighting — nil when the line has no word timings
  public var activeWordIndex: Int?

  public init(
    result: LyricsResult = .none,
    activeLine: ActiveLyricLine? = nil,
    activeWordIndex: Int? = nil
  ) {
    self.result = result
    self.activeLine = activeLine
    self.activeWordIndex = activeWordIndex
  }
}

// MARK: - SyncedLyricsTracker

/// Playback-side half of the G4 synced-lyrics subsystem: observes the
/// player as a `MusicPlayable` notifier, resolves lyrics for the
/// currently playing song through `SyncedLyricsManager` (injected as a
/// provider so the active account is resolved by the caller), and
/// republishes the active `ActiveLyricLine`/word index.
///
/// Subscriptions:
/// - `@Published update` for Combine/SwiftUI consumers
/// - `Notification.Name.syncedLyricsUpdate` for NotificationCenter
///   consumers (posted on every published change, `object` = tracker)
///
/// Handles: track change (refetch + reset), seek (recompute — including
/// seeks while paused via `updatePlaybackPosition`), unsynced results
/// (published once, no ticking), no lyrics and offline (both surface as
/// `.none`). Timing rides the existing 0.1s `didLyricsTimeChange`
/// player callback — no own timer needed.
@MainActor
public final class SyncedLyricsTracker: ObservableObject {
  @Published public private(set) var update = LyricsTrackingUpdate()

  /// the resolved lyrics for the current track, if any
  public var currentLyrics: SyncedLyrics? { update.result.syncedLyrics }

  private let currentlyPlayingCB: @MainActor () -> AbstractPlayable?
  private let elapsedTimeCB: @MainActor () -> Double
  private let lyricsProvider: @MainActor (AbstractPlayable) async -> LyricsResult
  private let notificationHandler: EventNotificationHandler?
  private var trackedPlayableObjectID: NSManagedObjectID?
  /// generation guard — a resolve that lands after the track already
  /// changed again must not overwrite the newer track's state
  private var resolveGeneration = 0

  public init(
    currentlyPlayingCB: @escaping @MainActor () -> AbstractPlayable?,
    elapsedTimeCB: @escaping @MainActor () -> Double,
    lyricsProvider: @escaping @MainActor (AbstractPlayable) async -> LyricsResult,
    notificationHandler: EventNotificationHandler? = nil
  ) {
    self.currentlyPlayingCB = currentlyPlayingCB
    self.elapsedTimeCB = elapsedTimeCB
    self.lyricsProvider = lyricsProvider
    self.notificationHandler = notificationHandler
  }

  /// Forces a re-resolve of the current track's lyrics — e.g. after the
  /// UI invalidated the `SyncedLyricsManager` cache (manual refresh).
  public func refresh() {
    trackedPlayableObjectID = nil
    updateTrackingIfNeeded()
  }

  /// Recomputes the active line for an arbitrary position — call after
  /// seek interactions while paused (the lyrics tick only runs during
  /// playback).
  public func updatePlaybackPosition(seconds: Double) {
    recomputeActive(atSeconds: seconds)
  }

  private func updateTrackingIfNeeded() {
    let playable = currentlyPlayingCB()
    let objectID = playable?.objectID
    guard objectID != trackedPlayableObjectID else { return }
    trackedPlayableObjectID = objectID
    resolveGeneration += 1
    publish(LyricsTrackingUpdate())
    guard let playable else { return }
    let generation = resolveGeneration
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await lyricsProvider(playable)
      guard resolveGeneration == generation,
            trackedPlayableObjectID == playable.objectID
      else { return }
      var newUpdate = LyricsTrackingUpdate(result: result)
      // compute the active line immediately so a track resumed mid-way
      // lands on the right lyric instead of waiting for the next tick
      if let lyrics = result.syncedLyrics, lyrics.synced {
        let elapsed = elapsedTimeCB()
        newUpdate.activeLine = lyrics.activeLine(atSeconds: elapsed)
        newUpdate.activeWordIndex = activeWordIndex(
          line: newUpdate.activeLine,
          lyrics: lyrics,
          atSeconds: elapsed
        )
      }
      publish(newUpdate)
    }
  }

  private func recomputeActive(atSeconds seconds: Double) {
    guard let lyrics = update.result.syncedLyrics, lyrics.synced else { return }
    let line = lyrics.activeLine(atSeconds: seconds)
    let wordIndex = activeWordIndex(line: line, lyrics: lyrics, atSeconds: seconds)
    guard update.activeLine != line || update.activeWordIndex != wordIndex
    else { return }
    var newUpdate = update
    newUpdate.activeLine = line
    newUpdate.activeWordIndex = wordIndex
    publish(newUpdate)
  }

  /// Word-level index inside `line` — `activeWord` expects the already
  /// offset-adjusted position (matching `SyncedLyrics.activeLine`).
  private func activeWordIndex(
    line: ActiveLyricLine?,
    lyrics: SyncedLyrics,
    atSeconds seconds: Double
  ) -> Int? {
    guard let line else { return nil }
    let adjustedMs = Int((seconds * 1_000).rounded()) + lyrics.offset
    return line.line.activeWord(atMilliseconds: adjustedMs)?.index
  }

  private func publish(_ newUpdate: LyricsTrackingUpdate) {
    guard newUpdate != update else { return }
    update = newUpdate
    notificationHandler?.post(name: .syncedLyricsUpdate, object: self, userInfo: nil)
  }
}

// MARK: MusicPlayable

extension SyncedLyricsTracker: MusicPlayable {
  public func didStartPlayingFromBeginning() {
    updateTrackingIfNeeded()
  }

  public func didStartPlaying() {
    updateTrackingIfNeeded()
  }

  public func didPause() {}

  public func didStopPlaying() {
    trackedPlayableObjectID = nil
    resolveGeneration += 1
    publish(LyricsTrackingUpdate())
  }

  public func didElapsedTimeChange() {
    updateTrackingIfNeeded()
  }

  public func didPlaylistChange() {}
  public func didArtworkChange() {}

  /// 0.1s playback tick — the heart of line/word tracking; also catches
  /// track switches that did not surface through `didStartPlaying`
  public func didLyricsTimeChange(time: CMTime) {
    updateTrackingIfNeeded()
    recomputeActive(atSeconds: time.seconds)
  }
}
