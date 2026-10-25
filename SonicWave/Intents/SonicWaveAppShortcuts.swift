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
    // Change Repeat / Shuffle
    //
    AppShortcut(
      intent: SetRepeatIntent(),
      phrases: [
        "Change repeat in \(.applicationName)",
        "Set repeat \(\.$repeatMode) in \(.applicationName)",
        "Set repeat mode to \(\.$repeatMode) in \(.applicationName)",
        "Activate repeat \(\.$repeatMode) in \(.applicationName)",
      ],
      shortTitle: "Change Repeat",
      systemImageName: "repeat"
    )
    AppShortcut(
      intent: SetShuffleIntent(),
      phrases: [
        "Shuffle in \(.applicationName)",
        "Change shuffle in \(.applicationName)",
        "Shuffle \(\.$isShuffle) in \(.applicationName)",
        "Change shuffle \(\.$isShuffle) in \(.applicationName)",
        "Change shuffle to \(\.$isShuffle) in \(.applicationName)",
        "Change shuffle mode to \(\.$isShuffle) in \(.applicationName)",
        "Set shuffle \(\.$isShuffle) in \(.applicationName)",
        "Set shuffle to \(\.$isShuffle) in \(.applicationName)",
        "Set shuffle mode to \(\.$isShuffle) in \(.applicationName)",
      ],
      shortTitle: "Change Shuffle",
      systemImageName: "shuffle"
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
    // Sleep Timer / Playback Rate
    //
    AppShortcut(
      intent: SleepTimerIntent(),
      phrases: [
        "Set sleep timer in \(.applicationName)",
        "Set sleep timer to \(\.$timerOption) in \(.applicationName)",
        "Turn off sleep timer in \(.applicationName)",
        "Cancel sleep timer in \(.applicationName)",
        "Stop playback in \(\.$timerOption) in \(.applicationName)",
      ],
      shortTitle: "Sleep Timer",
      systemImageName: "moon.zzz"
    )
    AppShortcut(
      intent: SetPlaybackRateIntent(),
      phrases: [
        "Set playback rate in \(.applicationName)",
        "Set playback rate to \(\.$rate) in \(.applicationName)",
        "Change playback speed to \(\.$rate) in \(.applicationName)",
        "Change playback rate to \(\.$rate) in \(.applicationName)",
      ],
      shortTitle: "Playback Rate",
      systemImageName: "gauge.open.with.lines.needle.33percent"
    )
    //
    // Discovery / Album Shuffle
    //
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
    AppShortcut(
      intent: StartAlbumShuffleIntent(),
      phrases: [
        "Shuffle albums in \(.applicationName)",
        "Start album shuffle in \(.applicationName)",
        "Play album radio in \(.applicationName)",
        "Shuffle my albums in \(.applicationName)",
      ],
      shortTitle: "Shuffle Albums",
      systemImageName: "shuffle"
    )
    //
    // Library Maintenance
    //
    AppShortcut(
      intent: DownloadEntityIntent(),
      phrases: [
        "Download an item by ID in \(.applicationName)",
        "Download \(\.$libraryElementType) with ID \(\.$id) in \(.applicationName)",
      ],
      shortTitle: "Download ID",
      systemImageName: "arrow.down.circle"
    )
    AppShortcut(
      intent: SetDislikeForCurrentlyPlayingSongIntent(),
      phrases: [
        "Dislike song in \(.applicationName)",
        "Dislike current song in \(.applicationName)",
        "Dislike this song in \(.applicationName)",
      ],
      shortTitle: "Dislike Song",
      systemImageName: "hand.thumbsdown"
    )
  }
}
