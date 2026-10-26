//
//  MusicFolderSettingsView.swift
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

// MARK: - MusicFolderSettingsView

/// G23: scopes the account's library to one server music folder
/// (`musicFolderId` on getArtists/getAlbumList2/getRandomSongs).
/// Subsonic only — `.notSupported` renders an honest explanation.
/// The filter applies at sync time: a resync is required, the footer
/// points at it instead of silently half-filtering the mirror.
struct MusicFolderSettingsView: View {
  enum LoadState {
    case loading
    case loaded([MusicFolderStub])
    case notSupported
    case failed
  }

  let accountInfo: AccountInfo

  @State
  private var loadState: LoadState = .loading
  @State
  private var selectedId: String?

  private var backendApi: BackendApi {
    appDelegate.getMeta(accountInfo).backendApi
  }

  private func select(_ id: String?) {
    selectedId = id
    appDelegate.storage.settings.accounts
      .updateSetting(accountInfo) { accountSettings in
        accountSettings.musicFolderId = id
      }
  }

  var body: some View {
    ZStack {
      SettingsList {
        switch loadState {
        case .loading:
          SettingsSection {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          }
        case .notSupported:
          SettingsSection {
            SecondaryText("Music folders are not supported by this server.")
          }
        case .failed:
          SettingsSection {
            SecondaryText("Couldn't load music folders. Check the connection and try again.")
          }
        case .loaded(let folders):
          if folders.count <= 1 {
            SettingsSection {
              SecondaryText("This server exposes only one music folder — nothing to select.")
            }
          } else {
            SettingsSection(
              content: {
                ForEach([MusicFolderStub(id: "", name: "All Folders")] + folders) { folder in
                  Button {
                    select(folder.id.isEmpty ? nil : folder.id)
                  } label: {
                    HStack {
                      Text(folder.name)
                      Spacer()
                      if (folder.id.isEmpty && selectedId == nil) || folder.id == selectedId {
                        Image(systemName: "checkmark")
                          .foregroundColor(.accentColor)
                      }
                    }
                  }
                  .foregroundColor(.primary)
                }
              },
              footer: "The library shows only this folder after the next resync — use Resync Library on the Account screen to apply it now. Search and genres stay server-wide; the folder list itself is browsable under Directories."
            )
          }
        }
      }
    }
    .navigationTitle("Music Folder")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      selectedId = appDelegate.storage.settings.accounts
        .getSetting(accountInfo).read.musicFolderId
      Task { @MainActor in
        do {
          switch try await backendApi.getMusicFolders() {
          case .supported(let folders): loadState = .loaded(folders)
          case .notSupported: loadState = .notSupported
          }
        } catch {
          appDelegate.eventLogger.report(topic: "Music Folders", error: error)
          loadState = .failed
        }
      }
    }
  }
}
