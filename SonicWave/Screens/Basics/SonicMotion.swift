//
//  SonicMotion.swift
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

// MARK: - SonicMotion

/// Single routing point for `UIView.animate` in the player surface
/// (design-system §6): motion durations live here, and every animation
/// runs instantly — the `animations` block is applied without a
/// transition — when Reduce Motion is enabled. Crossfades stay
/// opacity-only under Reduce Motion per the spec's mapping.
enum SonicMotion {
  /// popup/sheet transitions, cell focus flash, display-style switch
  static let popupTransitionDuration: TimeInterval = 0.2
  /// artwork-gradient crossfade on track change (`AnimatedGradientLayer`)
  static let artworkCrossfadeDuration: TimeInterval = 2.0
  /// grace period before a still-unresolved lyrics lookup swaps the
  /// lyrics pane from its loading state to the empty state
  static let lyricsResolveGracePeriod: TimeInterval = 1.2

  static var isReduceMotionEnabled: Bool {
    UIAccessibility.isReduceMotionEnabled
  }

  /// `UIView.animate` that applies the change instantly under Reduce Motion
  @MainActor
  static func animate(
    withDuration duration: TimeInterval,
    delay: TimeInterval = 0,
    options: UIView.AnimationOptions = [],
    animations: @escaping () -> (),
    completion: ((Bool) -> ())? = nil
  ) {
    if isReduceMotionEnabled {
      animations()
      completion?(true)
      return
    }
    UIView.animate(
      withDuration: duration,
      delay: delay,
      options: options,
      animations: animations,
      completion: completion
    )
  }

  /// Smooth-scroll flag: `isLyricsSmoothScrolling` setting AND not
  /// Reduce Motion — under Reduce Motion lyric jumps are instant.
  @MainActor
  static var isLyricsSmoothScrollingAllowed: Bool {
    appDelegate.storage.settings.user.isLyricsSmoothScrolling && !isReduceMotionEnabled
  }

  @MainActor
  private static var appDelegate: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }
}
