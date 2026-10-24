//
//  DisplaySettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 30.12.23.
//  Copyright (c) 2023 Maximilian Bauer. All rights reserved.
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

// MARK: - DisplaySettingsView

struct DisplaySettingsView: View {
  @EnvironmentObject
  private var settings: Settings
  @State
  private var activeIconName: String? = AppIconManager.activeIconName

  func setAppearanceMode(style: UIUserInterfaceStyle) {
    settings.appearanceMode = style
    appDelegate.setAppAppearanceMode(style: style)
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection {
          SettingsRow(title: "Appearance") {
            Menu(
              settings.appearanceMode == .unspecified ? "System" :
                (settings.appearanceMode == .light ? "Light" : "Dark")
            ) {
              Button("System") {
                setAppearanceMode(style: .unspecified)
              }
              Button("Light") {
                setAppearanceMode(style: .light)
              }
              Button("Dark") {
                setAppearanceMode(style: .dark)
              }
            }
          }
        }

        SettingsSection(
          content: {
            SettingsRow(title: "Black Mode") {
              Menu(settings.blackModePreference.description) {
                ForEach(BlackModePreference.allCases, id: \.self) { preference in
                  Button {
                    settings.blackModePreference = preference
                  } label: {
                    if settings.blackModePreference == preference {
                      Label(preference.description, systemImage: "checkmark")
                    } else {
                      Text(preference.description)
                    }
                  }
                }
              }
            }
          },
          footer:
          "Dark forces the dark interface. True Black shows pure black surfaces in dark mode — saves battery on OLED screens."
        )

        if settings.activeAccountInfo != nil {
          SettingsSection(
            content: {
              SettingsRow(title: "Artwork Tint") {
                Menu(settings.artworkTintIntensity.description) {
                  ForEach(ArtworkTintIntensity.allCases, id: \.self) { intensity in
                    Button {
                      settings.artworkTintIntensity = intensity
                    } label: {
                      if settings.artworkTintIntensity == intensity {
                        Label(intensity.description, systemImage: "checkmark")
                      } else {
                        Text(intensity.description)
                      }
                    }
                  }
                }
              }
            },
            footer:
            "How strongly the Now Playing background takes on the current artwork's colors. Stored per account."
          )
        }

        #if !targetEnvironment(macCatalyst)
          SettingsSection(
            content: {
              SettingsCheckBoxRow(title: "Haptic Feedback", isOn: $settings.isHapticsEnabled)
            },
            footer:
            "Certain interactions provide haptic feedback. Long pressing to display the details menu will always trigger haptic feedback."
          )
        #endif

        #if targetEnvironment(macCatalyst)
          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Mini Player Always on Top",
                isOn: $settings.isMiniPlayerAlwaysOnTop
              )
            },
            footer:
            "Keep the mini player window floating above all other windows."
          )
        #endif

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Music Player Skip Buttons",
              isOn: $settings.isShowMusicPlayerSkipButtons
            )
          },
          footer:
          "Add skip forward and skip backward buttons to the music player, along with the previous/next buttons."
        )

        if let activeAccountInfo = settings.activeAccountInfo,
           let credentials = appDelegate.storage.settings.accounts.getSetting(activeAccountInfo)
           .read.loginCredentials,
           credentials.backendApi.asServerApiType != .ampache {
          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Lyrics Smooth Scrolling",
                isOn: $settings.isLyricsSmoothScrolling
              )
            },
            footer:
            "Lyrics are smoothly scrolled to next line. Deactivating will result in jumping from line to line."
          )

          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Synced Lyrics Online Lookup",
                isOn: $settings.isSyncedLyricsExternalLookupActive
              )
            },
            footer:
            "When the server has no synced lyrics, title, artist, album, and duration of the current track are sent to lrclib.net — only while online, never your account data."
          )
        }

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Detailed Information",
              isOn: $settings.isShowDetailedInfo
            )
          },
          footer:
          "Display detailed information (bitrate, ID) and button \"Copy ID to Clipboard\"."
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Song Duration", isOn: $settings.isShowSongDuration)
          },
          footer:
          "Display song duration in table rows."
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Album Duration", isOn: $settings.isShowAlbumDuration)
          },
          footer:
          "Display album duration in table rows."
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Artist Duration", isOn: $settings.isShowArtistDuration)
          },
          footer:
          "Display artist duration in table rows."
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Show Star Rating", isOn: $settings.isShowRating)
          },
          footer:
          "Display star rating in song cells and the currently playing view."
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Disable Player Shuffle Button",
              isOn: Binding<Bool>(
                get: { !settings.isPlayerShuffleButtonEnabled },
                set: {
                  settings.isPlayerShuffleButtonEnabled = !$0
                  UIMenuSystem.main.setNeedsRebuild()
                }
              )
            )
          },
          footer:
          "The player shuffle button is displayed but non-interactive."
        )

        // hidden until alternate Icon Composer assets ship and are
        // declared under `CFBundleAlternateIcons` — see `AppIconManager`
        if AppIconManager.isSupported, !AppIconManager.alternateIcons.isEmpty {
          SettingsSection(
            content: {
              SettingsRow(title: "App Icon") {
                Menu(activeIconName ?? "Default") {
                  Button {
                    AppIconManager.setIcon(named: nil)
                    activeIconName = nil
                  } label: {
                    if activeIconName == nil {
                      Label("Default", systemImage: "checkmark")
                    } else {
                      Text("Default")
                    }
                  }
                  ForEach(AppIconManager.alternateIcons, id: \.self) { iconName in
                    Button {
                      AppIconManager.setIcon(named: iconName)
                      activeIconName = iconName
                    } label: {
                      if activeIconName == iconName {
                        Label(iconName, systemImage: "checkmark")
                      } else {
                        Text(iconName)
                      }
                    }
                  }
                }
              }
            },
            footer:
            "Choose an alternate Home Screen icon."
          )
        }
      }
    }
    .navigationTitle("Display")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - DisplaySettingsView_Previews

struct DisplaySettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    DisplaySettingsView().environmentObject(settings)
  }
}
