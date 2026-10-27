//
//  WatchBridge.swift
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
import SonicWaveKit
#if canImport(WatchConnectivity)

  // MARK: - WatchBridge

  /// Owns the app-side watch services (G15): `WatchSessionHandler`
  /// (WCSession activation + command execution) and `WatchStatePublisher`
  /// (now-playing pushes + artwork transfers). Player notifiers are held
  /// **weakly** by the player — this bridge is what keeps the publisher
  /// alive. Mirrors `WidgetBridge`: `start()` is idempotent and safe to
  /// call from both manager-start seams.
  @MainActor
  final class WatchBridge {
    private let player: PlayerFacade
    private let sessionHandler: WatchSessionHandler
    private let statePublisher: WatchStatePublisher
    private var isStarted = false

    init(player: PlayerFacade, storage: PersistentStorage) {
      self.player = player
      statePublisher = WatchStatePublisher(player: player, storage: storage)
      sessionHandler = WatchSessionHandler(
        player: player,
        stateProvider: { [statePublisher] in statePublisher.buildState() }
      )
    }

    /// idempotent — called from both `startManagerForNormalOperation`
    /// and `startManagerAfterSync` alongside `widgetBridge.start()`
    func start() {
      guard !isStarted else { return }
      isStarted = true
      sessionHandler.start()
      player.addNotifier(notifier: statePublisher)
      // push a snapshot immediately — a watch opened while the app is
      // already playing must not wait for the next player event
      statePublisher.publishNow()
    }
  }
#endif
