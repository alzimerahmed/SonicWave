//
//  LidarrSettingsView.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 27.02.26.
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
import SwiftUI

// MARK: - LidarrSettingsView

/// G25: Lidarr connection settings — base URL + API key. The key is a
/// secret: it goes to Keychain (`LidarrKeychain`), never to UserDefaults.
/// With both set, artist menus gain "Request in Lidarr".
struct LidarrSettingsView: View {
  let accountInfo: AccountInfo

  @State
  private var baseUrl = ""
  @State
  private var apiKey = ""
  /// the account the fields were loaded for — a stale field value must
  /// never be written into a freshly-switched account (same guard as
  /// publicUrlOverride on AccountSettingsView)
  @State
  private var loadedAccountIdent: String?

  private func save() {
    guard loadedAccountIdent == accountInfo.ident else { return }
    let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    appDelegate.storage.settings.accounts
      .updateSetting(accountInfo) { accountSettings in
        accountSettings.lidarrUrl = trimmed.isEmpty ? nil : trimmed
      }
    // whitespacesAndNewlines — a pasted key keeps a trailing newline
    // otherwise and silently fails auth
    let status = LidarrKeychain.save(
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      accountIdent: accountInfo.ident
    )
    if status != errSecSuccess {
      appDelegate.eventLogger.info(
        topic: "Lidarr",
        message: "Couldn't store the API key in Keychain (status \(status)).",
        displayPopup: false
      )
    }
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(
          content: {
            SettingsRow(
              title: String(localized: "Server URL", comment: "Lidarr settings row"),
              orientation: .vertical
            ) {
              TextField("http://nas:8686", text: $baseUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit { save() }
            }
            SettingsRow(
              title: String(localized: "API Key", comment: "Lidarr settings row"),
              orientation: .vertical
            ) {
              SecureField(
                String(localized: "Lidarr Settings → General → API Key", comment: "Lidarr API key field placeholder"),
                text: $apiKey
              )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { save() }
            }
          },
          footer: String(
            localized: "Found under Settings → General → Security in Lidarr. The key is stored in Keychain, not in settings. With both fields set, artist menus get a “Request in Lidarr” action.",
            comment: "Lidarr settings footer"
          )
        )
      }
    }
    .navigationTitle("Lidarr")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      baseUrl = appDelegate.storage.settings.accounts
        .getSetting(accountInfo).read.lidarrUrl ?? ""
      apiKey = LidarrKeychain.apiKey(accountIdent: accountInfo.ident) ?? ""
      loadedAccountIdent = accountInfo.ident
    }
    .onDisappear { save() }
  }
}
