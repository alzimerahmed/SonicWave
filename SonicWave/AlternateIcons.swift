//
//  AlternateIcons.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 17.11.25.
//  Copyright (c) 2025 Alzimer Ahmed. All rights reserved.
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

import UIKit

// MARK: - AppIconManager

/// G24 — alternate app icon mechanism: reads the alternates declared
/// under `CFBundleIcons`/`CFBundleAlternateIcons` in the bundle and
/// applies a choice via `UIApplication.setAlternateIconName`.
/// TODO(G24): produce alternate Icon Composer assets (`.icon` variants
/// of `SonicWaveAppIcon.icon` — Icon Composer is macOS-only) and declare
/// them under `CFBundleAlternateIcons` in Info.plist. Until then
/// `alternateIcons` is empty and the settings picker row stays hidden.
enum AppIconManager {
  static var isSupported: Bool {
    #if targetEnvironment(macCatalyst) // ok
      return false
    #else
      return UIApplication.shared.supportsAlternateIcons
    #endif
  }

  /// names of the configured alternate icons (empty until assets ship)
  static var alternateIcons: [String] {
    guard isSupported,
          let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
          let alternates = icons["CFBundleAlternateIcons"] as? [String: Any]
    else { return [] }
    return alternates.keys.sorted()
  }

  /// name of the active alternate icon, nil when the primary icon is set
  static var activeIconName: String? {
    #if targetEnvironment(macCatalyst) // ok
      return nil
    #else
      return UIApplication.shared.alternateIconName
    #endif
  }

  static func setIcon(named name: String?) {
    #if !targetEnvironment(macCatalyst) // ok
      guard isSupported else { return }
      UIApplication.shared.setAlternateIconName(name) { error in
        guard let error else { return }
        (UIApplication.shared.delegate as? AppDelegate)?.eventLogger
          .report(topic: "App Icon", error: error)
      }
    #endif
  }
}
