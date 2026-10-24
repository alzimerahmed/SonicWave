//
//  ArtworkTintPalette.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 15.11.25.
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

import SonicWaveKit
import UIKit

// MARK: - ArtworkTintPalette

/// Resolved `sonicArtwork*` token set for one track (design-system §2.4):
/// the artwork's dominant colors drive the player background gradient,
/// the most saturated one becomes the control accent, and metadata text
/// uses a contrast color that never drops below 4.5:1 against the
/// primary stop.
///
/// `intensity` (the `artworkTintIntensity` account setting) decides how
/// much of the palette reaches the surface:
/// - `.off`    → `isArtworkTinted == false`, pure semantic background
/// - `.subtle` → two-stop gradient (primary → secondary), default
/// - `.vivid`  → up to four-stop gradient + accent-tinted controls
struct ArtworkTintPalette: Equatable {
  /// `sonicArtworkPrimary` — top gradient stop, hero surface color
  let primary: UIColor
  /// `sonicArtworkSecondary` — bottom gradient stop
  let secondary: UIColor
  /// `sonicArtworkAccent` — most saturated extracted color, HSL-clamped
  /// to lightness ∈ [0.35, 0.75]; progress tint + active control tint
  let accent: UIColor
  /// `sonicArtworkContrast` — black/white ≥4.5:1 vs `primary`, else
  /// `sonicHardLabel`; used for metadata text over the artwork gradient
  let contrast: UIColor
  /// black/white ≥4.5:1 vs `accent` — label color on accent-filled controls
  let accentContrast: UIColor
  /// gradient stops in display order (2 stops subtle, up to 4 vivid)
  let gradientColors: [UIColor]

  var isArtworkTinted: Bool {
    intensity != .off
  }

  let intensity: ArtworkTintIntensity

  /// accent lightness window per §2.4
  static let accentLightnessRange: ClosedRange<CGFloat> = 0.35 ... 0.75

  init(
    extractedColors: [UIColor],
    fallbackTheme: ThemePreference,
    intensity: ArtworkTintIntensity,
    isTrueBlack: Bool
  ) {
    self.intensity = intensity

    // fallback chain §2.4: dominant colors → theme accent + semantic bg
    let semanticBackground: UIColor = isTrueBlack ? .black : .systemBackground
    let extracted = extractedColors.isEmpty
      ? [fallbackTheme.asColor, semanticBackground]
      : extractedColors

    primary = extracted[0]
    secondary = extracted.count > 1 ? extracted[1] : semanticBackground

    let mostSaturated = extracted.max(by: {
      $0.sonicSaturationLightness.saturation < $1.sonicSaturationLightness.saturation
    }) ?? fallbackTheme.asColor
    accent = mostSaturated.sonicWithLightnessClamped(to: Self.accentLightnessRange)

    contrast = primary.sonicContrastColor
    accentContrast = accent.sonicContrastColor

    switch intensity {
    case .off:
      gradientColors = [semanticBackground, semanticBackground]
    case .subtle:
      gradientColors = [primary, secondary]
    case .vivid:
      // up to four stops: the full extracted set in dominance order,
      // padded with the semantic background when fewer resolve
      var stops = Array(extracted.prefix(4))
      while stops.count < 2 {
        stops.append(semanticBackground)
      }
      gradientColors = stops
    }
  }

  /// evenly spread locations for `gradientColors` ([0,1] for two stops)
  var gradientLocations: [NSNumber] {
    guard gradientColors.count > 1 else { return [0, 1] }
    return gradientColors.indices.map {
      NSNumber(value: Double($0) / Double(gradientColors.count - 1))
    }
  }
}
