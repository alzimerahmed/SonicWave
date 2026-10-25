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

// MARK: - WidgetCommandPerformer

/// Dispatch surface for widget transport commands (G12 interactivity).
///
/// Writes `WidgetCommand.json` into the App Group container and posts the
/// `command` Darwin notification. The app's `WidgetCommandConsumer` reads,
/// deletes and executes the file — file absence within
/// `commandConsumeTimeout` is the proof that the app is alive and handled
/// the tap, so the widget can finish without opening the app.
enum WidgetCommandPerformer {
  /// `true` = app consumed the command (no open needed). `false` = no
  /// consumer responded — caller should fall back to opening the app;
  /// the command file survives and is consumed on next app start.
  static func dispatch(_ command: WidgetCommand) async -> Bool {
    do {
      try WidgetStore.writeCommand(command)
    } catch {
      return false
    }
    WidgetStore.postCommandNotification()

    let deadline = Date()
      .addingTimeInterval(WidgetSharedConfig.commandConsumeTimeout)
    while Date() < deadline {
      if Task.isCancelled {
        return true
      }
      if !WidgetStore.commandFileExists() {
        return true
      }
      try? await Task.sleep(nanoseconds: 60_000_000)
    }
    return false
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

  func perform() async throws -> some IntentResult & OpensIntent {
    if await WidgetCommandPerformer.dispatch(.togglePlayPause) {
      return .result()
    }
    return .result(opensIntent: OpenSonicWaveIntent(target: .playback))
  }
}

// MARK: - NextTrackWidgetIntent

struct NextTrackWidgetIntent: AppIntent {
  static let title: LocalizedStringResource = "Next Track"
  static let description = IntentDescription("Skips to the next track.")
  static let isDiscoverable = false

  init() {}

  func perform() async throws -> some IntentResult & OpensIntent {
    if await WidgetCommandPerformer.dispatch(.playNext) {
      return .result()
    }
    return .result(opensIntent: OpenSonicWaveIntent(target: .playback))
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

  func perform() async throws -> some IntentResult & OpensIntent {
    if await WidgetCommandPerformer.dispatch(.playPreviousOrReplay) {
      return .result()
    }
    return .result(opensIntent: OpenSonicWaveIntent(target: .playback))
  }
}

// MARK: - WidgetOpenTarget

/// Trivial entity satisfying `OpenIntent`'s `Target: AppEntity`
/// requirement — carries the logical destination for cold opens.
struct WidgetOpenTarget: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation =
    "SonicWave"
  static let defaultQuery = WidgetOpenTargetQuery()

  var id: String

  static let playback = WidgetOpenTarget(id: "playback")

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "SonicWave")
  }
}

// MARK: - WidgetOpenTargetQuery

struct WidgetOpenTargetQuery: EntityQuery {
  func entities(
    for identifiers: [WidgetOpenTarget.ID]
  ) async throws -> [WidgetOpenTarget] {
    identifiers.map { WidgetOpenTarget(id: $0) }
  }

  func suggestedEntities() async throws -> [WidgetOpenTarget] {
    [.playback]
  }
}

// MARK: - OpenSonicWaveIntent

/// `OpenIntent` bridge used when a widget transport tap can't reach a
/// running app — the system launches SonicWave to perform this intent
/// (custom `sonicwave://` schemes are not openable from widget intents;
/// `OpenURLIntent` accepts universal links only). The pending command file
/// is consumed by `WidgetCommandConsumer` during app start.
struct OpenSonicWaveIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open SonicWave"
  static let isDiscoverable = false

  @Parameter(title: "Target")
  var target: WidgetOpenTarget

  init() {
    target = .playback
  }

  init(target: WidgetOpenTarget) {
    self.target = target
  }

  func perform() async throws -> some IntentResult {
    // performed inside the app — no action needed here; the command file
    // written by the widget is picked up on start
    .result()
  }
}
