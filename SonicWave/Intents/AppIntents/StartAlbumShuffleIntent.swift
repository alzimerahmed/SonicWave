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

// MARK: - StartAlbumShuffleIntent

struct StartAlbumShuffleIntent: AppIntent {
  static let intentClassName = "StartAlbumShuffleIntent"
  static let title: LocalizedStringResource = "Shuffle Albums"
  static let description = IntentDescription(
    "Starts album radio: whole albums from the library play through in shuffled order."
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

    // shared recipe with the Home-Screen quick action
    // (`QuickActionsHandler`) — the handler also no-ops a live session
    // instead of wiping the queue
    switch AlbumShuffleLauncher.start(
      storage: appDelegate.storage,
      player: appDelegate.player,
      accountInfo: accountCoreData.info
    ) {
    case .alreadyRunning:
      return .result(
        dialog: "Album shuffle is already running.",
        view: IntentResultView(
          image: AmperfyImage.shuffle.asImage,
          displayString: "Album shuffle is already running."
        )
      )
    case .libraryEmpty:
      throw AmperfyAppIntentError.notFound
    case .started:
      let dialog = "Album shuffle started."
      return .result(
        dialog: IntentDialog(stringLiteral: dialog),
        view: IntentResultView(
          image: AmperfyImage.shuffle.asImage,
          displayString: dialog
        )
      )
    }
  }
}
