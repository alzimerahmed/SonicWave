//
//  SleepTimerIntent.swift
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

import SonicWaveKit
import AppIntents
import Foundation
import SwiftUI

extension SleepTimerOptionAppEnum {
  var image: Image {
    switch self {
    case .off:
      return AmperfyImage.sleep.asImage
    default:
      return AmperfyImage.sleepFill.asImage
    }
  }
}

// MARK: - SleepTimerResultView

struct SleepTimerResultView: View {
  var option: SleepTimerOptionAppEnum
  var displayString: String

  var body: some View {
    VStack {
      option.image
        .font(intentResultViewHeaderImageFont)
        .foregroundStyle(
          appDelegate.storage.settings.accounts.activeSetting.read.themePreference
            .asSwiftUIColor
        )
      Spacer()
      Text(displayString)
    }
    .padding()
  }
}

// MARK: - SleepTimerIntent

struct SleepTimerIntent: AppIntent {
  static let intentClassName = "SleepTimerIntent"
  static let title: LocalizedStringResource = "Sleep Timer"
  static let description = IntentDescription(
    "Starts a sleep timer that pauses playback after a countdown or at the end of the current track, or turns the timer off."
  )

  @Parameter(
    title: "Timer",
    requestValueDialog: "When should playback pause?"
  )
  var timerOption: SleepTimerOptionAppEnum

  static var parameterSummary: some ParameterSummary {
    Summary("Set sleep timer to \(\.$timerOption)") {}
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
    let dialog: String
    switch timerOption {
    case .off:
      appDelegate.deactivateSleepTimer()
      dialog = "Sleep timer is off."
    case .endOfTrack:
      // mirrors the main-menu action: a pending countdown is replaced by
      // the pause-at-end-of-track flag
      appDelegate.sleepTimer?.invalidate()
      appDelegate.sleepTimer = nil
      appDelegate.player.isShouldPauseAfterFinishedPlaying = true
      dialog =
        "Playback will pause at the end of the current \(appDelegate.player.playerMode.playableName)."
    default:
      appDelegate.player.isShouldPauseAfterFinishedPlaying = false
      appDelegate.activateSleepTimer(timeInterval: timerOption.timeInterval ?? 0)
      dialog = "Playback will pause in \(timerOption.displayName.lowercased())."
    }
    return .result(
      dialog: IntentDialog(stringLiteral: dialog),
      view: SleepTimerResultView(option: timerOption, displayString: dialog)
    )
  }
}
