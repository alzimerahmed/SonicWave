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

  /// Contrast-safe tint for icon-only interactive glyphs (transport
  /// buttons). The raw theme colors fail the 3:1 non-text contrast bar
  /// on the light `WidgetBackground` (#F2F2F7) — .yellow 1.6:1,
  /// .orange 2.0:1, .green 2.2:1 — so interactive controls fall back to
  /// `.primary` in light appearance; the dark background (#1C1C1E) is
  /// fine and keeps the theme accent. Decorative tints keep using
  /// `color(name:)`.
  static func interactiveColor(
    name: String?,
    for colorScheme: ColorScheme
  ) -> Color {
    colorScheme == .light ? .primary : color(name: name)
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
  /// safety-net timeline refresh while the app is alive — the state's
  /// `Date` anchors keep progress ticking between publishes
  static let timelineReloadInterval: TimeInterval = 30 * 60
  /// artwork edge sizes per surface
  /// systemMedium Now Playing widget
  static let artworkMedium: CGFloat = 56
  /// Live Activity Lock Screen card
  static let artworkLockScreen: CGFloat = 52
  /// Dynamic Island expanded region
  static let artworkIslandExpanded: CGFloat = 48
  /// systemSmall Now Playing widget + empty states
  static let artworkSmall: CGFloat = 44
  /// Recently Played rows + empty state
  static let artworkRow: CGFloat = 40
  /// Dynamic Island compact region
  static let artworkIslandCompact: CGFloat = 20
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
}
