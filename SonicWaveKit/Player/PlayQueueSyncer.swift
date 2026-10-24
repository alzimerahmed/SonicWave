//
//  PlayQueueSyncer.swift
//  SonicWaveKit
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

import CoreData
import Foundation
import os.log

// MARK: - PlayQueueSyncDecision

enum PlayQueueSyncDecision {
  /// local queue won — upload it to the server
  case push
  /// server queue is newer — restore it locally
  case pull
  /// nothing to do
  case none
}

// MARK: - PlayQueueSyncPolicy

/// Conflict policy for server play-queue sync (G9), pure decision
/// function kept separate from side effects for unit testing:
/// - a locally dirty queue always wins — it is pushed, never clobbered
///   by a restore (data-loss prevention)
/// - otherwise the remote queue is restored only when its `changed`
///   timestamp is newer than the last one we have already seen
///   (`PlayerData.playQueueRemoteChangeDate`)
enum PlayQueueSyncPolicy {
  static func decide(
    isPlayQueueDirty: Bool,
    remoteChangeDate: Date?,
    lastSeenRemoteChangeDate: Date?
  ) -> PlayQueueSyncDecision {
    if isPlayQueueDirty {
      return .push
    }
    guard let remoteChangeDate else {
      return .none
    }
    guard let lastSeenRemoteChangeDate else {
      return .pull
    }
    return remoteChangeDate > lastSeenRemoteChangeDate ? .pull : .none
  }
}

// MARK: - PlayQueueSyncer

/// Server play-queue synchronisation (G9), modelled on `ScrobbleSyncer`:
/// registered as a `MusicPlayable` notifier so every user-facing queue
/// mutation lands in `didPlaylistChange` — there it marks
/// `PlayerData.isPlayQueueDirty` and schedules a debounced
/// `savePlayQueue` upload. On `start()` it fetches `getPlayQueue` and
/// applies `PlayQueueSyncPolicy` (push / pull / none).
///
/// Feature-gated by backend: Ampache returns `nil` remote queues and
/// no-ops uploads, so this class silently degrades there.
@MainActor
public class PlayQueueSyncer {
  /// settle window after the last queue change before uploading — queue
  /// edits often arrive in bursts (multi-add, reorder)
  private static let uploadDebounceIntervalInSec: TimeInterval = 3.0

  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "PlayQueueSyncer")
  private let player: PlayerFacade
  private let networkMonitor: NetworkMonitorFacade
  private let account: Account
  private let storage: PersistentStorage
  private let librarySyncer: LibrarySyncer
  private let eventLogger: EventLogger
  private var isRunning = false
  private var isActive = false
  private var debounceTimer: Timer?

  private var playerData: PlayerData {
    storage.main.library.getPlayerData()
  }

  init(
    player: PlayerFacade,
    networkMonitor: NetworkMonitorFacade,
    account: Account,
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    eventLogger: EventLogger
  ) {
    self.player = player
    self.networkMonitor = networkMonitor
    self.account = account
    self.storage = storage
    self.librarySyncer = librarySyncer
    self.eventLogger = eventLogger
  }

  /// pull-check on login/sync completion, then push when the policy says so
  public func start() {
    isRunning = true
    if !isActive {
      isActive = true
      Task { @MainActor in
        await self.syncPlayQueueOnStartup()
        self.isActive = false
      }
    }
  }

  public func stop() {
    isRunning = false
    debounceTimer?.invalidate()
    debounceTimer = nil
  }

  private var isSyncAllowed: Bool {
    isRunning && storage.settings.user.isOnlineMode && networkMonitor.isConnectedToNetwork
  }

  private func syncPlayQueueOnStartup() async {
    guard isSyncAllowed else { return }
    do {
      let remoteQueue = try await librarySyncer.syncDownRemotePlayQueue()
      let data = playerData
      let decision = PlayQueueSyncPolicy.decide(
        isPlayQueueDirty: data.isPlayQueueDirty,
        remoteChangeDate: remoteQueue?.changedDate,
        lastSeenRemoteChangeDate: data.playQueueRemoteChangeDate
      )
      switch decision {
      case .push:
        try await uploadPlayQueue()
      case .pull:
        if let remoteQueue {
          restoreRemotePlayQueue(remoteQueue)
        }
      case .none:
        break
      }
    } catch {
      eventLogger.report(topic: "Play Queue Sync", error: error, displayPopup: false)
    }
  }

  private func uploadPlayQueue() async throws {
    let data = playerData
    // only the music context queue is mirrored — podcast mode has no
    // server representation; skip (dirty stays set until a music sync)
    guard data.playerMode == .music else { return }
    let songIds = data.contextQueue.playables.compactMap { $0.asSong?.id }
    // `current` must reference an id inside the uploaded list — when the
    // user queue is playing the current item is not part of the context
    // queue, so derive it from the context index instead
    let currentSongId = data.currentIndex >= 0 ? data.contextQueue
      .getPlayable(at: data.currentIndex)?.asSong?.id : nil
    let snapshot = PlayQueueSnapshot(
      songIds: songIds,
      currentSongId: currentSongId,
      positionInMilliseconds: Int(player.elapsedTime * 1_000)
    )
    try await librarySyncer.syncUpload(playQueue: snapshot)
    os_log(
      "Play queue uploaded (%i songs)",
      log: self.log,
      type: .info,
      snapshot.songIds.count
    )
    let now = Date()
    data.setPlayQueueLastSyncDate(now)
    // our own upload is the newest remote state — stamping it prevents
    // the next pull-check from restoring the queue we just wrote
    data.setPlayQueueRemoteChangeDate(now)
    data.setPlayQueueDirty(false)
  }

  /// Restores the remote queue into `PlayerData.contextQueue`.
  /// Mutates `playerData` directly instead of going through the player
  /// facade: facade queue methods would start playback / stop the player
  /// and fire `didPlaylistChange`, which would echo-dirty the queue we
  /// just restored. Restoring at startup before the player is live makes
  /// the silent write safe.
  /// Songs not synced locally yet are skipped (documented limitation) —
  /// the remote queue references server ids that only exist after a
  /// library sync has fetched them.
  private func restoreRemotePlayQueue(_ remoteQueue: RemotePlayQueue) {
    let data = playerData
    var restoredPlayables = [AbstractPlayable]()
    var unresolvedCount = 0
    for songId in remoteQueue.songIds {
      if let song = storage.main.library.getSong(for: account, id: songId) {
        restoredPlayables.append(song)
      } else {
        unresolvedCount += 1
      }
    }
    if unresolvedCount > 0 {
      os_log(
        "Play queue restore: %i server songs not synced locally — skipped",
        log: self.log,
        type: .info,
        unresolvedCount
      )
    }

    data.clearContextQueue()
    if !restoredPlayables.isEmpty {
      data.appendContextQueue(playables: restoredPlayables)
      let restoredIndex = remoteQueue.currentSongId
        .flatMap { id in restoredPlayables.firstIndex(where: { $0.id == id }) } ?? 0
      data.setUserQueuePlaying(false)
      data.setCurrentIndex(restoredIndex)
    }
    data.setPlayQueueRemoteChangeDate(remoteQueue.changedDate)

    // position restore: seeking only makes sense when the player already
    // has the restored song loaded — otherwise the position has nowhere
    // to persist and is dropped (documented limitation)
    if let currentId = remoteQueue.currentSongId,
       player.currentlyPlaying?.id == currentId, player.isPlaying {
      player.seek(toSecond: Double(remoteQueue.positionInMilliseconds) / 1_000)
    }

    os_log(
      "Play queue restored from server (%i songs)",
      log: self.log,
      type: .info,
      restoredPlayables.count
    )
  }

  private func scheduleDebouncedUpload() {
    debounceTimer?.invalidate()
    debounceTimer = Timer
      .scheduledTimer(withTimeInterval: Self.uploadDebounceIntervalInSec, repeats: false) { _ in
        Task { @MainActor in
          guard self.isSyncAllowed else { return }
          do {
            try await self.uploadPlayQueue()
          } catch {
            self.eventLogger.report(
              topic: "Play Queue Sync",
              error: error,
              displayPopup: false
            )
          }
        }
      }
  }
}

// MARK: MusicPlayable

extension PlayQueueSyncer: MusicPlayable {
  /// every user-facing queue mutation (insert/append/remove/move/clear)
  /// funnels through here — mark dirty and let changes settle before push
  public func didPlaylistChange() {
    guard isRunning else { return }
    playerData.setPlayQueueDirty(true)
    scheduleDebouncedUpload()
  }

  public func didStartPlayingFromBeginning() {}
  public func didStartPlaying() {}
  public func didPause() {}
  public func didStopPlaying() {}
  public func didElapsedTimeChange() {}
  public func didArtworkChange() {}
  public func didShuffleChange() {}
  public func didRepeatChange() {}
  public func didPlaybackRateChange() {}
}
