//
//  DownloadEntityIntent.swift
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

// MARK: - DownloadEntityResultView

struct DownloadEntityResultView: View {
  var displayString: String

  var body: some View {
    VStack {
      AmperfyImage.download.asImage
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

// MARK: - DownloadEntityIntent

struct DownloadEntityIntent: AppIntent {
  static let intentClassName = "DownloadEntityIntent"
  static let title: LocalizedStringResource = "Download ID"
  static let description = IntentDescription(
    "Downloads the library element with the given ID (all of its songs or episodes are pinned to the download queue)."
  )

  @Parameter(title: "ID")
  var id: String

  @Parameter(
    title: "Account",
    description: "Account used to search for ID. If not provided the active account will be used."
  )
  var account: AccountAppEntity?

  @Parameter(title: "Library Element Type", default: .song)
  var libraryElementType: PlayableContainerTypeAppEnum

  static var parameterSummary: some ParameterSummary {
    Summary("Download ID \(\.$id) of type \(\.$libraryElementType)") {
      \.$account
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
    guard let accountCoreData = appDelegate.intentManager.getAccount(fromIntent: account)
    else { throw AmperfyAppIntentError.accountNotValid }

    let playableContainer = appDelegate.intentManager.getPlayableContainer(
      account: accountCoreData,
      id: id,
      libraryElementType: libraryElementType
    )
    guard let playableContainer, !playableContainer.playables.isEmpty
    else { throw AmperfyAppIntentError.notFound }

    // pinned download — same path as the library UI's "Download" actions
    // (`download(objects:)` pins the tier, never evicted automatically)
    appDelegate.getMeta((playableContainer.account ?? accountCoreData).info)
      .playableDownloadManager.download(objects: playableContainer.playables)

    let dialog =
      "Added \(playableContainer.playables.count) items from \(playableContainer.name) to the download queue."
    return .result(
      dialog: IntentDialog(stringLiteral: dialog),
      view: DownloadEntityResultView(displayString: dialog)
    )
  }
}
