//
//  PlaybackActivityAttributes.swift
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

import Foundation

#if canImport(ActivityKit)
  import ActivityKit

  // MARK: - PlaybackActivityAttributes

  /// Live Activity payload (G13). Compiled into BOTH the app and the
  /// widget extension (dual target membership) — Apple's standard
  /// ActivityKit pattern; ActivityKit matches attributes across processes
  /// by name + Codable shape, not by module identity.
  ///
  /// `ContentState.elapsedAnchor` carries a `Date` so elapsed/progress
  /// renders via `Text(timerInterval:)`/`ProgressView(timerInterval:)`
  /// without per-second activity updates — the battery-correct pattern,
  /// which is why the app does NOT declare
  /// `NSSupportsLiveActivitiesFrequentUpdates`.
  struct PlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
      public var playableId: String
      public var title: String
      public var artist: String
      public var album: String
      /// file name inside `widget-art/` in the App Group container
      public var artworkFileName: String?
      public var isPlaying: Bool
      public var isRadio: Bool
      public var isCached: Bool
      public var elapsedAnchor: Date
      public var elapsedSeconds: Double
      public var duration: Double
      public var playbackRate: Double

      public init(
        playableId: String,
        title: String,
        artist: String,
        album: String,
        artworkFileName: String?,
        isPlaying: Bool,
        isRadio: Bool,
        isCached: Bool,
        elapsedAnchor: Date,
        elapsedSeconds: Double,
        duration: Double,
        playbackRate: Double
      ) {
        self.playableId = playableId
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkFileName = artworkFileName
        self.isPlaying = isPlaying
        self.isRadio = isRadio
        self.isCached = isCached
        self.elapsedAnchor = elapsedAnchor
        self.elapsedSeconds = elapsedSeconds
        self.duration = duration
        self.playbackRate = playbackRate
      }

      /// wall-clock interval covering the whole track, playback-rate aware —
      /// feeds `ProgressView(timerInterval:)` for zero-update progress
      var progressTimerInterval: ClosedRange<Date> {
        let clampedRate = max(playbackRate, 0.01)
        let start = elapsedAnchor
          .addingTimeInterval(-elapsedSeconds / clampedRate)
        let end = elapsedAnchor
          .addingTimeInterval((duration - elapsedSeconds) / clampedRate)
        return start ... max(start, end)
      }
    }

    /// queue/context name (static for the life of the activity)
    public var contextName: String
    /// `ThemePreference` lowercased description — accent without kit access
    public var themeName: String

    public init(contextName: String, themeName: String) {
      self.contextName = contextName
      self.themeName = themeName
    }
  }
#endif
