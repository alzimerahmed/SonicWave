//
//  AlbumShuffleHandler.swift
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

import Foundation

// MARK: - AlbumProgressInfo

/// Playthrough progress of the album currently playing inside an album
/// shuffle session (G21) — polled by the UI for a progress bar.
public struct AlbumProgressInfo: Sendable, Equatable {
  /// display name of the album currently in play
  public let albumName: String
  /// tracks inside the current album group
  public let totalTrackCount: Int
  /// tracks of the current album already finished
  public let playedTrackCount: Int
  /// summed durations of all tracks in the current album (seconds)
  public let totalDurationInSeconds: Int
  /// played seconds inside the current album, incl. elapsed time of the
  /// currently playing track
  public let playedDurationInSeconds: Double
  /// albums still pending in the shuffle pool (not yet appended)
  public let queuedAlbumCount: Int
  /// name of the album that will be appended next, if any
  public let nextAlbumName: String?

  public init(
    albumName: String,
    totalTrackCount: Int,
    playedTrackCount: Int,
    totalDurationInSeconds: Int,
    playedDurationInSeconds: Double,
    queuedAlbumCount: Int,
    nextAlbumName: String?
  ) {
    self.albumName = albumName
    self.totalTrackCount = totalTrackCount
    self.playedTrackCount = playedTrackCount
    self.totalDurationInSeconds = totalDurationInSeconds
    self.playedDurationInSeconds = playedDurationInSeconds
    self.queuedAlbumCount = queuedAlbumCount
    self.nextAlbumName = nextAlbumName
  }

  /// playthrough as 0...1 for progress indicators
  public var progressRatio: Double {
    guard totalDurationInSeconds > 0 else { return 0 }
    return min(max(playedDurationInSeconds / Double(totalDurationInSeconds), 0), 1)
  }

  /// Copy with the live elapsed time folded into
  /// `playedDurationInSeconds` — the player caches the verdict computed
  /// once per track/queue change (played duration = finished tracks
  /// only), so each read re-adds the current position and the 1s UI
  /// tick stays allocation-free.
  func addingElapsedTime(_ elapsedTime: Double) -> AlbumProgressInfo {
    AlbumProgressInfo(
      albumName: albumName,
      totalTrackCount: totalTrackCount,
      playedTrackCount: playedTrackCount,
      totalDurationInSeconds: totalDurationInSeconds,
      playedDurationInSeconds: playedDurationInSeconds + elapsedTime,
      queuedAlbumCount: queuedAlbumCount,
      nextAlbumName: nextAlbumName
    )
  }
}

// MARK: - AlbumShuffleGroup

/// One album inside an album shuffle session — its playables in album
/// track order (disk, track, title, id).
struct AlbumShuffleGroup {
  var name: String
  var playables: [AbstractPlayable]
}

// MARK: - AlbumShufflePlan

/// Result of `AlbumShuffleHandler.planSession` — the context to start
/// playback with plus the shuffled album pool to append lazily.
struct AlbumShufflePlan {
  /// the first album to play (`index` points at the start track inside it)
  var initialContext: PlayContext
  /// the album group loaded into the queue by `initialContext`
  var activeGroup: AlbumShuffleGroup
  /// the remaining album groups, shuffled
  var pendingGroups: [AlbumShuffleGroup]
}

// MARK: - AlbumShuffleHandler

/// G21 album-queue shuffle ("album radio"): holds the pool of albums a
/// `playShuffled` session has not queued yet. `AudioPlayer` materializes
/// the next shuffled album into the context queue whenever the queue
/// drains (`materializeNextAlbumInQueue`), so playback continues until
/// the pool is exhausted.
@MainActor
class AlbumShuffleHandler {
  private(set) var activeGroup: AlbumShuffleGroup?
  private var pendingGroups = [AlbumShuffleGroup]()

  /// `AudioPlayer` constructs this from a nonisolated property
  /// initializer — fresh state needs no actor hop
  nonisolated init() {}

  /// true while a session is running — even when the pool is already
  /// drained (the last album is playing)
  var isSessionActive: Bool { activeGroup != nil }
  /// albums still waiting to be appended
  var hasPendingAlbums: Bool { !pendingGroups.isEmpty }
  var queuedAlbumCount: Int { pendingGroups.count }

  func activate(plan: AlbumShufflePlan) {
    activeGroup = plan.activeGroup
    pendingGroups = plan.pendingGroups
  }

  /// Pops the next shuffled album and makes it the new `activeGroup`.
  /// Returns nil when the pool is exhausted.
  func dequeueNextAlbum() -> AlbumShuffleGroup? {
    guard !pendingGroups.isEmpty else { return nil }
    let next = pendingGroups.removeFirst()
    activeGroup = next
    return next
  }

  func reset() {
    activeGroup = nil
    pendingGroups = []
  }

  /// Album playthrough progress for the UI progress bar — nil when no
  /// session is running or the currently playing item is not part of the
  /// active album (e.g. a user-queue song is playing).
  func progress(
    currentlyPlaying: AbstractPlayable?,
    elapsedTime: Double
  ) -> AlbumProgressInfo? {
    guard let group = activeGroup,
          let current = currentlyPlaying,
          let index = group.playables
            .firstIndex(where: { $0.objectID == current.objectID })
    else { return nil }
    let total = group.playables.reduce(0) { $0 + $1.duration }
    let played = Double(group.playables.prefix(index).reduce(0) { $0 + $1.duration }) +
      elapsedTime
    return AlbumProgressInfo(
      albumName: group.name,
      totalTrackCount: group.playables.count,
      playedTrackCount: index,
      totalDurationInSeconds: total,
      playedDurationInSeconds: played,
      queuedAlbumCount: pendingGroups.count,
      nextAlbumName: pendingGroups.first?.name
    )
  }

  /// Groups a play context into whole albums: playables are bucketed by
  /// album in first-seen order, each bucket sorted in album track order.
  /// The album containing `context`'s active playable goes first when
  /// `isKeepIndexDuringShuffle` is set, otherwise every album is shuffled.
  /// Returns nil for non-music contexts and for contexts with a single
  /// album — those fall back to the regular song shuffle.
  static func planSession(context: PlayContext) -> AlbumShufflePlan? {
    guard context.type == .music, !context.playables.isEmpty else { return nil }
    var order = [String]()
    var grouped = [String: AlbumShuffleGroup]()
    for playable in context.playables {
      // songs without an album and non-song playables each form their own
      // single-item group so nothing is ever dropped from the session
      let key = playable.asSong?.album?.id ?? "__loose_\(playable.id)"
      let name = playable.asSong?.album?.name ?? playable.title
      if grouped[key] == nil {
        grouped[key] = AlbumShuffleGroup(name: name, playables: [])
        order.append(key)
      }
      grouped[key]?.playables.append(playable)
    }
    var groups = order.compactMap { grouped[$0] }.map { group -> AlbumShuffleGroup in
      var sorted = group
      sorted.playables = sortInAlbumTrackOrder(sorted.playables)
      return sorted
    }
    // a single album has nothing to shuffle across — the regular
    // song-level shuffle handles that context better
    guard groups.count > 1 else { return nil }

    var startIndex = 0
    if context.isKeepIndexDuringShuffle,
       let startPlayable = context.getActivePlayable(),
       let groupIndex = groups.firstIndex(
         where: { group in
           group.playables.contains { $0.objectID == startPlayable.objectID }
         }
       ) {
      let group = groups.remove(at: groupIndex)
      startIndex = group.playables
        .firstIndex(where: { $0.objectID == startPlayable.objectID }) ?? 0
      groups.shuffle()
      groups.insert(group, at: 0)
    } else {
      groups.shuffle()
    }

    let active = groups.removeFirst()
    return AlbumShufflePlan(
      initialContext: PlayContext(
        name: context.name,
        type: context.type,
        index: startIndex,
        playables: active.playables
      ),
      activeGroup: active,
      pendingGroups: groups
    )
  }

  /// Disk-aware album track order — like `Song.sortByTrackNumber`
  /// except disks compare numerically when both parse, so `"10"` sorts
  /// after `"2"` instead of before it.
  private static func sortInAlbumTrackOrder(
    _ playables: [AbstractPlayable]
  ) -> [AbstractPlayable] {
    playables.sorted {
      if $0.disk != $1.disk {
        let leftDisk = $0.disk ?? ""
        let rightDisk = $1.disk ?? ""
        if let leftNumber = Int(leftDisk), let rightNumber = Int(rightDisk) {
          return leftNumber < rightNumber
        }
        return leftDisk < rightDisk
      } else if $0.track != $1.track {
        return $0.track < $1.track
      } else if $0.title != $1.title {
        return $0.title < $1.title
      } else {
        return $0.id < $1.id
      }
    }
  }
}
