//
//  WidgetViews.swift
//  SonicWaveWidgets
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

import SwiftUI
import UIKit

// MARK: - WidgetTheme

/// Accent mapping for the `themeName` carried inside `WidgetState` /
/// `PlaybackActivityAttributes` — the widget can't read app-private
/// settings, so the account's `ThemePreference` arrives as a name
/// (design-system §2.1: tint only, six named system colors).
enum WidgetTheme {
  static func color(name: String?) -> Color {
    switch name {
    case "green":
      return .green
    case "red":
      return .red
    case "yellow":
      return .yellow
    case "orange":
      return .orange
    case "purple":
      return .purple
    default:
      return .blue
    }
  }
}

// MARK: - WidgetMetrics

/// widget-side mirror of the design-system tokens that apply here —
/// artwork radius is 5pt everywhere (§4.2), cell gutter 16 (§4.1)
enum WidgetMetrics {
  static let artworkCornerRadius: CGFloat = 5
  static let cellGutter: CGFloat = 16
  /// ≥44pt interactive targets (design-system §8.6)
  static let transportTarget: CGFloat = 44
}

// MARK: - WidgetArtworkView

/// Artwork or themed placeholder — a bare gray box is design-system slop
/// (§9); the fallback mirrors `getGeneratedArtwork`: theme-tinted SF glyph
/// on a soft theme wash.
struct WidgetArtworkView: View {
  let fileName: String?
  let themeColor: Color

  var body: some View {
    if let fileName,
       let url = WidgetStore.artworkURL(fileName: fileName),
       let image = UIImage(contentsOfFile: url.path) {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .clipShape(
          RoundedRectangle(
            cornerRadius: WidgetMetrics.artworkCornerRadius
          )
        )
    } else {
      ZStack {
        themeColor.opacity(0.15)
        Image(systemName: "music.note")
          .font(.title2)
          .foregroundStyle(themeColor)
      }
      .clipShape(
        RoundedRectangle(
          cornerRadius: WidgetMetrics.artworkCornerRadius
        )
      )
    }
  }
}

// MARK: - subtitle helper

extension WidgetNowPlaying {
  /// "Artist — Album" with empty parts dropped; radios fall back to the
  /// context name so the line is never blank
  var metadataSubtitle: String {
    let parts = [artist, album].filter { !$0.isEmpty }
    if !parts.isEmpty {
      return parts.joined(separator: " — ")
    }
    return contextName
  }

  /// static "m:ss" for the paused state (timerInterval views handle the
  /// playing case locally)
  var remainingTimeDescription: String {
    let remaining = max(duration - elapsedSeconds, 0)
    let minutes = Int(remaining) / 60
    let seconds = Int(remaining) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
