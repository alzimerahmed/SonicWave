//
//  ListeningAnalytics.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 26.10.26.
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

// MARK: - ListeningPeriod

/// G14: reporting windows for the listening-stats screen. All windows
/// are rolling ("in the last week" = the 7 days up to `now`), not
/// calendar-aligned — a "this week so far" reading would make
/// Monday-morning stats look empty and lie about engagement.
public enum ListeningPeriod: Int, CaseIterable, Sendable {
  case week = 0
  case month
  case year
  case allTime

  // display strings (`displayName`/`recapTitle`) intentionally live in
  // the app target — `String(localized:)` resolves against the app
  // bundle's Localizable.xcstrings, not the framework's

  /// rolling cutoff; `nil` = unbounded (fetch everything)
  public func startDate(from now: Date, calendar: Calendar = .current) -> Date? {
    switch self {
    case .week:
      return calendar.date(byAdding: .day, value: -7, to: now)
    case .month:
      return calendar.date(byAdding: .month, value: -1, to: now)
    case .year:
      return calendar.date(byAdding: .year, value: -1, to: now)
    case .allTime:
      return nil
    }
  }
}

// MARK: - PlayEventSnapshot

/// Sendable, CoreData-free view of one `PlayEvent` row — the pure
/// input to `ListeningStatsAggregator`. Tests build these directly;
/// production maps them off `PlayEvent` wrappers.
public struct PlayEventSnapshot: Sendable, Equatable {
  public var date: Date
  public var secondsListened: Int
  public var trackDuration: Int
  public var isCountedAsPlay: Bool
  public var title: String?
  public var artistName: String?
  public var albumName: String?
  public var genreName: String?
  /// server-side id of the playable; `nil` once it left the library
  /// (the denormalized names still carry the row then)
  public var playableId: String?

  public init(
    date: Date,
    secondsListened: Int,
    trackDuration: Int,
    isCountedAsPlay: Bool,
    title: String?,
    artistName: String?,
    albumName: String?,
    genreName: String?,
    playableId: String?
  ) {
    self.date = date
    self.secondsListened = secondsListened
    self.trackDuration = trackDuration
    self.isCountedAsPlay = isCountedAsPlay
    self.title = title
    self.artistName = artistName
    self.albumName = albumName
    self.genreName = genreName
    self.playableId = playableId
  }
}

// MARK: - ListeningTopEntry

/// one row of a top-N chart. `representativePlayableId` lets the UI
/// resolve artwork for artist/album entries through one of the songs
/// that produced the rank — deleted playables simply show placeholder
/// art, never a blank.
public struct ListeningTopEntry: Sendable, Equatable {
  public var name: String
  /// secondary line — artist name for song/album entries, nil otherwise
  public var detail: String?
  /// counted plays only (`isCountedAsPlay`) — skips never chart
  public var playCount: Int
  /// all audible seconds in the group, skips included
  public var secondsListened: Int
  public var representativePlayableId: String?
}

// MARK: - ListeningStats

public struct ListeningStats: Sendable {
  public var period: ListeningPeriod
  /// every audible second in the window, counted plays and skips alike
  public var secondsListened: Int
  /// sessions meeting `PlayCountingRule`
  public var playCount: Int
  /// sessions below the play threshold
  public var skipCount: Int
  /// distinct songs that saw a counted play
  public var uniqueSongCount: Int
  public var topSongs: [ListeningTopEntry]
  public var topArtists: [ListeningTopEntry]
  public var topAlbums: [ListeningTopEntry]
  public var topGenres: [ListeningTopEntry]

  public var isEmpty: Bool { secondsListened == 0 && playCount == 0 && skipCount == 0 }
}

// MARK: - ListeningStatsAggregator

/// pure aggregation over `PlayEventSnapshot`s — single pass, dictionary
/// group-bys, no per-entity fetches (the Phase-8 mix-stats lesson:
/// never materialize MOs to count them; here snapshots arrive already
/// materialized and the grouping stays O(n)).
public enum ListeningStatsAggregator {
  /// `events` must already be period-scoped (the fetch filters by
  /// `date >= period.startDate`); `period` only labels the result.
  /// Newest-first ordering is exploited for `representativePlayableId`:
  /// the first non-nil playable id seen per group is the most recent.
  public static func aggregate(
    _ events: [PlayEventSnapshot],
    period: ListeningPeriod,
    topLimit: Int = 10
  )
    -> ListeningStats {
    var stats = ListeningStats(
      period: period,
      secondsListened: 0,
      playCount: 0,
      skipCount: 0,
      uniqueSongCount: 0,
      topSongs: [],
      topArtists: [],
      topAlbums: [],
      topGenres: []
    )

    var songs = [String: ListeningTopEntry]()
    var artists = [String: ListeningTopEntry]()
    var albums = [String: ListeningTopEntry]()
    var genres = [String: ListeningTopEntry]()

    /// accumulate `delta` plays/`seconds` into `group[key]`, keeping the
    /// first-seen (most recent — events arrive newest-first) non-nil
    /// playable id as the artwork hook
    func add(
      to group: inout [String: ListeningTopEntry],
      key: String,
      name: String,
      detail: String?,
      event: PlayEventSnapshot
    ) {
      let counted = event.isCountedAsPlay ? 1 : 0
      guard var entry = group[key] else {
        group[key] = ListeningTopEntry(
          name: name,
          detail: detail,
          playCount: counted,
          secondsListened: event.secondsListened,
          representativePlayableId: event.playableId
        )
        return
      }
      entry.playCount += counted
      entry.secondsListened += event.secondsListened
      if entry.representativePlayableId == nil {
        entry.representativePlayableId = event.playableId
      }
      group[key] = entry
    }

    for event in events {
      stats.secondsListened += event.secondsListened
      if event.isCountedAsPlay {
        stats.playCount += 1
      } else {
        stats.skipCount += 1
      }

      let title = event.title ?? "Unknown Title"
      let artistName = event.artistName ?? "Unknown Artist"
      // a deleted playable leaves playableId nil — group the orphan by
      // its denormalized title+artist so it still charts honestly
      let songKey = event.playableId ?? "orphan|\(title)|\(artistName)"
      add(
        to: &songs,
        key: songKey,
        name: title,
        detail: event.artistName,
        event: event
      )

      add(
        to: &artists,
        key: artistName,
        name: artistName,
        detail: nil,
        event: event
      )

      let albumName = event.albumName ?? "Unknown Album"
      add(
        to: &albums,
        // \u{1F} separator: names are user data — a visible delimiter
        // would collide; a control char can't appear in metadata
        key: "\(albumName)\u{1F}\(artistName)",
        name: albumName,
        detail: event.artistName,
        event: event
      )

      let genreName = event.genreName ?? "Unknown Genre"
      add(
        to: &genres,
        key: genreName,
        name: genreName,
        detail: nil,
        event: event
      )
    }

    stats.uniqueSongCount = songs.values.filter { $0.playCount > 0 }.count
    // rank by counted plays, then total seconds, then name — the order
    // is fully deterministic, which snapshot tests rely on
    func top(_ group: [String: ListeningTopEntry]) -> [ListeningTopEntry] {
      Array(
        group.values.sorted {
          if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
          if $0.secondsListened != $1.secondsListened {
            return $0.secondsListened > $1.secondsListened
          }
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(topLimit)
      )
    }
    stats.topSongs = top(songs)
    stats.topArtists = top(artists)
    stats.topAlbums = top(albums)
    stats.topGenres = top(genres)
    return stats
  }

  /// plain-text recap for the share sheet — honest numbers only; when
  /// nothing charted the caller shows the empty state instead.
  /// `periodTitle` is caller-supplied because localized display strings
  /// live in the app target (its bundle owns `Localizable.xcstrings`).
  public static func recapText(for stats: ListeningStats, periodTitle: String) -> String {
    var lines = [String]()
    lines.append("SonicWave Recap — \(periodTitle)")
    lines.append(
      "\(stats.secondsListened.asDurationShortString) of music · \(stats.playCount) plays across \(stats.uniqueSongCount) songs"
    )
    if let topArtist = stats.topArtists.first {
      lines.append("Top artist: \(topArtist.name) (\(topArtist.playCount) plays)")
    }
    if let topAlbum = stats.topAlbums.first {
      let detail = topAlbum.detail.map { " by \($0)" } ?? ""
      lines.append("Top album: \(topAlbum.name)\(detail) (\(topAlbum.playCount) plays)")
    }
    if let topSong = stats.topSongs.first {
      let detail = topSong.detail.map { " by \($0)" } ?? ""
      lines.append("Top song: \(topSong.name)\(detail) (\(topSong.playCount) plays)")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - ListeningStatsProvider

/// fetch seam between `LibraryStorage` and the pure aggregator — the
/// only type the stats UI needs. `since`-scoped fetches keep the DB
/// from materializing rows outside the reporting window; "All Time"
/// fetches everything (bounded by real usage — one row per play).
public struct ListeningStatsProvider {
  private let library: LibraryStorage

  public init(library: LibraryStorage) {
    self.library = library
  }

  @MainActor
  public func stats(
    for account: Account,
    period: ListeningPeriod,
    now: Date = Date(),
    calendar: Calendar = .current,
    topLimit: Int = 10
  )
    -> ListeningStats {
    let events = library.getPlayEvents(
      for: account,
      since: period.startDate(from: now, calendar: calendar)
    )
    return ListeningStatsAggregator.aggregate(
      events.map(\.asSnapshot),
      period: period,
      topLimit: topLimit
    )
  }

  /// cheap existence check for the empty state — `count(for:)` stays
  /// in SQLite, no rows materialized
  @MainActor
  public func hasAnyEvents(for account: Account) -> Bool {
    library.getPlayEventCount(for: account) > 0
  }
}
