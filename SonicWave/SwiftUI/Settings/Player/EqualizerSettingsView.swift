//
//  EqualizerSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 19.07.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

import AVFoundation
import SonicWaveKit
import SwiftUI

// MARK: - EqualizerSettingsView

struct EqualizerSettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  @State
  private var eqSettingToEdit: EqualizerSetting?
  @State
  private var eqSettingNameSaved: String = ""
  @State
  private var eqSettingName: String = ""
  @State
  var eqSettingGains: [CGFloat] = EqualizerSetting.frequencies.map { _ in 0.0 }
  @State
  var sliderLabel: [String] = EqualizerSetting.frequencies.map {
    if $0 < 1000 {
      return "\(Int($0))"
    } else {
      return "\(Int($0 / 1000))k"
    }
  }

  @State
  var isShowDeleteAlert = false

  /// stable identity (portType:uid) of the output the route currently
  /// feeds — the key per-output EQ overrides map profile names to
  @State
  private var currentRouteKey: String?
  @State
  private var currentOutputName: String = ""

  /// the bundled AutoEQ-derived correction profiles — candidates for
  /// the active profile and per-output overrides; read through the
  /// facade so the kit stays the only store client
  private var autoEqProfiles: [ParametricEQSetting] {
    appDelegate.player.autoEqProfiles
  }

  /// the persisted active profile: a parametric selection supersedes
  /// the legacy graphic setting. Profile *names* are the stable
  /// cross-launch identity — the engine resolves per-route overrides
  /// by name and bundled AutoEQ profiles get fresh ids every launch
  private var activeProfileName: String {
    settings.activeParametricEqualizerSetting?.name
      ?? settings.activeEqualizerSetting.description
  }

  /// the override profile name mapped to the current output, if any
  private var currentRouteProfileName: String? {
    currentRouteKey.flatMap { settings.routeEqualizerProfileNames[$0] }
  }

  private func isGraphicProfileSelected(_ eqSetting: EqualizerSetting) -> Bool {
    guard settings.activeParametricEqualizerSetting == nil else { return false }
    if eqSetting == .off {
      // `.off`'s id is re-randomized every launch — a persisted off
      // selection never id-matches the runtime singleton, so its name
      // is the stable identity here
      return settings.activeEqualizerSetting.name == EqualizerSetting.off.name
    }
    return settings.activeEqualizerSetting == eqSetting
  }

  private func selectGraphicProfile(_ eqSetting: EqualizerSetting) {
    // clear first so the persisted parametric profile stops superseding
    // the graphic curve — the sinks apply the change to the engine
    settings.activeParametricEqualizerSetting = nil
    settings.activeEqualizerSetting = eqSetting
  }

  private func selectParametricProfile(_ profile: ParametricEQSetting) {
    settings.activeParametricEqualizerSetting = profile
  }

  private func setRouteProfile(_ profileName: String?) {
    guard let routeKey = currentRouteKey else { return }
    // persists the name map and pushes resolved overrides to the
    // engine in one call — then mirror the map back into the view state
    appDelegate.player.setRouteEqualizerProfile(profileName, forRouteKey: routeKey)
    settings.routeEqualizerProfileNames = appDelegate.player.routeEqualizerProfileNames
  }

  private func refreshCurrentOutputRoute() {
    currentRouteKey = appDelegate.player.currentOutputRouteKey
    currentOutputName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
      ?? String(
        localized: "Unknown Output",
        comment: "EQ settings: no audio output reported by the system"
      )
    settings.routeEqualizerProfileNames = appDelegate.player.routeEqualizerProfileNames
  }

  @ViewBuilder
  private func parametricProfileButton(_ profile: ParametricEQSetting) -> some View {
    Button {
      selectParametricProfile(profile)
    } label: {
      // name compare, not id — a persisted bundled profile keeps the id
      // it was saved with while the store decodes fresh ids each launch
      if settings.activeParametricEqualizerSetting?.name == profile.name {
        Label(profile.name, systemImage: "checkmark")
      } else {
        Text(profile.name)
      }
    }
  }

  @ViewBuilder
  private func routeProfileButton(_ profileName: String) -> some View {
    Button {
      setRouteProfile(profileName)
    } label: {
      if currentRouteProfileName == profileName {
        Label(profileName, systemImage: "checkmark")
      } else {
        Text(profileName)
      }
    }
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Enable Equalizer",
              isOn: Binding(
                get: { settings.isEqualizerEnabled },
                set: { isEnabled in
                  settings.isEqualizerEnabled = isEnabled
                }
              )
            )

            if settings.isEqualizerEnabled {
              SettingsRow(title: String(localized: "EQ Profile")) {
                Menu(activeProfileName) {
                  Button {
                    selectGraphicProfile(.off)
                  } label: {
                    if isGraphicProfileSelected(.off) {
                      Label(EqualizerSetting.off.description, systemImage: "checkmark")
                    } else {
                      Text(EqualizerSetting.off.description)
                    }
                  }

                  if !settings.equalizerSettings.isEmpty {
                    Section {
                      ForEach(settings.equalizerSettings, id: \.self) { eqSetting in
                        Button {
                          selectGraphicProfile(eqSetting)
                        } label: {
                          if isGraphicProfileSelected(eqSetting) {
                            Label(eqSetting.description, systemImage: "checkmark")
                          } else {
                            Text(eqSetting.description)
                          }
                        }
                      }
                    } header: {
                      Text(String(localized: "Graphic"))
                    }
                  }

                  if !settings.parametricEqualizerSettings.isEmpty {
                    Section {
                      ForEach(settings.parametricEqualizerSettings, id: \.self) { profile in
                        parametricProfileButton(profile)
                      }
                    } header: {
                      Text(String(localized: "Parametric"))
                    }
                  }

                  if !autoEqProfiles.isEmpty {
                    Section {
                      ForEach(autoEqProfiles, id: \.self) { profile in
                        parametricProfileButton(profile)
                      }
                    } header: {
                      Text(String(localized: "AutoEQ-style (approximate)"))
                    }
                  }
                }
              }
            }
          },
          footer:
          String(localized: "AutoEQ-style profiles provide approximate parametric corrections for specific headphones — representative values, not measured calibration. Parametric profiles can be selected but not edited.")
        )

        if settings.isEqualizerEnabled {
          SettingsSection(
            content: {
              SettingsRow(title: String(localized: "Current Output")) {
                SecondaryText(currentOutputName)
              }
              SettingsRow(title: String(localized: "EQ for This Output")) {
                Menu(
                  currentRouteProfileName
                    ?? String(localized: "Same as Active Profile")
                ) {
                  Button {
                    setRouteProfile(nil)
                  } label: {
                    if currentRouteProfileName == nil {
                      Label(
                        String(localized: "Same as Active Profile"),
                        systemImage: "checkmark"
                      )
                    } else {
                      Text(String(localized: "Same as Active Profile"))
                    }
                  }

                  if !settings.equalizerSettings.isEmpty {
                    Section {
                      ForEach(settings.equalizerSettings, id: \.self) { eqSetting in
                        routeProfileButton(eqSetting.name)
                      }
                    } header: {
                      Text(String(localized: "Graphic"))
                    }
                  }

                  if !settings.parametricEqualizerSettings.isEmpty {
                    Section {
                      ForEach(settings.parametricEqualizerSettings, id: \.self) { profile in
                        routeProfileButton(profile.name)
                      }
                    } header: {
                      Text(String(localized: "Parametric"))
                    }
                  }

                  if !autoEqProfiles.isEmpty {
                    Section {
                      ForEach(autoEqProfiles, id: \.self) { profile in
                        routeProfileButton(profile.name)
                      }
                    } header: {
                      Text(String(localized: "AutoEQ-style (approximate)"))
                    }
                  }
                }
                .disabled(currentRouteKey == nil)
              }
            },
            header: String(localized: "Per-Output EQ"),
            footer:
            String(localized: "Applies a different EQ profile to this audio output. The choice is remembered per device.")
          )
        }

        SettingsSection(content: {
          SettingsRow(title: "Equalizer") {
            Menu((eqSettingToEdit != nil) ? eqSettingNameSaved : "Select") {
              ForEach(settings.equalizerSettings, id: \.self) { eqSetting in
                Button(eqSetting.description) {
                  eqSettingToEdit = eqSetting
                  eqSettingName = eqSetting.name
                  eqSettingNameSaved = eqSetting.name
                  eqSettingGains = eqSetting.gains.compactMap { CGFloat($0) }
                }
              }
              Button("Create new Equalizer") {
                let newEQ = EqualizerSetting(name: "My new Equalizer")
                var curEqSetting = settings.equalizerSettings
                curEqSetting.append(newEQ)
                settings.equalizerSettings = curEqSetting
                eqSettingToEdit = newEQ
                eqSettingName = newEQ.name
                eqSettingNameSaved = newEQ.name
                eqSettingGains = newEQ.gains.compactMap { CGFloat($0) }
              }
            }
          }

          if eqSettingToEdit != nil {
            SettingsRow(title: "Name") {
              TextField("Equalizer Name", text: $eqSettingName)
                .multilineTextAlignment(.trailing)
            }

            EqualizerView(
              sliderLabels: $sliderLabel,
              sliderValues: $eqSettingGains,
              sliderTintColor: Color(settings.themePreference.asColor),
              gradientColors: [Color(settings.themePreference.asColor), .clear]
            )

            SettingsButtonRow(title: "Save") {
              guard var eqSettingToEdit else { return }
              var curEqSetting = settings.equalizerSettings
              guard let index = curEqSetting.firstIndex(of: eqSettingToEdit) else { return }
              eqSettingToEdit.name = eqSettingName
              eqSettingNameSaved = eqSettingName
              eqSettingToEdit.gains = eqSettingGains.compactMap { Float($0) }
              self.eqSettingToEdit = eqSettingToEdit
              curEqSetting[index] = eqSettingToEdit
              settings.equalizerSettings = curEqSetting

              if settings.activeEqualizerSetting == eqSettingToEdit {
                settings.activeEqualizerSetting = eqSettingToEdit
              }
            }
            SettingsButtonRow(title: "Delete", actionType: .destructive) {
              isShowDeleteAlert = true
            }.alert(isPresented: $isShowDeleteAlert) {
              Alert(
                title: Text("Delete Equalizer"),
                message: Text(
                  "Are you sure to delete this equalizer?"
                ),
                primaryButton: .destructive(Text("Delete")) {
                  guard let eqSettingToEdit else { return }
                  var curEqSetting = settings.equalizerSettings
                  guard let index = curEqSetting.firstIndex(of: eqSettingToEdit) else { return }
                  curEqSetting.remove(at: index)
                  settings.equalizerSettings = curEqSetting

                  if settings.activeEqualizerSetting == eqSettingToEdit {
                    settings.activeEqualizerSetting = .off
                  }

                  self.eqSettingToEdit = nil
                },
                secondaryButton: .cancel()
              )
            }
          }

        }, header: "Equalizer Editor")
      }
    }
    .navigationTitle("Equalizer")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshCurrentOutputRoute()
    }
    // headphone plug/unplug or AirPlay handoff changes the route —
    // republish the output row + its override mapping live
    .onReceive(
      NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
    ) { _ in
      refreshCurrentOutputRoute()
    }
  }
}

// MARK: - EqualizerSettingsView_Previews

struct EqualizerSettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    EqualizerSettingsView().environmentObject(settings)
  }
}
