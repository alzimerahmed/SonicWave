//
//  WidgetIntents.swift
//  SonicWaveWidgets
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

import AppIntents
import Foundation
import os.log

// MARK: - WidgetCommandPerformer

/// Dispatch surface for widget transport commands (G12 interactivity).
///
/// Writes `WidgetCommand.json` into the App Group container and posts the
/// `command` Darwin notification. The app's `WidgetCommandConsumer` reads,
/// deletes and executes the file; when the app is not running the file
/// survives in the container and `WidgetCommandConsumer.start()` drains it
/// at next launch — the widget itself never has to open the app.
enum WidgetCommandPerformer {
  private static let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "WidgetCommandPerformer"
  )

  static func dispatch(_ command: WidgetCommand) {
    do {
      try WidgetStore.writeCommand(command)
    } catch {
      // log, then ping anyway — a pending command file from an earlier
      // tap may still be sitting in the container
      os_log(
        "Widget command write failed (%s): %s",
        log: log,
        type: .error,
        command.rawValue,
        error.localizedDescription
      )
    }
    WidgetStore.postCommandNotification()
  }
}

// MARK: - TogglePlayPauseWidgetIntent

struct TogglePlayPauseWidgetIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle Play/Pause"
  static let description = IntentDescription(
    "Plays or pauses SonicWave playback."
  )
  static let isDiscoverable = false

  init() {}

  func perform() async throws -> some IntentResult {
    WidgetCommandPerformer.dispatch(.togglePlayPause)
    return .result()
  }
}

// MARK: - NextTrackWidgetIntent

struct NextTrackWidgetIntent: AppIntent {
  static let title: LocalizedStringResource = "Next Track"
  static let description = IntentDescription("Skips to the next track.")
  static let isDiscoverable = false

  init() {}

  func perform() async throws -> some IntentResult {
    WidgetCommandPerformer.dispatch(.playNext)
    return .result()
  }
}

// MARK: - PreviousTrackWidgetIntent

struct PreviousTrackWidgetIntent: AppIntent {
  static let title: LocalizedStringResource = "Previous Track"
  static let description = IntentDescription(
    "Plays the previous track (or replays the current one)."
  )
  static let isDiscoverable = false

  init() {}

  func perform() async throws -> some IntentResult {
    WidgetCommandPerformer.dispatch(.playPreviousOrReplay)
    return .result()
  }
}
