//
//  IntentResultView.swift
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

// MARK: - IntentResultView

/// Shared snippet view for intent results — one themed glyph plus the
/// dialog text. Replaces the per-intent `XxxResultView` boilerplate,
/// which was byte-identical except for the icon.
struct IntentResultView: View {
  var image: Image
  var displayString: String

  var body: some View {
    VStack {
      image
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
