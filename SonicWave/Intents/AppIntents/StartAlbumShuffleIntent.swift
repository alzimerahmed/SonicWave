//
//  StartAlbumShuffleIntent.swift
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

// MARK: - StartAlbumShuffleResultView

struct StartAlbumShuffleResultView: View {
  var displayString: String

  var body: some View {
    VStack {
      AmperfyImage.shuffle.asImage
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

// MARK: - StartAlbumShuffleIntent

struct StartAlbumShuffleIntent: AppIntent {
  static let intentClassName = "StartAlbumShuffleIntent"
  static let title: LocalizedStringResource = "Shuffle Albums"
  static let description = IntentDescription(
    "Starts album radio: whole albums from the library play through in shuffled order (G21 album-queue shuffle)."
  )

  @Parameter(
    title: "Account",
    description: "Account whose library is shuffled. If not provided the active account will be used."
  )
  var account: AccountAppEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Shuffle albums") {
      \.$account
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
    guard let accountCoreData = appDelegate.intentManager.getAccount(fromIntent: account)
    else { throw AmperfyAppIntentError.accountNotValid }

    if appDelegate.player.isAlbumShuffleSessionActive {
      return .result(
        dialog: "Album shuffle is already running.",
        view: StartAlbumShuffleResultView(displayString: "Album shuffle is already running.")
      )
    }

    let songs = appDelegate.storage.main.library.getSongs(for: accountCoreData)
    guard !songs.isEmpty else { throw AmperfyAppIntentError.notFound }

    // same entry path as the entity-preview "Shuffle Albums" action
    // (EntityPreviewVC): enable the account-level album-shuffle mode, then
    // `playShuffled` — the kit keeps whole albums back-to-back and lazily
    // appends the next album as the queue drains
    appDelegate.storage.settings.accounts.updateSetting(accountCoreData.info) { accountSettings in
      accountSettings.isAlbumShuffleActive = true
    }
    appDelegate.player.playShuffled(
      context: PlayContext(name: "Album Shuffle", playables: songs)
    )

    let dialog = "Album shuffle started."
    return .result(
      dialog: IntentDialog(stringLiteral: dialog),
      view: StartAlbumShuffleResultView(displayString: dialog)
    )
  }
}
