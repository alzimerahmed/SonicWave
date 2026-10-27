//
//  WatchSessionHandler.swift
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
#if canImport(WatchConnectivity)
  @preconcurrency import WatchConnectivity

  // MARK: - WatchSessionHandler

  /// iPhone-side WatchConnectivity endpoint (G15). Activates `WCSession`,
  /// answers the watch's `stateRequest`s, and executes its transport
  /// commands — strictly through `PlayerFacade`, the only API surface app
  /// code may touch.
  ///
  /// `WCSessionDelegate` callbacks arrive on a private serial queue, so
  /// the delegate methods are `nonisolated` and hop to the main actor for
  /// all player access. `@preconcurrency` silences the (unaudited)
  /// `replyHandler` Sendable gap — the handler is only ever invoked back
  /// on that same serial queue.
  @MainActor
  final class WatchSessionHandler: NSObject {
    private let player: PlayerFacade
    private let stateProvider: () -> WatchNowPlaying
    private var isStarted = false

    init(player: PlayerFacade, stateProvider: @escaping () -> WatchNowPlaying) {
      self.player = player
      self.stateProvider = stateProvider
    }

    private lazy var log = {
      OSLog(
        subsystem: "com.alzimerahmed.SonicWave",
        category: "WatchSessionHandler"
      )
    }()

    /// idempotent — `WCSession` must be activated once per session
    /// lifetime; re-activation after `sessionDidDeactivate` goes through
    /// `reactivate()` instead
    func start() {
      guard !isStarted, WCSession.isSupported() else { return }
      isStarted = true
      WCSession.default.delegate = self
      WCSession.default.activate()
    }

    /// re-activation after the system deactivated the session
    /// (watch switching / re-pairing) — Apple-prescribed pattern
    private func reactivate() {
      guard isStarted, WCSession.isSupported() else { return }
      WCSession.default.activate()
    }

    // MARK: command handling

    /// executes a `WatchCommand` against the player and returns the
    /// fresh now-playing snapshot as the message reply — the watch never
    /// needs a second round trip to re-render
    private func handle(message: [String: Any]) -> [String: Any] {
      guard let kindRaw = message[WatchKey.kind] as? String,
            let kind = WatchMessageKind(rawValue: kindRaw) else {
        os_log(
          "Dropping watch message with unknown kind",
          log: log,
          type: .info
        )
        return stateProvider().asDictionary
      }

      switch kind {
      case .stateRequest:
        break // pure query — answered with the state payload below
      case .nowPlaying:
        break // phone never receives this kind — treated as a query
      case .command:
        guard let commandRaw = message[WatchKey.command] as? String,
              let command = WatchCommand(rawValue: commandRaw) else {
          os_log("Dropping unknown watch command", log: log, type: .info)
          return stateProvider().asDictionary
        }
        execute(command, message: message)
      }
      return stateProvider().asDictionary
    }

    private func execute(_ command: WatchCommand, message: [String: Any]) {
      switch command {
      case .togglePlayPause:
        player.togglePlayPause()
      case .playNext:
        player.playNext()
      case .playPreviousOrReplay:
        player.playPreviousOrReplay()
      case .setVolume:
        guard let volume = message[WatchKey.volume] as? Double else { return }
        player.volume = Float(min(max(volume, 0), 1))
      }
    }
  }

  // MARK: WCSessionDelegate

  extension WatchSessionHandler: WCSessionDelegate {
    nonisolated func session(
      _ session: WCSession,
      activationDidCompleteWith activationState: WCSessionActivationState,
      error: Error?
    ) {
      if let error {
        os_log(
          "WCSession activation failed: %s",
          log: OSLog(
            subsystem: "com.alzimerahmed.SonicWave",
            category: "WatchSessionHandler"
          ),
          type: .error,
          error.localizedDescription
        )
      }
    }

    nonisolated func session(
      _ session: WCSession,
      didReceiveMessage message: [String: Any],
      replyHandler: @escaping ([String: Any]) -> Void
    ) {
      Task { @MainActor in
        replyHandler(self.handle(message: message))
      }
    }

    /// background-transfer path — a watch command delivered while the
    /// app was not reachable is replayed here on next launch
    nonisolated func session(
      _ session: WCSession,
      didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
      Task { @MainActor in
        _ = self.handle(message: userInfo)
      }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
      Task { @MainActor in
        self.reactivate()
      }
    }
  }
#endif
