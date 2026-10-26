//
//  WidgetSharedModels.swift
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

// MARK: - WidgetSharedConfig

/// App Group bridge between the app and the `SonicWaveWidgets` extension.
/// The app publishes `WidgetState.json` + artwork files into the group
/// container and reloads widget timelines; the extension reads them. Widget
/// transport buttons write `WidgetCommand.json` and ping the app via a
/// Darwin notification so taps don't launch the app while it is alive.
enum WidgetSharedConfig {
  static let appGroupIdentifier = "group.com.alzimerahmed.SonicWave"
  static let stateFileName = "WidgetState.json"
  static let commandFileName = "WidgetCommand.json"
  static let artworkDirectoryName = "widget-art"

  /// Darwin notification posted by the widget extension after writing a
  /// command file; the app's `WidgetCommandConsumer` consumes the file.
  /// Plain `String` (cast to `CFString` at the CoreFoundation call sites)
  /// so the shared static stays trivially Sendable.
  static let commandDarwinNotification =
    "com.alzimerahmed.sonicwave.widget.command"

  /// Commands older than this are dropped on consumption — replaying a
  /// stale tap on the next app launch would be surprising.
  static let commandMaxAge: TimeInterval = 120

  /// WidgetKit `kind` identifiers — used by the app to reload timelines and
  /// by the extension's `StaticConfiguration`s. Must match exactly.
  static let kindNowPlaying = "SonicWaveNowPlayingWidget"
  static let kindRecentlyPlayed = "SonicWaveRecentlyPlayedWidget"
  static let kindLockScreenNowPlaying = "SonicWaveNowPlayingLockScreenWidget"

  static let appURLScheme = "sonicwave"
}

// MARK: - WidgetLibraryElementType

/// Subset of `PlayableContainerTypeAppEnum` (see `IntentManager`) the
/// x-callback `playID` action accepts — plain strings so the widget
/// extension needs no SonicWaveKit link.
enum WidgetLibraryElementType: String, Codable, Sendable {
  case song
  case podcastEpisode
  /// `playID` has no radio type — radios are display-only entries.
  case radio

  var isPlayableViaDeepLink: Bool {
    self != .radio
  }
}

// MARK: - WidgetNowPlaying

/// Snapshot of the player's current track. `elapsedAnchor` + `elapsedSeconds`
/// + `playbackRate` let widget/Live Activity progress views run on
/// `timerInterval:`/`ProgressView(timerInterval:)` anchors — no per-second
/// timeline reloads, no `NSSupportsLiveActivitiesFrequentUpdates`.
struct WidgetNowPlaying: Codable, Sendable {
  var id: String
  var libraryElementType: WidgetLibraryElementType
  var title: String
  var artist: String
  var album: String
  /// file name inside `widget-art/` in the App Group container
  var artworkFileName: String?
  var isPlaying: Bool
  var isCached: Bool
  /// queue/context name (playlist/album/…), empty for loose queues
  var contextName: String
  var elapsedAnchor: Date
  var elapsedSeconds: Double
  var duration: Double
  var playbackRate: Double
  /// `ThemePreference` lowercased description — app settings are
  /// app-private, so the theme accent travels inside the state file.
  var themeName: String
  var updatedAt: Date

  var isRadio: Bool {
    libraryElementType == .radio
  }

  /// progress fraction `[0,1]` at an arbitrary instant, rate-aware
  func progressFraction(at date: Date) -> Double {
    guard duration > 0 else { return 0 }
    let elapsed = isPlaying
      ? elapsedSeconds + date.timeIntervalSince(elapsedAnchor) * playbackRate
      : elapsedSeconds
    return min(max(elapsed / duration, 0), 1)
  }

  /// wall-clock interval covering the whole track — feed to
  /// `ProgressView(timerInterval:)`; the view interpolates locally.
  var progressTimerInterval: ClosedRange<Date> {
    let clampedRate = max(playbackRate, 0.01)
    let start = elapsedAnchor.addingTimeInterval(-elapsedSeconds / clampedRate)
    let end = elapsedAnchor
      .addingTimeInterval((duration - elapsedSeconds) / clampedRate)
    return start ... max(start, end)
  }

  /// remaining wall-clock interval (for countdown displays) —
  /// `upperBound` is clamped to `elapsedAnchor` so an elapsed overrun
  /// (elapsed > duration / clock skew) can't form an inverted
  /// `ClosedRange`, which traps at runtime
  var remainingTimerInterval: ClosedRange<Date> {
    let range = progressTimerInterval
    return elapsedAnchor ... max(elapsedAnchor, range.upperBound)
  }
}

// MARK: - WidgetRecentItem

struct WidgetRecentItem: Codable, Sendable, Identifiable, Hashable {
  var id: String
  var libraryElementType: WidgetLibraryElementType
  var title: String
  var artist: String
  var artworkFileName: String?

  /// `sonicwave://x-callback-url/playID?id=…&libraryElementType=…` —
  /// built via `URLComponents` so an `&`, `=` or `+` inside an entity id
  /// can't break out and inject extra query parameters
  var deepLinkURL: URL? {
    guard libraryElementType.isPlayableViaDeepLink else { return nil }
    var components = URLComponents()
    components.scheme = WidgetSharedConfig.appURLScheme
    components.host = "x-callback-url"
    components.path = "/playID"
    components.queryItems = [
      URLQueryItem(name: "id", value: id),
      URLQueryItem(name: "libraryElementType", value: libraryElementType.rawValue),
    ]
    return components.url
  }
}

// MARK: - WidgetState

struct WidgetState: Codable, Sendable {
  var nowPlaying: WidgetNowPlaying?
  var recentlyPlayed: [WidgetRecentItem]

  static let empty = WidgetState(nowPlaying: nil, recentlyPlayed: [])
}

// MARK: - WidgetCommand

/// Transport commands the widget extension can dispatch to the app. The
/// raw values intentionally match `sonicwave://x-callback-url/` action
/// names (`IntentManager`) — they double as cold-launch documentation.
enum WidgetCommand: String, Codable, Sendable, CaseIterable {
  case togglePlayPause
  case playNext
  case playPreviousOrReplay
}

// MARK: - WidgetCommandEnvelope

struct WidgetCommandEnvelope: Codable, Sendable {
  var command: WidgetCommand
  var createdAt: Date
}

// MARK: - WidgetStore

/// File-IO surface for the App Group container. Used by the app
/// (`WidgetStatePublisher` writes state, `WidgetCommandConsumer` reads
/// commands) and by the extension (reads state, writes commands).
enum WidgetStore {
  static var containerURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: WidgetSharedConfig.appGroupIdentifier)
  }

  static var stateFileURL: URL? {
    containerURL?.appendingPathComponent(WidgetSharedConfig.stateFileName)
  }

  static var commandFileURL: URL? {
    containerURL?.appendingPathComponent(WidgetSharedConfig.commandFileName)
  }

  static var artworkDirectoryURL: URL? {
    containerURL?.appendingPathComponent(
      WidgetSharedConfig.artworkDirectoryName,
      isDirectory: true
    )
  }

  static func artworkURL(fileName: String) -> URL? {
    // the file name travels inside the shared-container JSON blob —
    // reject path separators and `..` segments so a crafted state file
    // can't resolve artwork outside `widget-art/`; the callers render
    // the themed placeholder on `nil`
    guard fileName == (fileName as NSString).lastPathComponent,
          !fileName.contains("..") else { return nil }
    return artworkDirectoryURL?.appendingPathComponent(fileName)
  }

  static func readState() -> WidgetState? {
    guard let url = stateFileURL,
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(WidgetState.self, from: data)
  }

  static func writeState(_ state: WidgetState) throws {
    guard let url = stateFileURL else { return }
    let data = try JSONEncoder().encode(state)
    try data.write(to: url, options: .atomic)
  }

  static func writeCommand(_ command: WidgetCommand) throws {
    // a missing App Group container must not masquerade as a delivered
    // command — the Darwin ping would fire regardless
    guard let url = commandFileURL else {
      throw CocoaError(.fileNoSuchFile)
    }
    let envelope = WidgetCommandEnvelope(command: command, createdAt: Date())
    let data = try JSONEncoder().encode(envelope)
    try data.write(to: url, options: .atomic)
  }

  /// Reads and deletes the pending command file. Returns `nil` when no
  /// command is queued or the file can't be decoded.
  ///
  /// Residual race: a widget write landing between the read and the
  /// delete below is removed unseen — the command is lost. The window is
  /// a single file operation; the proper fix (per-command unique
  /// filenames) is deliberately not worth the added bookkeeping for a
  /// tap the user can simply repeat.
  static func consumeCommandEnvelope() -> WidgetCommandEnvelope? {
    guard let url = commandFileURL,
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(WidgetCommandEnvelope.self, from: data)
  }

  /// Wipes every widget artifact in the shared container: state is
  /// reset to `.empty`, the `widget-art/` cache contents and any
  /// pending command file are removed. Called on account teardown
  /// (logout + obsolete-account cleanup) so a removed account's
  /// now-playing/recent data can't linger on the Home/Lock Screen.
  /// The callers reload WidgetKit timelines afterwards.
  static func purgeSharedState() {
    try? writeState(.empty)
    if let commandURL = commandFileURL {
      try? FileManager.default.removeItem(at: commandURL)
    }
    guard let directory = artworkDirectoryURL,
          let files = try? FileManager.default
          .contentsOfDirectory(atPath: directory.path) else { return }
    for file in files {
      try? FileManager.default
        .removeItem(at: directory.appendingPathComponent(file))
    }
  }

  /// Darwin ping — cross-process inside the App Group; wakes the app's
  /// `WidgetCommandConsumer` without launching it.
  static func postCommandNotification() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(WidgetSharedConfig.commandDarwinNotification as CFString),
      nil,
      nil,
      true
    )
  }
}
