//
//  LiveActivityManager.swift
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

import Foundation
import os.log
import SonicWaveKit
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
  import ActivityKit
#endif

// MARK: - LiveActivityManager

/// Owns the playback Live Activity (G13) — starts it on track start,
/// updates it on track/pause/artwork/rate changes and ends it on stop.
/// Per-second ticking is handled inside the activity by `Date`-anchored
/// `timerInterval:` views, so updates only ship on real state changes
/// (no `NSSupportsLiveActivitiesFrequentUpdates`).
///
/// Honors `ActivityAuthorizationInfo` plus the in-app opt-out
/// `UserSettings.isLiveActivityEnabled`; turning the toggle off while an
/// activity is live ends it immediately.
@MainActor
final class LiveActivityManager: MusicPlayable {
  private let player: PlayerFacade
  private let storage: PersistentStorage
  private var refreshTask: Task<Void, Never>?
  /// serializes `update`/`end` ActivityKit calls — fire-and-forget Tasks
  /// can complete out of order and regress the activity to a stale
  /// state; each call awaits the previous one before issuing
  private var activityWork: Task<Void, Never>?

  private static let refreshDebounceNanos: UInt64 = 200_000_000

  #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var activity: Activity<PlaybackActivityAttributes>?
  #endif

  /// whether the settings UI should offer the toggle — Live Activities
  /// require device/user authorization, not just the capability flag
  static var isSupported: Bool {
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
      return ActivityAuthorizationInfo().areActivitiesEnabled
    #else
      return false
    #endif
  }

  init(player: PlayerFacade, storage: PersistentStorage) {
    self.player = player
    self.storage = storage
  }

  private lazy var log = {
    OSLog(
      subsystem: "com.alzimerahmed.SonicWave",
      category: "LiveActivityManager"
    )
  }()

  // MARK: MusicPlayable

  func didStartPlayingFromBeginning() { scheduleRefresh() }
  func didStartPlaying() { scheduleRefresh() }
  func didPause() { scheduleRefresh() }
  func didStopPlaying() { scheduleRefresh() }
  func didPlaylistChange() { scheduleRefresh() }
  func didArtworkChange() { scheduleRefresh() }
  func didNowPlayingInfoChange() { scheduleRefresh() }
  func didPlaybackRateChange() { scheduleRefresh() }
  /// elapsed ticks are deliberately ignored — the activity's
  /// `Date`-anchored progress views tick locally
  func didElapsedTimeChange() {}
  func didShuffleChange() {}
  func didRepeatChange() {}

  /// re-evaluates immediately after the user toggles
  /// `isLiveActivityEnabled` — disabling ends a running activity now
  func settingChanged() {
    refresh()
  }

  /// called once at bridge start: adopts an already-live activity
  /// (relaunch mid-session), ends stale leftovers, refreshes state
  func syncOnStart() {
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
      if activity == nil {
        activity = Activity<PlaybackActivityAttributes>.activities.first
        for stale in Activity<PlaybackActivityAttributes>.activities
          .dropFirst() {
          enqueueActivityWork {
            await stale.end(nil, dismissalPolicy: .immediate)
          }
        }
      }
      refresh()
    #endif
  }

  // MARK: activity lifecycle

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.refreshDebounceNanos)
      guard let self, !Task.isCancelled else { return }
      refresh()
    }
  }

  private func refresh() {
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
      guard storage.settings.user.isLiveActivityEnabled,
            ActivityAuthorizationInfo().areActivitiesEnabled,
            let playable = player.currentlyPlaying else {
        endActivity()
        return
      }
      let content = ActivityContent(
        state: makeContentState(for: playable),
        staleDate: nil
      )
      if let activity {
        enqueueActivityWork {
          await activity.update(content)
        }
        return
      }
      if let existing = Activity<PlaybackActivityAttributes>.activities.first {
        activity = existing
        enqueueActivityWork {
          await existing.update(content)
        }
        return
      }
      let attributes = PlaybackActivityAttributes(
        contextName: player.contextName,
        themeName: themeName(for: playable)
      )
      do {
        activity = try Activity<PlaybackActivityAttributes>.request(
          attributes: attributes,
          content: content,
          pushType: nil
        )
      } catch {
        os_log(
          "Live Activity request failed: %s",
          log: log,
          type: .error,
          error.localizedDescription
        )
      }
    #endif
  }

  private func endActivity() {
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
      guard let activity else { return }
      let finalContent = ActivityContent(
        state: activity.content.state,
        staleDate: nil
      )
      // self.activity stays bound until `end` actually executes inside the
      // work chain — nil'ing early let refresh() re-adopt the dying
      // activity via `activities.first` and update it after its own end
      enqueueActivityWork { [weak self] in
        await activity.end(finalContent, dismissalPolicy: .immediate)
        await MainActor.run { self?.activity = nil }
      }
    #endif
  }

  /// chains an ActivityKit call behind the previous one so updates and
  /// ends always apply in issue order
  private func enqueueActivityWork(
    _ work: @escaping @Sendable () async -> Void
  ) {
    let previous = activityWork
    activityWork = Task {
      await previous?.value
      await work()
    }
  }

  #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private func makeContentState(
      for playable: AbstractPlayable
    ) -> PlaybackActivityAttributes.ContentState {
      let radioInfo = playable.isRadio ? player.currentRadioNowPlaying : nil
      return PlaybackActivityAttributes.ContentState(
        title: radioInfo?.title ?? playable.title,
        artist: playable.isRadio
          ? (radioInfo?.artist ?? "")
          : playable.creatorName,
        album: playable.asSong?.album?.name ?? "",
        artworkFileName: WidgetStatePublisher
          .copyArtworkIntoGroupContainer(
            for: playable,
            storage: storage
          ),
        isPlaying: player.isPlaying,
        isRadio: playable.isRadio,
        isCached: playable.isCached,
        elapsedAnchor: Date(),
        elapsedSeconds: player.elapsedTime,
        duration: player.duration,
        playbackRate: player.playbackRate.asDouble
      )
    }
  #endif

  private func themeName(for playable: AbstractPlayable?) -> String {
    storage.settings.accounts.getSetting(playable?.account?.info)
      .read.themePreference.description.lowercased()
  }
}
