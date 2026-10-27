//
//  WatchShared.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 28.10.26.
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

// MARK: - WatchMessageKind

/// Message envelope kinds exchanged over WatchConnectivity (G15).
/// The shared file is compiled into the iOS app and the watch app so
/// both sides agree on keys — same dual-membership pattern as
/// `WidgetSharedModels`.
public enum WatchMessageKind: String {
  /// watch → phone: a `WatchCommand` to execute against `PlayerFacade`
  case command
  /// watch → phone: "send me your current state" (reply carries the
  /// `WatchNowPlaying` dictionary)
  case stateRequest
  /// phone → watch: a `WatchNowPlaying` payload — used both as the
  /// `updateApplicationContext` envelope and as command/message replies
  case nowPlaying
}

// MARK: - WatchCommand

/// Transport commands the watch can send. Remote control only — the
/// watch never touches the library or the server directly.
public enum WatchCommand: String {
  case togglePlayPause
  case playNext
  case playPreviousOrReplay
  /// engine gain — absolute value in `WatchKey.volume` (0...1)
  case setVolume
}

// MARK: - WatchKey

/// Dictionary keys for the `[String: Any]` payloads WatchConnectivity
/// transports. Only plist-serializable values are used.
public enum WatchKey {
  public static let kind = "kind"
  public static let command = "command"
  public static let volume = "volume"
  /// file-transfer metadata key — artwork files are tagged with the
  /// playable id they belong to so the watch can match art to state
  public static let artworkTrackId = "artworkTrackId"
  /// command send instant — `transferUserInfo` payloads replay verbatim
  /// on next launch, so the phone drops commands older than ~60s
  public static let sentAt = "sentAt"
  /// per-command unique id — a `sendMessage` whose reply was lost is
  /// re-queued as `transferUserInfo`, so the phone dedupes by nonce
  /// (an age check alone can't tell delivered-and-executed from stale)
  public static let nonce = "nonce"
}

// MARK: - WatchQueueItem

public struct WatchQueueItem: Equatable, Sendable {
  public var title: String
  public var artist: String

  public init(title: String, artist: String) {
    self.title = title
    self.artist = artist
  }

  public init?(dictionary: [String: Any]) {
    guard let title = dictionary["title"] as? String else { return nil }
    self.title = title
    artist = dictionary["artist"] as? String ?? ""
  }

  public var asDictionary: [String: Any] {
    ["title": title, "artist": artist]
  }
}

// MARK: - WatchNowPlaying

/// Now-playing snapshot the phone publishes to the watch via
/// `updateApplicationContext` and as command replies. `elapsed` is
/// anchored by `capturedAt` so the watch can advance progress locally
/// between pushes — the same anchor pattern `WidgetNowPlaying` uses.
public struct WatchNowPlaying: Equatable {
  /// false = nothing queued/playing (watch shows its idle state)
  public var hasNowPlaying: Bool
  /// `AbstractPlayable.id` — also the artwork-transfer match key
  public var trackId: String
  public var title: String
  public var artist: String
  public var album: String
  public var isPlaying: Bool
  /// radios can't seek and show "LIVE" instead of progress
  public var isRadio: Bool
  public var isSeekable: Bool
  public var elapsed: Double
  public var duration: Double
  /// engine gain 0...1 — maps `PlayerFacade.volume`
  public var volume: Double
  public var contextName: String
  /// instant `elapsed` was sampled — progress = elapsed + (now - capturedAt)
  public var capturedAt: Date
  /// queue glimpse — up to `WatchNowPlaying.maxUpNextItems` next entries
  public var upNext: [WatchQueueItem]

  public static let maxUpNextItems = 5

  public init(
    hasNowPlaying: Bool = false,
    trackId: String = "",
    title: String = "",
    artist: String = "",
    album: String = "",
    isPlaying: Bool = false,
    isRadio: Bool = false,
    isSeekable: Bool = false,
    elapsed: Double = 0,
    duration: Double = 0,
    volume: Double = 0,
    contextName: String = "",
    capturedAt: Date = Date(),
    upNext: [WatchQueueItem] = []
  ) {
    self.hasNowPlaying = hasNowPlaying
    self.trackId = trackId
    self.title = title
    self.artist = artist
    self.album = album
    self.isPlaying = isPlaying
    self.isRadio = isRadio
    self.isSeekable = isSeekable
    self.elapsed = elapsed
    self.duration = duration
    self.volume = volume
    self.contextName = contextName
    self.capturedAt = capturedAt
    self.upNext = upNext
  }

  public init(dictionary: [String: Any]) {
    hasNowPlaying = dictionary["hasNowPlaying"] as? Bool ?? false
    trackId = dictionary["trackId"] as? String ?? ""
    title = dictionary["title"] as? String ?? ""
    artist = dictionary["artist"] as? String ?? ""
    album = dictionary["album"] as? String ?? ""
    isPlaying = dictionary["isPlaying"] as? Bool ?? false
    isRadio = dictionary["isRadio"] as? Bool ?? false
    isSeekable = dictionary["isSeekable"] as? Bool ?? false
    elapsed = dictionary["elapsed"] as? Double ?? 0
    duration = dictionary["duration"] as? Double ?? 0
    volume = dictionary["volume"] as? Double ?? 0
    contextName = dictionary["contextName"] as? String ?? ""
    capturedAt = dictionary["capturedAt"] as? Date ?? Date()
    upNext = (dictionary["upNext"] as? [[String: Any]] ?? [])
      .compactMap { WatchQueueItem(dictionary: $0) }
  }

  public var asDictionary: [String: Any] {
    [
      "kind": WatchMessageKind.nowPlaying.rawValue,
      "hasNowPlaying": hasNowPlaying,
      "trackId": trackId,
      "title": title,
      "artist": artist,
      "album": album,
      "isPlaying": isPlaying,
      "isRadio": isRadio,
      "isSeekable": isSeekable,
      "elapsed": elapsed,
      "duration": duration,
      "volume": volume,
      "contextName": contextName,
      "capturedAt": capturedAt,
      "upNext": upNext.map { $0.asDictionary },
    ]
  }

  /// live progress on the watch between context pushes — capped at
  /// `duration` so a stale snapshot can't run past the track end
  public func elapsedNow(at date: Date = Date()) -> Double {
    guard isPlaying else { return elapsed }
    return min(duration > 0 ? duration : .greatestFiniteMagnitude,
               elapsed + date.timeIntervalSince(capturedAt))
  }
}
