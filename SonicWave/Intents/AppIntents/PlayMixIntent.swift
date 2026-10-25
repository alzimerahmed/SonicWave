//
//  PlayMixIntent.swift
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

// MARK: - PlayMixResultView

struct PlayMixResultView: View {
  var mixKind: MixKindAppEnum
  var displayString: String

  var body: some View {
    VStack {
      AmperfyImage.instantMix.asImage
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

// MARK: - PlayMixIntent

struct PlayMixIntent: AppIntent {
  static let intentClassName = "PlayMixIntent"
  static let title: LocalizedStringResource = "Play Mix"
  static let description = IntentDescription(
    "Resolves and plays one of the discovery mixes (Favorites Radio, Decade Mix, Genre Blend, Deep Cuts, Time Machine)."
  )

  @Parameter(
    title: "Mix",
    requestValueDialog: "Which mix do you want to play?"
  )
  var mixKind: MixKindAppEnum

  @Parameter(
    title: "Mix Seed",
    description: "Only used by seeded mixes: the decade start year for Decade Mix (e.g. 1990) or the genre name for Genre Blend."
  )
  var mixSeed: String?

  @Parameter(
    title: "Account",
    description: "Account whose library resolves the mix. If not provided the active account will be used."
  )
  var account: AccountAppEntity?

  @Parameter(title: "Shuffle", default: .off)
  var shuffleOption: ShuffleTypeAppEnum

  static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$mixKind) mix") {
      \.$mixSeed
      \.$account
      \.$shuffleOption
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
    guard let accountCoreData = appDelegate.intentManager.getAccount(fromIntent: account)
    else { throw AmperfyAppIntentError.accountNotValid }

    let mix = Mix(
      kind: mixKind.mixKind,
      title: mixKind.displayName,
      parameter: mixSeed
    )
    // `resolve` reports "mix can't be built right now" as an empty list or
    // a thrown error — for an intent both collapse into one spoken
    // unavailability answer, never a failure
    guard let songs = try? await appDelegate.getMeta(accountCoreData.info)
      .mixProvider.resolve(mix: mix), !songs.isEmpty
    else {
      return .result(
        dialog: "The \(mixKind.displayName) mix isn't available right now.",
        view: PlayMixResultView(
          mixKind: mixKind,
          displayString: "The \(mixKind.displayName) mix isn't available right now."
        )
      )
    }

    _ = appDelegate.intentManager.play(
      context: PlayContext(name: mix.title, playables: songs),
      shuffleOption: shuffleOption == .on,
      repeatOption: .off
    )
    let dialog = "Now playing \(mix.title)."
    return .result(
      dialog: IntentDialog(stringLiteral: dialog),
      view: PlayMixResultView(mixKind: mixKind, displayString: dialog)
    )
  }
}
