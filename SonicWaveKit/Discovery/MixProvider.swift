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
  /// local mirror actually contains so empty kinds never surface. The
  /// mirror stats are collected on a background context with
  /// count/group-by fetches only — no `SongMO` materialization, so this
  /// stays cheap at 50k-song library scale.
  public func availableMixes() async -> [Mix] {
    let accountObjectId = account.managedObject.objectID
    let stats =
      (try? await storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(
          managedObjectId: accountObjectId
        )
        return MixLibraryStats(
          context: asyncCompanion.context,
          library: asyncCompanion.library,
          account: accountAsync
        )
      }) ?? MixLibraryStats()
    guard stats.songCount > 0 else { return [] }

    var mixes = [Mix]()
    if stats.favoriteCount > 0 {
      mixes.append(Mix(
        kind: .favoritesRadio,
        title: String(localized: "Favorites Radio", bundle: .main),
        subtitle: isOnline
          ? String(localized: "Similar songs around your favorites", bundle: .main)
          : String(localized: "Your favorites, shuffled", bundle: .main)
      ))
    }
    for decade in stats.decadeCounts.keys.sorted()
    where stats.decadeCounts[decade, default: 0] >= Self.minSongsPerDecadeMix {
      mixes.append(Mix(
        kind: .decadeMix,
        title: String(
          format: String(localized: "%llds Mix", bundle: .main),
          decade
        ),
        subtitle: String(
          format: String(localized: "Songs from the %llds", bundle: .main),
          decade
        ),
        parameter: String(decade)
      ))
    }
    for genre in stats.topGenreNames {
      mixes.append(Mix(
        kind: .genreBlend,
        title: String(
          format: String(localized: "%@ Blend", bundle: .main),
          genre
        ),
        subtitle: String(
          format: String(localized: "A fresh pick from %@", bundle: .main),
          genre
        ),
        parameter: genre
      ))
    }
    // deep cuts needs favorites or rated songs to cut from — without them
    // the card would resolve to an empty list
    if stats.favoriteOrRatedCount > 0 {
      mixes.append(Mix(
        kind: .deepCuts,
        title: String(localized: "Deep Cuts", bundle: .main),
        subtitle: String(
          localized: "Favorites and high-rated songs you barely play",
          bundle: .main
        )
      ))
    }
    // time-of-day needs play history — without `lastPlayedDate` rows the
    // card would degrade to a random pick that the title doesn't describe
    if stats.hasPlayedSongs {
      mixes.append(Mix(
        kind: .timeOfDay,
        title: String(localized: "Time Machine", bundle: .main),
        subtitle: String(
          localized: "What you usually play around now",
          bundle: .main
        )
      ))
    }
    return mixes
  }

  /// minimum songs in a decade bucket before it gets its own mix card
  private static let minSongsPerDecadeMix = 10
  /// how many genre-blend cards the hub offers at most
  private static let maxGenreBlendMixes = 3

  /// aggregate mirror stats behind `availableMixes()` — collected via
  /// `count(for:)` and dictionary group-by fetches, never by fetching
  /// `SongMO`s to count them
  private struct MixLibraryStats: Sendable {
    var songCount = 0
    var favoriteCount = 0
    /// favorites OR rated — presence gate for `deepCuts`
    var favoriteOrRatedCount = 0
    var decadeCounts = [Int: Int]()
    var topGenreNames = [String]()
    var hasPlayedSongs = false

    init() {}

    init(context: NSManagedObjectContext, library: LibraryStorage, account: Account) {
      let basePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        library.getFetchPredicate(forAccount: account),
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      ])

      let countRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      countRequest.predicate = basePredicate
      songCount = (try? context.count(for: countRequest)) ?? 0
      guard songCount > 0 else { return }

      let favoritesRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      favoritesRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        basePredicate,
        NSPredicate(format: "%K == TRUE", #keyPath(SongMO.isFavorite)),
      ])
      favoriteCount = (try? context.count(for: favoritesRequest)) ?? 0

      let favoriteOrRatedRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      favoriteOrRatedRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        basePredicate,
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          NSPredicate(format: "%K == TRUE", #keyPath(SongMO.isFavorite)),
          NSPredicate(format: "%K > 0", #keyPath(SongMO.rating)),
        ]),
      ])
      favoriteOrRatedCount = (try? context.count(for: favoriteOrRatedRequest)) ?? 0

      let playedRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      playedRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        basePredicate,
        NSPredicate(format: "%K != nil", #keyPath(SongMO.lastPlayedDate)),
      ])
      hasPlayedSongs = ((try? context.count(for: playedRequest)) ?? 0) > 0

      decadeCounts = Self.fetchYearHistogram(
        context: context,
        basePredicate: basePredicate
      )
      topGenreNames = Self.fetchTopGenreNames(
        context: context,
        basePredicate: basePredicate
      )
    }

    /// songs per calendar year → folded into decade buckets by the caller
    private static func fetchYearHistogram(
      context: NSManagedObjectContext,
      basePredicate: NSPredicate
    ) -> [Int: Int] {
      let countExpression = NSExpressionDescription()
      countExpression.name = "count"
      countExpression.expression = NSExpression(
        forFunction: "count:",
        arguments: [NSExpression(forKeyPath: "year")]
      )
      countExpression.expressionResultType = .integer64AttributeType

      let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "Song")
      fetchRequest.resultType = .dictionaryResultType
      fetchRequest.propertiesToGroupBy = [#keyPath(SongMO.year)]
      fetchRequest.propertiesToFetch = [#keyPath(SongMO.year), countExpression]
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        basePredicate,
        NSPredicate(format: "%K >= 1900", #keyPath(SongMO.year)),
      ])
      let rows = (try? context.fetch(fetchRequest)) ?? [NSDictionary]()
      var decadeCounts = [Int: Int]()
      for row in rows {
        guard let year = row[#keyPath(SongMO.year)] as? Int,
              let count = row["count"] as? Int
        else { continue }
        decadeCounts[year - (year % 10), default: 0] += count
      }
      return decadeCounts
    }

    /// genre names by song count, descending — capped at `maxGenreBlendMixes`
    private static func fetchTopGenreNames(
      context: NSManagedObjectContext,
      basePredicate: NSPredicate
    ) -> [String] {
      let genreKeyPath = "genre.name"
      let countExpression = NSExpressionDescription()
      countExpression.name = "count"
      countExpression.expression = NSExpression(
        forFunction: "count:",
        arguments: [NSExpression(forKeyPath: genreKeyPath)]
      )
      countExpression.expressionResultType = .integer64AttributeType

      let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "Song")
      fetchRequest.resultType = .dictionaryResultType
      fetchRequest.propertiesToGroupBy = [genreKeyPath]
      fetchRequest.propertiesToFetch = [genreKeyPath, countExpression]
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        basePredicate,
        NSPredicate(format: "%K != nil", genreKeyPath),
      ])
      let rows = (try? context.fetch(fetchRequest)) ?? [NSDictionary]()
      return rows.compactMap { row -> (String, Int)? in
        guard let name = row[genreKeyPath] as? String, !name.isEmpty,
              let count = row["count"] as? Int
        else { return nil }
        return (name, count)
      }
      .sorted { $0.1 > $1.1 }
      .prefix(maxGenreBlendMixes)
      .map { $0.0 }
    }
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
      return await resolveTimeOfDay(count: count)
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
  /// day", so the hour filter runs as a post-fetch scan of
  /// `lastPlayedDate` dictionary rows on a background context — no
  /// `SongMO` materialization — and only the matching handful is then
  /// resolved to objects on the main context.
  private func resolveTimeOfDay(count: Int) async -> [Song] {
    let calendar = Calendar.current
    let currentHour = calendar.component(.hour, from: Date())
    let accountObjectId = account.managedObject.objectID
    let candidateIds =
      (try? await storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(
          managedObjectId: accountObjectId
        )
        let objectIDExpression = NSExpressionDescription()
        objectIDExpression.name = "objectID"
        objectIDExpression.expression = NSExpression.expressionForEvaluatedObject()
        objectIDExpression.expressionResultType = .objectIDAttributeType

        let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "Song")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = [
          objectIDExpression,
          #keyPath(SongMO.lastPlayedDate),
        ]
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
          asyncCompanion.library.getFetchPredicate(forAccount: accountAsync),
          SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
          NSPredicate(format: "%K != nil", #keyPath(SongMO.lastPlayedDate)),
        ])
        let rows = (try? asyncCompanion.context.fetch(fetchRequest)) ?? [NSDictionary]()
        return rows.compactMap { row -> NSManagedObjectID? in
          guard let played = row[#keyPath(SongMO.lastPlayedDate)] as? Date,
                let objectID = row["objectID"] as? NSManagedObjectID
          else { return nil }
          let playedHour = calendar.component(.hour, from: played)
          let distance = abs(playedHour - currentHour)
          return min(distance, 24 - distance) <= 1 ? objectID : nil
        }
      }) ?? [NSManagedObjectID]()
    guard !candidateIds.isEmpty else {
      // no matches in this window — random library pick
      return resolveCriteriaMix(criteria: SmartPlaylistCriteria(), count: count)
    }
    var candidates = [Song]()
    storage.main.perform { companion in
      let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      fetchRequest.predicate = NSPredicate(format: "self IN %@", candidateIds)
      let found = (try? companion.context.fetch(fetchRequest)) ?? []
      candidates = found.compactMap { Song(managedObject: $0) }
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
