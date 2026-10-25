//
//  SetDislikeForCurrentlyPlayingSongIntent.swift
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

extension DislikeTypeAppEnum {
  var image: Image {
    switch self {
    case .dislike:
      return Image(systemName: "hand.thumbsdown.fill")
    case .removeDislike:
      return Image(systemName: "hand.thumbsdown")
    }
  }
}

// MARK: - SetDislikeForCurrentlyPlayingSongResultView

struct SetDislikeForCurrentlyPlayingSongResultView: View {
  var isDislike: DislikeTypeAppEnum
  var displayString: String

  var body: some View {
    VStack {
      isDislike.image
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

// MARK: - SetDislikeForCurrentlyPlayingSongIntent

struct SetDislikeForCurrentlyPlayingSongIntent: AppIntent {
  static let intentClassName = "SetDislikeForCurrentlyPlayingSongIntent"
  static let title: LocalizedStringResource = "Dislike currently playing song"
  static let description = IntentDescription(
    "Marks the currently playing song as disliked or removes the dislike."
  )

  @Parameter(
    title: "Dislike"
  )
  var isDislike: DislikeTypeAppEnum

  static var parameterSummary: some ParameterSummary {
    Summary("\(\.$isDislike) currently playing song") {}
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
    guard let currentlyPlaying = appDelegate.player.currentlyPlaying else {
      throw AmperfyAppIntentError.noItemIsPlaying
    }
    guard let song = currentlyPlaying.asSong else {
      // ignore
      return .result(dialog: "This option is only available for songs.")
    }
    let isDislikedBool = isDislike == .dislike
    let dialog =
      "\(song.title)\(song.creatorName != "" ? " by \(song.creatorName)" : "") \(isDislikedBool ? "has been disliked." : "is no longer disliked.")"
    guard currentlyPlaying.isDisliked != isDislikedBool else {
      // do nothing
      return .result(
        dialog: IntentDialog(stringLiteral: dialog),
        view:
        SetDislikeForCurrentlyPlayingSongResultView(isDislike: isDislike, displayString: dialog)
      )
    }

    // local-only flag on both shipped backends — the remote call stays
    // (same as the entity-preview context menu) so future backends can
    // sync it; a failure is logged, never thrown, because the flag
    // doesn't need a server round-trip
    appDelegate.storage.main.library.setDisliked(isDislikedBool, for: song)
    if let accountInfo = song.account?.info {
      do {
        if isDislikedBool {
          _ = try await appDelegate.getMeta(accountInfo).backendApi
            .setDislike(playableInfo: song.info)
        } else {
          _ = try await appDelegate.getMeta(accountInfo).backendApi
            .clearDislike(playableInfo: song.info)
        }
      } catch {
        appDelegate.eventLogger.report(topic: "Dislike Sync", error: error)
      }
    }
    return .result(
      dialog: IntentDialog(stringLiteral: dialog),
      view:
      SetDislikeForCurrentlyPlayingSongResultView(isDislike: isDislike, displayString: dialog)
    )
  }
}
