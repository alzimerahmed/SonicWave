//
//  AccountSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

// MARK: - AccountSettingsView

struct AccountSettingsView: View {
  let splitPercentage = 0.25

  @State
  var isPwUpdateDialogVisible = false
  @State
  var isShowLogoutAlert = false
  @State
  var isShowResyncLibraryAlert = false
  @State
  private var publicUrlOverride: String = ""
  /// the account `publicUrlOverride` was loaded for — a stale field value
  /// must never be written into a freshly-switched account
  @State
  private var publicUrlOverrideAccountIdent: String?
  @EnvironmentObject
  var settings: Settings

  func setThemePreference(preference: ThemePreference) {
    settings.themePreference = preference
    appDelegate.setAppTheme(color: preference.asColor)
    appDelegate.applyAppThemeToAlreadyLoadedViews()
  }

  private func resyncLibrary(accountInfo: AccountInfo) {
    appDelegate.closeAllButActiveMainTabs()
    if appDelegate.storage.settings.accounts.allAccounts.count <= 1 {
      appDelegate.stopForInit()
    }

    let meta = appDelegate.getMeta(accountInfo)
    meta.stopManager()
    appDelegate.resetMeta(accountInfo)

    // reset quick actions
    appDelegate.quickActionsManager.configureQuickActions()
    appDelegate.configureMainMenu()

    appDelegate.storage.settings.user.isOfflineMode = false
    let account = appDelegate.storage.main.library.getAccount(info: accountInfo)
    appDelegate.player.logout(account: account)
    let syncVC = AppStoryboard.Main.segueToSync(account: account)
    syncVC.modalPresentationStyle = .formSheet
    AppDelegate.mainSceneDelegate?.window?.rootViewController?.dismiss(animated: false)
    AppDelegate.mainSceneDelegate?.window?.rootViewController?.present(syncVC, animated: true)
  }

  private func httpHeaders(accountInfo: AccountInfo) -> [String: String] {
    appDelegate.storage.settings.accounts.getSetting(accountInfo).read
      .loginCredentials?.httpHeaders ?? [:]
  }

  private func saveHTTPHeaders(_ headers: [String: String], accountInfo: AccountInfo) {
    appDelegate.storage.settings.accounts
      .updateSetting(accountInfo) { accountSettings in
        accountSettings.loginCredentials?.httpHeaders = headers
      }
    if let updatedCredentials = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read.loginCredentials {
      appDelegate.getMeta(accountInfo).backendApi
        .provideCredentials(credentials: updatedCredentials)
    }
  }

  /// G18: reverse-proxy base URL for share links — nil when blank so the
  /// server-provided URL is used as-is (`ShareUrlRewriter`). Saves only
  /// while the field still belongs to `accountInfo`.
  private func savePublicUrlOverride(accountInfo: AccountInfo) {
    guard publicUrlOverrideAccountIdent == accountInfo.ident else { return }
    let trimmed = publicUrlOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    appDelegate.storage.settings.accounts
      .updateSetting(accountInfo) { accountSettings in
        accountSettings.publicUrlOverride = trimmed.isEmpty ? nil : trimmed
      }
  }

  private func saveAllowUntrustedCertificates(_ allowUntrusted: Bool, accountInfo: AccountInfo) {
    appDelegate.storage.settings.accounts
      .updateSetting(accountInfo) { accountSettings in
        accountSettings.loginCredentials?.allowUntrustedServerCertificates = allowUntrusted
      }
    // re-provide so the session TLS policy picks up the flag immediately
    if let updatedCredentials = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read.loginCredentials {
      appDelegate.getMeta(accountInfo).backendApi
        .provideCredentials(credentials: updatedCredentials)
    }
  }

  private func logout(accountInfo: AccountInfo) {
    appDelegate.closeAllButActiveMainTabs()
    if appDelegate.storage.settings.accounts.allAccounts.count <= 1 {
      appDelegate.stopForInit()
    }

    let meta = appDelegate.getMeta(accountInfo)
    meta.stopManager()
    appDelegate.resetMeta(accountInfo)

    // delete cached files
    CacheFileManager.shared.deleteAccountCache(accountInfo: accountInfo)
    // purge the account's Spotlight index domain now — its CoreData rows
    // are only removed by the next-launch cleanup, so entity-level
    // deletes can't carry this
    Task {
      await AmperKit.shared.spotlightIndexer
        .deleteItems(forAccountIdent: accountInfo.ident)
    }
    // same seam for the shared widget artifacts — the signed-out
    // account's now-playing/recent entries must not stay on the
    // Home/Lock Screen
    Task { @MainActor in
      WidgetBridge.purgeSharedState()
    }
    // reset login credentials -> at new start the login view is presented to auth and resync library
    appDelegate.storage.settings.accounts.logout(accountInfo)
    appDelegate.notificationHandler.post(name: .accountDeleted, object: nil, userInfo: nil)
    appDelegate.notificationHandler.post(name: .accountActiveChanged, object: nil, userInfo: nil)

    // reset quick actions
    appDelegate.quickActionsManager.configureQuickActions()
    appDelegate.configureMainMenu()

    appDelegate.storage.settings.user.isOfflineMode = false
    let account = appDelegate.storage.main.library.getAccount(info: accountInfo)
    appDelegate.player.logout(account: account)
    if let newActiveAccountInfo = appDelegate.storage.settings.accounts.active {
      let newActiveAccount = appDelegate.storage.main.library.getAccount(info: newActiveAccountInfo)
      appDelegate.closeAllButActiveMainTabs()
      appDelegate
        .setAppTheme(
          color: appDelegate.storage.settings.accounts.getSetting(newActiveAccountInfo)
            .read.themePreference.asColor
        )
      appDelegate.applyAppThemeToAlreadyLoadedViews()
      guard let mainScene = AppDelegate.mainSceneDelegate else { return }
      mainScene
        .replaceMainRootViewController(
          vc: AppStoryboard.Main
            .segueToMainWindow(account: newActiveAccount)
        )
    } else {
      // No other account: Behave like initial App start
      // force resync after login
      appDelegate.storage.settings.app.isLibrarySynced = false
      let loginVC = AppStoryboard.Main.segueToLogin()
      AppDelegate.mainSceneDelegate?.replaceMainRootViewController(vc: loginVC)
    }
  }

  var body: some View {
    ZStack {
      SettingsList {
        if let activeAccountInfo = settings.activeAccountInfo {
          SettingsSection {
            SettingsRow(title: "URL", orientation: .vertical, splitPercentage: splitPercentage) {
              SecondaryText(
                appDelegate.storage.settings.accounts.getSetting(settings.activeAccountInfo).read
                  .loginCredentials?.displayServerUrl ?? ""
              )
            }
            SettingsRow(
              title: "Username",
              orientation: .vertical,
              splitPercentage: splitPercentage
            ) {
              SecondaryText(
                appDelegate.storage.settings.accounts.getSetting(settings.activeAccountInfo).read
                  .loginCredentials?.username ?? ""
              )
            }
          }

          SettingsSection {
            SettingsRow(title: "Theme Color") {
              Menu(settings.themePreference.description) {
                Button(ThemePreference.blue.description) {
                  setThemePreference(preference: .blue)
                }
                Button(ThemePreference.green.description) {
                  setThemePreference(preference: .green)
                }
                Button(ThemePreference.red.description) {
                  setThemePreference(preference: .red)
                }
                Button(ThemePreference.yellow.description) {
                  setThemePreference(preference: .yellow)
                }
                Button(ThemePreference.orange.description) {
                  setThemePreference(preference: .orange)
                }
                Button(ThemePreference.purple.description) {
                  setThemePreference(preference: .purple)
                }
              }
            }
          }

          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Newest Songs",
                isOn: $settings.isAutoCacheLatestSongs
              )
              SettingsCheckBoxRow(
                title: "Newest Podcast Episodes",
                isOn: $settings.isAutoCacheLatestPodcastEpisodes
              )
              SettingsCheckBoxRow(
                title: "Favorite Songs and Albums",
                isOn: $settings.isAutoDownloadFavorites
              )
            },
            footer:
            "Favorites are kept downloaded permanently. To keep a playlist downloaded, open its ⋯ menu and enable “Download New Songs”.",
            header: "Auto Download"
          )

          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Play Queue",
                isOn: $settings.isPlayQueueSyncActive
              )
            },
            footer:
            "Saves your play queue to the server and restores newer changes from it. Not supported by all servers.",
            header: "Sync with Server"
          )

          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Scrobble streamed Songs",
                isOn: $settings.isScrobbleStreamedItems
              )
            },
            footer: "Enable to scrobble all streamed songs, even if the server already marks them as played."
          )

          SettingsSection {
            SettingsRow(title: "Backend API", splitPercentage: splitPercentage) {
              Text(
                appDelegate.storage.settings.accounts.getSetting(settings.activeAccountInfo).read
                  .loginCredentials?
                  .backendApi.description ?? ""
              )
              .foregroundColor(.secondary)
              .help(
                appDelegate.storage.settings.accounts.getSetting(settings.activeAccountInfo).read
                  .loginCredentials?
                  .backendApi.description ?? ""
              )
            }

            SettingsRow(title: "Server API Version", splitPercentage: splitPercentage) {
              Text(appDelegate.getMeta(activeAccountInfo).backendApi.serverApiVersion)
                .foregroundColor(.secondary)
                .help(appDelegate.getMeta(activeAccountInfo).backendApi.serverApiVersion)
            }
            SettingsRow(title: "Client API Version", splitPercentage: splitPercentage) {
              Text(appDelegate.getMeta(activeAccountInfo).backendApi.clientApiVersion)
                .foregroundColor(.secondary)
                .help(appDelegate.getMeta(activeAccountInfo).backendApi.clientApiVersion)
            }
          }

          SettingsSection(
            content: {
              SettingsRow(title: "Public URL Override", orientation: .vertical) {
                TextField(
                  "https://music.example.com",
                  text: $publicUrlOverride
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                // save on submit/leave — a per-keystroke write rewrites
                // the setting (and every share URL rewrite) mid-typing
                .onSubmit { savePublicUrlOverride(accountInfo: activeAccountInfo) }
                .onDisappear { savePublicUrlOverride(accountInfo: activeAccountInfo) }
              }
              NavigationLink(destination: MusicFolderSettingsView(accountInfo: activeAccountInfo)) {
                Label("Music Folder", systemImage: "folder")
              }
              NavigationLink(destination: LidarrSettingsView(accountInfo: activeAccountInfo)) {
                Label("Lidarr", systemImage: "antenna.radiowaves.left.and.right")
              }
              NavigationLink(destination: SharesSettingsView(accountInfo: activeAccountInfo)) {
                Text("Manage Shares")
              }
            },
            header: "Sharing",
            footer:
            "For servers behind a reverse proxy — links are generated from this base URL."
          )

          SettingsSection {
            NavigationLink(destination: ServerURLsSettingsView()) {
              Text("Manage Server URLs")
            }
            NavigationLink(destination: CustomHTTPHeadersView(
              headers: httpHeaders(accountInfo: activeAccountInfo)
            ) { updated in
              saveHTTPHeaders(updated, accountInfo: activeAccountInfo)
            }) {
              Text("Custom HTTP Headers")
            }
            NavigationLink(destination: ConnectionSecurityView(
              accountIdent: { activeAccountInfo.ident },
              allowUntrusted: appDelegate.storage.settings.accounts
                .getSetting(activeAccountInfo).read
                .loginCredentials?.allowUntrustedServerCertificates ?? false
            ) { newValue in
              saveAllowUntrustedCertificates(newValue, accountInfo: activeAccountInfo)
            }) {
              Text("Connection Security")
            }
          }

          SettingsSection {
            SettingsButtonRow(title: "Update Password") {
              withPopupAnimation { isPwUpdateDialogVisible = true }
            }
            SettingsButtonRow(title: "Resync Library") {
              isShowResyncLibraryAlert = true
            }.alert(isPresented: $isShowResyncLibraryAlert) {
              Alert(
                title: Text("Resync Library"),
                message: Text(
                  "This will reset your local library and start syncing again from the server. Your downloaded files will remain on this device.\n\nDo you want to resync your library?"
                ),
                primaryButton: .destructive(Text("Resync")) {
                  resyncLibrary(accountInfo: activeAccountInfo)
                },
                secondaryButton: .cancel()
              )
            }
          }

          SettingsSection {
            SettingsButtonRow(title: "Logout", actionType: .destructive) {
              isShowLogoutAlert = true
            }
            .alert(isPresented: $isShowLogoutAlert) {
              Alert(
                title: Text("Logout"),
                message: Text(
                  "Logging out will sign you out of the current account. Your login credentials will be removed, and all downloaded files for this account will be deleted.\n\nDo you want to log out?"
                ),
                primaryButton: .destructive(Text("Logout")) {
                  logout(accountInfo: activeAccountInfo)
                },
                secondaryButton: .cancel()
              )
            }
          }
        } else {
          // User is not logged in yet
          SettingsSection {
            SecondaryText("You aren't logged in yet.")
          }
        }
      }
    }
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $isPwUpdateDialogVisible) {
      UpdatePasswordView(isVisible: $isPwUpdateDialogVisible)
    }
    .onAppear {
      if let accountInfo = settings.activeAccountInfo {
        publicUrlOverride = appDelegate.storage.settings.accounts
          .getSetting(accountInfo).read.publicUrlOverride ?? ""
        publicUrlOverrideAccountIdent = accountInfo.ident
      }
    }
    .onDisappear {
      if let accountInfo = settings.activeAccountInfo {
        savePublicUrlOverride(accountInfo: accountInfo)
      }
    }
  }
}

// MARK: - AccountSettingsView_Previews

struct AccountSettingsView_Previews: PreviewProvider {
  static var previews: some View {
    AccountSettingsView()
  }
}
