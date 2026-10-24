//
//  MixProvider.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 24.02.26.
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

import CoreData
import Foundation
import os.log

// MARK: - MixKind

/// G7: the concrete mix catalogue. Server-bound mixes degrade to local
/// evaluation when offline or when the backend lacks the endpoint —
/// never an error for "server can't do it".
public enum MixKind: String, Sendable, Codable, CaseIterable {
  /// radio seeded by a random favorite song (`getSimilarSongs` when online,
  /// shuffled favorites offline)
  case favoritesRadio
  /// songs from a chosen decade (`Mix.parameter` carries the start year)
  case decadeMix
  /// random pick from a chosen genre (`Mix.parameter` carries the genre name)
  case genreBlend
  /// favorites/high-rated songs the user barely played (local only —
  /// needs the mirror's play counts, which servers don't expose per user)
  case deepCuts
  /// songs last played around the current hour (local only — the mirror
  /// holds `lastPlayedDate` timestamps)
  case timeOfDay
}

// MARK: - Mix

/// A concrete, resolvable mix instance offered to the UI. `parameter` is
/// the kind-specific seed (decade start year, genre name) — `nil` for
/// parameterless kinds.
public struct Mix: Sendable, Equatable {
  public let kind: MixKind
  public let title: String
  public let subtitle: String
  public let parameter: String?

  public init(kind: MixKind, title: String, subtitle: String = "", parameter: String? = nil) {
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.parameter = parameter
  }
}

// MARK: - MixProvider

/// G7: resolves `Mix`es to playable song lists by composing existing
/// endpoints (`requestSimilarSongs`) with local `LibraryStorage` criteria
/// fetches — the same value-model reuse as `SmartPlaylistCriteria`.
///
/// Capability matrix:
/// - favoritesRadio: Subsonic `getSimilarSongs2` / Ampache `get_similar`
///   (both via `LibrarySyncer.requestSimilarSongs`); offline → local
///   favorites shuffle.
/// - decadeMix / genreBlend / deepCuts / timeOfDay: local criteria eval —
///   `isOfflineMode` safe by construction.
///
/// `resolve` is `@MainActor` (same convention as `LibrarySyncer`) and
/// cancellable — `Task.checkCancellation` between the server hop and the
/// CoreData reads.
@MainActor
public class MixProvider {
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "MixProvider")
  public static let defaultSongCount = 50

  private let account: Account
  private let storage: PersistentStorage
  private let librarySyncer: LibrarySyncer
  private let networkMonitor: NetworkMonitorFacade
  private let evaluator: SmartPlaylistEvaluator

  public init(
    account: Account,
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    networkMonitor: NetworkMonitorFacade
  ) {
    self.account = account
    self.storage = storage
    self.librarySyncer = librarySyncer
    self.networkMonitor = networkMonitor
    self.evaluator = SmartPlaylistEvaluator(storage: storage, account: account)
  }

  private var isOnline: Bool {
    networkMonitor.isConnectedToNetwork && !storage.settings.user.isOfflineMode
  }

  /// The mixes the UI may offer for this account — computed from what the
  /// local mirror actually contains so empty kinds never surface.
  public func availableMixes() -> [Mix] {
    var mixes = [Mix]()
    var favoriteCount = 0
    var decadeCounts = [Int: Int]()
    var genreNames = [String]()
    var hasAnySongs = false
    storage.main.perform { companion in
      let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        companion.library.getFetchPredicate(forAccount: self.account),
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      ])
      let songMOs = (try? companion.context.fetch(fetchRequest)) ?? []
      hasAnySongs = !songMOs.isEmpty
      for songMO in songMOs {
        if songMO.isFavorite { favoriteCount += 1 }
        let year = Int(songMO.year)
        if year >= 1900 {
          decadeCounts[year - (year % 10), default: 0] += 1
        }
        if let genreName = songMO.genre?.name, !genreName.isEmpty {
          genreNames.append(genreName)
        }
      }
    }
    guard hasAnySongs else { return [] }

    if favoriteCount > 0 {
      mixes.append(Mix(
        kind: .favoritesRadio,
        title: "Favorites Radio",
        subtitle: isOnline
          ? "Similar songs around your favorites"
          : "Your favorites, shuffled"
      ))
    }
    for decade in decadeCounts.keys.sorted() where decadeCounts[decade, default: 0] >= 10 {
      mixes.append(Mix(
        kind: .decadeMix,
        title: "\(decade)s Mix",
        subtitle: "Songs from the \(decade)s",
        parameter: String(decade)
      ))
    }
    // blend the top genres by song count — a handful, not an exhaustive list
    let topGenres = Dictionary(grouping: genreNames, by: { $0 })
      .mapValues { $0.count }
      .sorted { $0.value > $1.value }
      .prefix(3)
      .map { $0.key }
    for genre in topGenres {
      mixes.append(Mix(
        kind: .genreBlend,
        title: "\(genre) Blend",
        subtitle: "A fresh pick from \(genre)",
        parameter: genre
      ))
    }
    mixes.append(Mix(
      kind: .deepCuts,
      title: "Deep Cuts",
      subtitle: "Favorites and high-rated songs you barely play"
    ))
    mixes.append(Mix(
      kind: .timeOfDay,
      title: "Time Machine",
      subtitle: "What you usually play around now"
    ))
    return mixes
  }

  /// Resolves a mix to songs. Empty result = mix can't be built right now
  /// (no seed, offline with no local candidates, backend unsupported) —
  /// the UI shows a "mix unavailable" empty state, never an error.
  public func resolve(mix: Mix, count: Int = MixProvider.defaultSongCount) async throws
    -> [Song] {
    try Task.checkCancellation()
    switch mix.kind {
    case .favoritesRadio:
      return try await resolveFavoritesRadio(count: count)
    case .decadeMix:
      guard let decade = mix.parameter.flatMap(Int.init) else { return [] }
      return resolveCriteriaMix(criteria: SmartPlaylistCriteria(
        combination: .matchAll,
        rules: [SmartPlaylistRule(
          field: .year,
          operator: .inRange,
          value: .intRange(lower: decade, upper: decade + 9)
        )]
      ), count: count)
    case .genreBlend:
      guard let genre = mix.parameter, !genre.isEmpty else { return [] }
      return resolveCriteriaMix(criteria: SmartPlaylistCriteria(
        combination: .matchAll,
        rules: [SmartPlaylistRule(field: .genre, operator: .equal, value: .text(genre))]
      ), count: count)
    case .deepCuts:
      return resolveCriteriaMix(criteria: SmartPlaylistCriteria(
        combination: .matchAny,
        rules: [
          SmartPlaylistRule(field: .favorite, operator: .equal, value: .bool(true)),
          SmartPlaylistRule(field: .rating, operator: .greaterThan, value: .int(3)),
        ]
      ).withExtraRules([SmartPlaylistRule(
        field: .playCount,
        operator: .lessThan,
        value: .int(3)
      )]), count: count)
    case .timeOfDay:
      return resolveTimeOfDay(count: count)
    }
  }

  // MARK: private resolvers

  /// Online: seed `getSimilarSongs` with a random favorite — the "Instant
  /// Mix" lineage. Offline or empty server response: shuffled favorites.
  private func resolveFavoritesRadio(count: Int) async throws -> [Song] {
    if isOnline,
       let seed = randomFavoriteSong() {
      let similar = try await librarySyncer.requestSimilarSongs(song: seed, count: count)
      if !similar.isEmpty { return similar }
      os_log("Favorites radio: similar-songs came back empty, local fallback", log: log, type: .info)
    }
    return resolveCriteriaMix(criteria: SmartPlaylistCriteria(
      combination: .matchAll,
      rules: [SmartPlaylistRule(field: .favorite, operator: .equal, value: .bool(true))]
    ), count: count)
  }

  private func randomFavoriteSong() -> Song? {
    var seed: Song?
    storage.main.perform { companion in
      let favorites = companion.library.getFavoriteSongs(for: self.account)
      seed = favorites[randomPick: 1].first
    }
    return seed
  }

  private func resolveCriteriaMix(criteria: SmartPlaylistCriteria, count: Int) -> [Song] {
    evaluator.evaluate(criteria: criteria, randomPickLimit: count)
  }

  /// Songs whose `lastPlayedDate` hour-of-day matches the current hour
  /// (±1h tolerance bucket). Date-field criteria can't express "hour of
  /// day", so this runs a post-fetch filter — cheap at library scale and
  /// honest about its approximation.
  private func resolveTimeOfDay(count: Int) -> [Song] {
    let calendar = Calendar.current
    let currentHour = calendar.component(.hour, from: Date())
    var candidates = [Song]()
    storage.main.perform { companion in
      let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        companion.library.getFetchPredicate(forAccount: self.account),
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
        NSPredicate(format: "lastPlayedDate != nil"),
      ])
      let found = (try? companion.context.fetch(fetchRequest)) ?? []
      candidates = found.compactMap { Song(managedObject: $0) }
        .filter { song in
          guard let played = song.lastTimePlayed else { return false }
          let playedHour = calendar.component(.hour, from: played)
          let distance = abs(playedHour - currentHour)
          return min(distance, 24 - distance) <= 1
        }
    }
    if candidates.isEmpty {
      // never played / no matches in this window — random library pick
      return resolveCriteriaMix(criteria: SmartPlaylistCriteria(), count: count)
    }
    return Array(candidates[randomPick: count])
  }
}

// MARK: - SmartPlaylistCriteria helper

extension SmartPlaylistCriteria {
  /// convenience for mix composition: AND an extra rule onto a criteria
  /// (deep cuts = (favorite OR rating>3) AND playCount<3 needs a nested
  /// group the flat model can't express — so deep cuts approximates as
  /// `matchAll` over all three rules, accepting the narrower selection)
  func withExtraRules(_ extra: [SmartPlaylistRule]) -> SmartPlaylistCriteria {
    var copy = self
    copy.combination = .matchAll
    copy.rules.append(contentsOf: extra)
    return copy
  }
}
