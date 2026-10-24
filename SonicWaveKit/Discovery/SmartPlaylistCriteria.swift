//
//  SmartPlaylistCriteria.swift
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

// MARK: - SmartPlaylistField

/// G8: filterable fields of a `SmartPlaylistRule`. Raw values match the
/// Navidrome `.nsp` field names where a mapping exists; `custom` carries
/// `.nsp` fields SonicWave cannot evaluate locally (e.g. `bpm`, `mbz_*`,
/// album/artist-level aggregates) — they are preserved on import, marked
/// unsupported, and skipped by the local evaluator.
public enum SmartPlaylistField: Sendable, Equatable {
  case rating
  case playCount
  case lastPlayed
  case addedDate
  case genre
  case year
  case artist
  case album
  case title
  case favorite
  /// local dislike flag (#587) — backed by `AbstractPlayableMO.isDisliked` (v51)
  case disliked
  case custom(String)

  /// CoreData keyPath on `SongMO` used for local evaluation.
  /// `nil` => field is not locally evaluable.
  var songKeyPath: String? {
    switch self {
    case .rating: return "rating"
    case .playCount: return "playCount"
    case .lastPlayed: return "lastPlayedDate"
    case .addedDate: return "addedDate"
    case .genre: return "genre.name"
    case .year: return "year"
    case .artist: return "artist.name"
    case .album: return "album.name"
    case .title: return "title"
    case .favorite: return "isFavorite"
    case .disliked: return "isDisliked"
    case .custom: return nil
    }
  }

  /// `.nsp` field name for round-tripping / display
  var nspName: String {
    switch self {
    case .rating: return "rating"
    case .playCount: return "playcount"
    case .lastPlayed: return "lastplayed"
    case .addedDate: return "dateadded"
    case .genre: return "genre"
    case .year: return "year"
    case .artist: return "artist"
    case .album: return "album"
    case .title: return "title"
    case .favorite: return "loved"
    case .disliked: return "disliked"
    case .custom(let name): return name
    }
  }
}

extension SmartPlaylistField: Codable {
  private enum KnownField: String, Codable {
    case rating, playCount, lastPlayed, addedDate, genre, year, artist, album, title
    case favorite, disliked
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let name = try container.decode(String.self)
    if let known = KnownField(rawValue: name) {
      switch known {
      case .rating: self = .rating
      case .playCount: self = .playCount
      case .lastPlayed: self = .lastPlayed
      case .addedDate: self = .addedDate
      case .genre: self = .genre
      case .year: self = .year
      case .artist: self = .artist
      case .album: self = .album
      case .title: self = .title
      case .favorite: self = .favorite
      case .disliked: self = .disliked
      }
    } else {
      self = .custom(name)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .rating: try container.encode("rating")
    case .playCount: try container.encode("playCount")
    case .lastPlayed: try container.encode("lastPlayed")
    case .addedDate: try container.encode("addedDate")
    case .genre: try container.encode("genre")
    case .year: try container.encode("year")
    case .artist: try container.encode("artist")
    case .album: try container.encode("album")
    case .title: try container.encode("title")
    case .favorite: try container.encode("favorite")
    case .disliked: try container.encode("disliked")
    case .custom(let name): try container.encode(name)
    }
  }
}

// MARK: - SmartPlaylistOperator

/// G8: comparison operators — superset of the `.nsp` operator grammar
/// (`is`/`isNot`/`gt`/`lt`/`contains`/`notContains`/`startsWith`/`endsWith`/
/// `inTheRange`/`inTheLast`/`notInTheLast`). `.nsp` operators that cannot be
/// expressed on local fields (`before`, `after`, `inPlaylist`, `isMissing`,
/// `isPresent`) are dropped at import and recorded in
/// `SmartPlaylistCriteria.unsupportedNotes`.
public enum SmartPlaylistOperator: String, Codable, Sendable, CaseIterable {
  case equal
  case notEqual
  case greaterThan
  case lessThan
  case contains
  case notContains
  case startsWith
  case endsWith
  /// `inTheRange` — value `.intRange`
  case inRange
  /// `inTheLast` — value `.days`, evaluated against a date field
  case inLastDays
  /// `notInTheLast` — value `.days`
  case notInLastDays
}

// MARK: - SmartPlaylistValue

public enum SmartPlaylistValue: Codable, Sendable, Equatable {
  case text(String)
  case int(Int)
  case bool(Bool)
  case intRange(lower: Int, upper: Int)
  /// day offset for `.inLastDays`/`.notInLastDays`
  case days(Int)

  /// scalar used by display/export paths
  public var displayString: String {
    switch self {
    case .text(let value): return value
    case .int(let value): return String(value)
    case .bool(let value): return value ? "true" : "false"
    case .intRange(let lower, let upper): return "\(lower)–\(upper)"
    case .days(let value): return "\(value)d"
    }
  }
}

// MARK: - SmartPlaylistRule

public struct SmartPlaylistRule: Codable, Sendable, Equatable {
  public var field: SmartPlaylistField
  public var `operator`: SmartPlaylistOperator
  public var value: SmartPlaylistValue

  public init(
    field: SmartPlaylistField,
    operator: SmartPlaylistOperator,
    value: SmartPlaylistValue
  ) {
    self.field = field
    self.`operator` = `operator`
    self.value = value
  }

  /// `true` when the field+operator pair can be evaluated against the local
  /// CoreData mirror (`.custom` fields and string ops on numeric/date fields
  /// are not evaluable and get skipped by `predicate()`).
  public var isLocallyEvaluable: Bool {
    predicate(referenceDate: Date()) != nil
  }

  /// Builds the single-rule predicate or `nil` when the combination cannot
  /// be expressed. String comparisons are case/diacritic-insensitive to
  /// match Navidrome's normalized-field semantics.
  func predicate(referenceDate: Date) -> NSPredicate? {
    guard let keyPath = field.songKeyPath else { return nil }
    switch (`operator`, value) {
    case (.equal, .text(let value)):
      return NSPredicate(format: "%K ==[cd] %@", keyPath, value)
    case (.notEqual, .text(let value)):
      return NSPredicate(format: "%K !=[cd] %@", keyPath, value)
    case (.equal, .int(let value)):
      return NSPredicate(format: "%K == %d", keyPath, value)
    case (.notEqual, .int(let value)):
      return NSPredicate(format: "%K != %d", keyPath, value)
    case (.equal, .bool(let value)):
      return NSPredicate(format: "%K == %@", keyPath, NSNumber(value: value))
    case (.notEqual, .bool(let value)):
      return NSPredicate(format: "%K != %@", keyPath, NSNumber(value: value))
    case (.greaterThan, .int(let value)):
      return NSPredicate(format: "%K > %d", keyPath, value)
    case (.lessThan, .int(let value)):
      return NSPredicate(format: "%K < %d", keyPath, value)
    case (.contains, .text(let value)):
      return NSPredicate(format: "%K CONTAINS[cd] %@", keyPath, value)
    case (.notContains, .text(let value)):
      return NSPredicate(format: "NOT (%K CONTAINS[cd] %@)", keyPath, value)
    case (.startsWith, .text(let value)):
      return NSPredicate(format: "%K BEGINSWITH[cd] %@", keyPath, value)
    case (.endsWith, .text(let value)):
      return NSPredicate(format: "%K ENDSWITH[cd] %@", keyPath, value)
    case (.inRange, .intRange(let lower, let upper)):
      return NSPredicate(format: "%K >= %d AND %K <= %d", keyPath, lower, keyPath, upper)
    case (.inLastDays, .days(let dayCount)):
      guard dayCount >= 0 else { return nil }
      let cutoff = referenceDate.addingTimeInterval(-TimeInterval(dayCount) * 86_400)
      return NSPredicate(format: "%K >= %@", keyPath, cutoff as NSDate)
    case (.notInLastDays, .days(let dayCount)):
      guard dayCount >= 0 else { return nil }
      let cutoff = referenceDate.addingTimeInterval(-TimeInterval(dayCount) * 86_400)
      // nil lastPlayedDate counts as "not played in the last N days"
      return NSPredicate(format: "%K == nil OR %K < %@", keyPath, keyPath, cutoff as NSDate)
    default:
      return nil
    }
  }
}

// MARK: - SmartPlaylistSort

public struct SmartPlaylistSort: Codable, Sendable, Equatable {
  public var field: SmartPlaylistField
  public var ascending: Bool

  public init(field: SmartPlaylistField, ascending: Bool) {
    self.field = field
    self.ascending = ascending
  }

  var sortDescriptor: NSSortDescriptor? {
    guard let keyPath = field.songKeyPath else { return nil }
    return NSSortDescriptor(key: keyPath, ascending: ascending)
  }
}

// MARK: - SmartPlaylistCriteria

/// G8: the persistable smart-playlist value model. Persisted as JSON by the
/// database agent (`PlaylistMO.smartCriteriaJson`); evaluated locally by
/// `SmartPlaylistEvaluator` via `fetchDescriptor()`. Imported `.nsp` rules
/// keep a lossless-ish shape: mappable expressions become rules, unmappable
/// ones are dropped and recorded in `unsupportedNotes` so the UI can flag
/// "partially evaluated — server resolves the rest" and still play the
/// server-resolved list.
public struct SmartPlaylistCriteria: Codable, Sendable, Equatable {
  public enum Combination: String, Codable, Sendable {
    /// `.nsp` `all:` — every rule must match
    case matchAll
    /// `.nsp` `any:` — at least one rule must match
    case matchAny
  }

  public var combination: Combination
  public var rules: [SmartPlaylistRule]
  public var sort: SmartPlaylistSort?
  public var limit: Int?
  /// human-readable notes about rules/fields/operators that were dropped
  /// on import because the local evaluator cannot express them
  public var unsupportedNotes: [String]
  /// `.nsp` provenance — `true` when imported from a server smart playlist
  public var isImportedFromServer: Bool

  public init(
    combination: Combination = .matchAll,
    rules: [SmartPlaylistRule] = [],
    sort: SmartPlaylistSort? = nil,
    limit: Int? = nil,
    unsupportedNotes: [String] = [],
    isImportedFromServer: Bool = false
  ) {
    self.combination = combination
    self.rules = rules
    self.sort = sort
    self.limit = limit
    self.unsupportedNotes = unsupportedNotes
    self.isImportedFromServer = isImportedFromServer
  }

  public var isEmpty: Bool { rules.isEmpty }

  /// `true` when at least one rule uses the local dislike flag — the flag
  /// lands with schema v51; callers can gate UI or fall back to the
  /// server-resolved list until the migration ships.
  public var containsDislikedRules: Bool {
    rules.contains { $0.field == .disliked }
  }

  /// Combined predicate for local evaluation. Rules that cannot be mapped
  /// are silently skipped — `matchAll` with zero evaluable rules degrades to
  /// `TRUEPREDICATE`, `matchAny` to `FALSEPREDICATE` (evaluable-empty ≠
  /// match-everything for the ANY semantics).
  public func predicate(referenceDate: Date = Date()) -> NSPredicate {
    let rulePredicates = rules.compactMap { $0.predicate(referenceDate: referenceDate) }
    switch combination {
    case .matchAll:
      return rulePredicates.isEmpty
        ? NSPredicate(value: true)
        : NSCompoundPredicate(andPredicateWithSubpredicates: rulePredicates)
    case .matchAny:
      return rulePredicates.isEmpty
        ? NSPredicate(value: false)
        : NSCompoundPredicate(orPredicateWithSubpredicates: rulePredicates)
    }
  }

  public func sortDescriptors() -> [NSSortDescriptor] {
    sort?.sortDescriptor.map { [$0] } ?? []
  }

  /// Fetch descriptor consumed by `SmartPlaylistEvaluator` — callers AND the
  /// account predicate plus `SongMO.excludeServerDeleteUncachedSongsFetchPredicate`.
  public func songFetchRequest(referenceDate: Date = Date())
    -> NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = predicate(referenceDate: referenceDate)
    fetchRequest.sortDescriptors = sortDescriptors()
    if let limit, limit > 0 {
      fetchRequest.fetchLimit = limit
    }
    return fetchRequest
  }
}
