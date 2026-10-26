//
//  AmperfyAppShortcuts.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 08.01.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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
import UIKit

// MARK: - AmperfyAppShortcuts

struct AmperfyAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    // `AppShortcutsBuilder` historically surfaces at most 10 shortcuts —
    // entries beyond the cap are silently dropped, so this list is
    // curated to exactly 10: the eight highest-value originals plus
    // Sleep Timer and Play Mix. Repeat/Shuffle transport is covered by
    // the Home-Screen widgets; the AlbumShuffle/PlaybackRate/Download/
    // Dislike intents still exist, they simply have no shortcut phrase.
    //
    // Quick Actions
    //
    AppShortcut(
      intent: SetOnlineOfflineModeIntent(),
      phrases: [
        "Activate mode in \(.applicationName)",
        "Switch mode in \(.applicationName)",
        "Activate \(\.$mode) mode in \(.applicationName)",
        "Switch to \(\.$mode) mode in \(.applicationName)",
      ],
      shortTitle: "Switch Mode",
      systemImageName: "arrowshape.forward"
    )
    AppShortcut(
      intent: SwitchAccountIntent(),
      phrases: [
        "Switch account in \(.applicationName)",
        "Switch to \(\.$account) in \(.applicationName)",
        "Switch to \(\.$account) account in \(.applicationName)",
        "Activate \(\.$account) account in \(.applicationName)",
      ],
      shortTitle: "Switch Account",
      systemImageName: "person.circle.fill"
    )
    AppShortcut(
      intent: PlayRandomSongsIntent(),
      phrases: [
        "Play random songs in \(.applicationName)",
        "Play \(\.$filterOption) random songs in \(.applicationName)",
      ],
      shortTitle: "Play Random Songs",
      systemImageName: "shuffle"
    )
    AppShortcut(
      intent: ContinuePlaybackIntent(),
      phrases: [
        "Continue in \(.applicationName)",
        "Continue playback in \(.applicationName)",
        "Continue \(\.$playbackMode) in \(.applicationName)",
        "Continue \(\.$playbackMode) playback in \(.applicationName)",
      ],
      shortTitle: "Continue Playback",
      systemImageName: "play.house.fill"
    )
    //
    // Favorite / Rate
    //
    AppShortcut(
      intent: SetFavoriteForCurrentlyPlayingSongIntent(),
      phrases: [
        "Favorite song in \(.applicationName)",
        "Favorite current song in \(.applicationName)",
        "\(\.$isFavorite) in \(.applicationName)",
        "\(\.$isFavorite) song in \(.applicationName)",
      ],
      shortTitle: "Favorite Song",
      systemImageName: "heart"
    )
    AppShortcut(
      intent: SetRatingForCurrentlyPlayingSongIntent(),
      phrases: [
        "Change rating in \(.applicationName)",
        "Remove rating in \(.applicationName)",
        "Delete rating in \(.applicationName)",
        "Rate \(\.$rating) in \(.applicationName)",
        "Rate \(\.$rating) stars in \(.applicationName)",
        "Rate song \(\.$rating) in \(.applicationName)",
        "Rate song \(\.$rating) stars in \(.applicationName)",
        "Rate song with \(\.$rating) stars in \(.applicationName)",
        "Rate song with \(\.$rating) stars in \(.applicationName)",
        "Set rating to \(\.$rating) in \(.applicationName)",
        "Set rating to \(\.$rating) stars in \(.applicationName)",
        "Set song rating to \(\.$rating) in \(.applicationName)",
        "Set song rating to \(\.$rating) stars in \(.applicationName)",
        "Change rating to \(\.$rating) in \(.applicationName)",
        "Change rating to \(\.$rating) stars in \(.applicationName)",
        "Change song rating to \(\.$rating) in \(.applicationName)",
        "Change song rating to \(\.$rating) stars in \(.applicationName)",
      ],
      shortTitle: "Rate Song",
      systemImageName: "star"
    )
    //
    // Playback Shortcutes
    //
    AppShortcut(
      intent: PlayPausePlaybackIntent(),
      phrases: [
        "\(\.$playPauseMode) in \(.applicationName)",
        "\(\.$playPauseMode) playback in \(.applicationName)",
      ],
      shortTitle: "Play/Pause/Toggle",
      systemImageName: "playpause.fill"
    )
    AppShortcut(
      intent: NextPreviousTrackIntent(),
      phrases: [
        "Change track in \(.applicationName)",
        "Play \(\.$nextPreviousMode) in \(.applicationName)",
      ],
      shortTitle: "Change Track",
      systemImageName: "forward.fill"
    )
    //
    // Sleep Timer / Discovery
    //
    AppShortcut(
      intent: SleepTimerIntent(),
      phrases: [
        "Set sleep timer in \(.applicationName)",
        "Set sleep timer to \(\.$timerOption) in \(.applicationName)",
        "Turn off sleep timer in \(.applicationName)",
        "Cancel sleep timer in \(.applicationName)",
      ],
      shortTitle: "Sleep Timer",
      systemImageName: "moon.zzz"
    )
    AppShortcut(
      intent: PlayMixIntent(),
      phrases: [
        "Play a mix in \(.applicationName)",
        "Play \(\.$mixKind) in \(.applicationName)",
        "Play the \(\.$mixKind) mix in \(.applicationName)",
        "Start \(\.$mixKind) in \(.applicationName)",
      ],
      shortTitle: "Play Mix",
      systemImageName: "point.3.filled.connected.trianglepath.dotted"
    )
  }
}
