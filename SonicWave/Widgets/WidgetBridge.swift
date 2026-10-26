//
//  WidgetBridge.swift
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
import SonicWaveKit
#if canImport(WidgetKit)
  import WidgetKit
#endif

// MARK: - WidgetBridge

/// Owns the app-side widget/live-activity services (G12 + G13):
/// `WidgetStatePublisher` (state file + timeline reloads),
/// `WidgetCommandConsumer` (Darwin-notification transport commands) and
/// `LiveActivityManager`. Player notifiers are held **weakly** by the
/// player — this bridge is what keeps all three alive.
@MainActor
final class WidgetBridge {
  private let player: PlayerFacade
  private let statePublisher: WidgetStatePublisher
  private let commandConsumer: WidgetCommandConsumer
  private let liveActivityManager: LiveActivityManager
  private var isStarted = false

  init(player: PlayerFacade, storage: PersistentStorage) {
    self.player = player
    statePublisher = WidgetStatePublisher(player: player, storage: storage)
    commandConsumer = WidgetCommandConsumer(player: player)
    liveActivityManager = LiveActivityManager(player: player, storage: storage)
  }

  /// idempotent — called from both `startManagerForNormalOperation` and
  /// `startManagerAfterSync`
  func start() {
    guard !isStarted else { return }
    isStarted = true
    player.addNotifier(notifier: statePublisher)
    player.addNotifier(notifier: liveActivityManager)
    commandConsumer.start()
    // push a snapshot immediately — a widget added while the app is
    // already playing must not wait for the next player event
    statePublisher.publishNow()
    liveActivityManager.syncOnStart()
  }

  /// re-evaluates the Live Activity immediately — turning
  /// `isLiveActivityEnabled` off must end a running activity now, not on
  /// the next player event
  func notifyLiveActivitySettingChanged() {
    liveActivityManager.settingChanged()
  }

  /// Security seam (M1): account teardown — logout and the launch-time
  /// obsolete-account cleanup — must also erase the shared widget
  /// artifacts (`WidgetState.json`, `widget-art/` contents, pending
  /// command file); the state isn't per-account keyed, so any removed
  /// account invalidates the whole surface. Static so the seam works
  /// without materializing the lazy bridge.
  static func purgeSharedState() {
    WidgetStore.purgeSharedState()
    #if canImport(WidgetKit)
      WidgetCenter.shared
        .reloadTimelines(ofKind: WidgetSharedConfig.kindNowPlaying)
      WidgetCenter.shared
        .reloadTimelines(ofKind: WidgetSharedConfig.kindRecentlyPlayed)
      WidgetCenter.shared
        .reloadTimelines(ofKind: WidgetSharedConfig.kindLockScreenNowPlaying)
    #endif
  }
}
