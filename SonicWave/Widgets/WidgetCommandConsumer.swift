//
//  WidgetCommandConsumer.swift
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

/// Darwin-notification callback — `CFNotificationCallback` is a C
/// convention function pointer, so it cannot capture context; the consumer
/// instance travels through the `observer` pointer instead.
private let widgetCommandDarwinCallback: CFNotificationCallback = {
  _, observer, _, _, _ in
  guard let observer else { return }
  let consumer = Unmanaged<WidgetCommandConsumer>
    .fromOpaque(observer)
    .takeUnretainedValue()
  Task { @MainActor in
    consumer.consumePending()
  }
}

// MARK: - WidgetCommandConsumer

/// Executes widget transport commands (G12). The widget extension writes
/// `WidgetCommand.json` into the App Group container and posts the
/// `command` Darwin notification; this consumer reads, deletes and runs
/// the command on the player — the widget's tap never has to open the app
/// while it is alive. Files left over from a killed session are drained at
/// start (fresh only — a stale tap is not replayed).
@MainActor
final class WidgetCommandConsumer {
  private let player: PlayerFacade
  private var isObserving = false

  init(player: PlayerFacade) {
    self.player = player
  }

  private lazy var log = {
    OSLog(
      subsystem: "com.alzimerahmed.SonicWave",
      category: "WidgetCommandConsumer"
    )
  }()

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(WidgetSharedConfig.commandDarwinNotification as CFString),
      nil
    )
  }

  /// starts observing the Darwin channel, then drains any pending
  /// command — observing first closes the race where a command file
  /// written between drain and registration would sit until next launch
  func start() {
    guard !isObserving else { return }
    isObserving = true
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      widgetCommandDarwinCallback,
      WidgetSharedConfig.commandDarwinNotification as CFString,
      nil,
      .deliverImmediately
    )
    consumePending()
  }

  /// runs the newest pending command; envelopes older than
  /// `commandMaxAge` are dropped — replaying a stale tap from a killed
  /// session on the next launch would be surprising
  fileprivate func consumePending() {
    guard let envelope = WidgetStore.consumeCommandEnvelope() else { return }
    let age = -envelope.createdAt.timeIntervalSinceNow
    guard age < WidgetSharedConfig.commandMaxAge else {
      os_log(
        "Dropping stale widget command (%lds old)",
        log: log,
        type: .info,
        Int(age)
      )
      return
    }
    execute(envelope.command)
  }

  private func execute(_ command: WidgetCommand) {
    switch command {
    case .togglePlayPause:
      player.togglePlayPause()
    case .playNext:
      player.playNext()
    case .playPreviousOrReplay:
      player.playPreviousOrReplay()
    }
  }
}
