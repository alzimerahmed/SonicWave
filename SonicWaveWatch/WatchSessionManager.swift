//
//  WatchSessionManager.swift
//  SonicWaveWatch
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
import SwiftUI
import WatchConnectivity

// MARK: - WatchSessionManager

/// Watch-side WatchConnectivity endpoint (G15, remote control only).
/// Receives `WatchNowPlaying` snapshots via `updateApplicationContext`
/// and artwork via file transfers; sends transport commands as
/// `sendMessage` when the iPhone app is reachable (fresh state comes
/// back in the reply) or `transferUserInfo` when it is not (the phone
/// app is woken in the background and pushes state back via context).
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
  /// latest snapshot — `hasNowPlaying == false` drives the idle state
  @Published private(set) var nowPlaying = WatchNowPlaying()
  /// iOS app reachable right now — gates `sendMessage` vs
  /// `transferUserInfo` and the unreachable overlay
  @Published private(set) var isReachable = false
  /// SonicWave installed on the paired iPhone
  @Published private(set) var isCompanionAppInstalled = true
  /// artwork for `artworkTrackId` — displayed only while it matches the
  /// current track; `nil` renders the placeholder
  @Published private(set) var artwork: UIImage?
  @Published private(set) var artworkTrackId = ""
  /// crown-bound volume — remote value is mirrored in on state apply;
  /// local edits are throttled out as `setVolume` commands
  @Published var volume: Double = 0.5 {
    didSet { scheduleVolumeSend() }
  }

  private var isApplyingRemoteVolume = false
  private var lastSentVolume: Double?
  private var volumeSendTask: Task<Void, Never>?
  private static let volumeThrottleNanos: UInt64 = 200_000_000

  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "WatchSessionManager"
  )

  /// nonisolated so `@StateObject`'s nonisolated autoclosure can build it —
  /// the delegate callbacks + `activationDidComplete` (which performs the
  /// initial state reads) do the MainActor work
  nonisolated override init() {
    super.init()
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  // MARK: commands

  func send(_ command: WatchCommand) {
    var message: [String: Any] = [
      WatchKey.kind: WatchMessageKind.command.rawValue,
      WatchKey.command: command.rawValue,
    ]
    if command == .setVolume {
      message[WatchKey.volume] = volume
    }
    guard WCSession.isSupported() else { return }
    let log = self.log
    if WCSession.default.isReachable {
      WCSession.default.sendMessage(
        message,
        replyHandler: { [weak self] reply in
          Task { @MainActor in
            self?.apply(stateDictionary: reply)
          }
        },
        errorHandler: { error in
          os_log(
            "Watch command send failed: %s",
            log: log,
            type: .error,
            error.localizedDescription
          )
        }
      )
    } else {
      // phone app not running — the transfer wakes it in the
      // background; play/pause toggles optimistically so the UI never
      // shows a control that silently does nothing
      WCSession.default.transferUserInfo(message)
      applyOptimisticEffect(of: command)
    }
  }

  /// asks the phone for a fresh snapshot — used on activation; only
  /// useful while reachable
  func requestState() {
    guard WCSession.isSupported(), WCSession.default.isReachable else { return }
    WCSession.default.sendMessage(
      [WatchKey.kind: WatchMessageKind.stateRequest.rawValue],
      replyHandler: { [weak self] reply in
        Task { @MainActor in
          self?.apply(stateDictionary: reply)
        }
      },
      errorHandler: nil
    )
  }

  // MARK: state application

  private func apply(stateDictionary: [String: Any]) {
    guard !stateDictionary.isEmpty else { return }
    let state = WatchNowPlaying(dictionary: stateDictionary)
    nowPlaying = state
    isApplyingRemoteVolume = true
    volume = state.volume
    lastSentVolume = state.volume
    isApplyingRemoteVolume = false
    if state.trackId != artworkTrackId {
      artwork = nil
    }
  }

  private func applyOptimisticEffect(of command: WatchCommand) {
    switch command {
    case .togglePlayPause:
      var updated = nowPlaying
      updated.isPlaying.toggle()
      updated.capturedAt = Date()
      nowPlaying = updated
    case .playNext, .playPreviousOrReplay, .setVolume:
      break // nothing honest to fabricate — the context push will land
    }
  }

  // MARK: volume throttle

  private func scheduleVolumeSend() {
    guard !isApplyingRemoteVolume else { return }
    volumeSendTask?.cancel()
    volumeSendTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.volumeThrottleNanos)
      guard let self, !Task.isCancelled else { return }
      guard lastSentVolume != volume else { return }
      lastSentVolume = volume
      send(.setVolume)
    }
  }
}

// MARK: WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Task { @MainActor in
      isCompanionAppInstalled = session.isCompanionAppInstalled
      isReachable = session.isReachable
      apply(stateDictionary: session.receivedApplicationContext)
      requestState()
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      isReachable = session.isReachable
      if session.isReachable {
        requestState()
      }
    }
  }

  nonisolated func sessionCompanionStateDidChange(_ session: WCSession) {
    Task { @MainActor in
      isCompanionAppInstalled = session.isCompanionAppInstalled
      isReachable = session.isReachable
    }
  }

  nonisolated func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    Task { @MainActor in
      apply(stateDictionary: applicationContext)
    }
  }

  /// artwork delivery — keep it only if it belongs to a known track;
  /// a stale transfer would otherwise linger on screen
  nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
    let trackId = file.metadata?[WatchKey.artworkTrackId] as? String ?? ""
    let image = UIImage(contentsOfFile: file.fileURL.path)
    Task { @MainActor in
      guard let image, !trackId.isEmpty else { return }
      artworkTrackId = trackId
      artwork = image
    }
  }
}
