//
//  SetPlaybackRateIntent.swift
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

// MARK: - SetPlaybackRateResultView

struct SetPlaybackRateResultView: View {
  var displayString: String

  var body: some View {
    VStack {
      AmperfyImage.playbackRate.asImage
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

// MARK: - SetPlaybackRateIntent

struct SetPlaybackRateIntent: AppIntent {
  static let intentClassName = "SetPlaybackRateIntent"
  static let title: LocalizedStringResource = "Set Playback Rate"
  static let description = IntentDescription("Sets the playback speed.")

  @Parameter(
    title: "Playback Rate",
    requestValueDialog: "Which playback rate?"
  )
  var rate: PlaybackRateAppEnum

  static var parameterSummary: some ParameterSummary {
    Summary("Set playback rate to \(\.$rate)") {}
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
    appDelegate.player.setPlaybackRate(rate.playbackRate)
    let dialog = "Playback rate set to \(rate.playbackRate.description)."
    return .result(
      dialog: IntentDialog(stringLiteral: dialog),
      view: SetPlaybackRateResultView(displayString: dialog)
    )
  }
}
