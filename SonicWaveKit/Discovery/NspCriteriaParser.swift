//
//  NspCriteriaParser.swift
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

import Foundation

// MARK: - NspSmartPlaylist

/// G8: the metadata layer of an `.nsp` document — fields that belong to the
/// playlist object itself rather than to its criteria.
public struct NspSmartPlaylist: Sendable, Equatable {
  public var name: String?
  public var comment: String?
  public var isPublic: Bool
  public var criteria: SmartPlaylistCriteria

  public init(
    name: String? = nil,
    comment: String? = nil,
    isPublic: Bool = false,
    criteria: SmartPlaylistCriteria
  ) {
    self.name = name
    self.comment = comment
    self.isPublic = isPublic
    self.criteria = criteria
  }
}

// MARK: - NspCriteriaParser

/// G8: maps the Navidrome `.nsp` criteria grammar to
/// `SmartPlaylistCriteria`. Grammar (verified against
/// `navidrome/model/criteria/json.go`):
///
///     {"name": …, "comment": …, "public": …,
///      "all": [{ "<op>": { "<field>": <value> } } | {"any": [ … ]}],
///      "sort": "<field>", "order": "asc|desc", "limit": 100}
///
/// Operators: is, isNot, gt, lt, contains, notContains, startsWith,
/// endsWith, inTheRange, before, after, inTheLast, notInTheLast,
/// inPlaylist, notInPlaylist, isMissing, isPresent (the latter two are
/// newer additions).
///
/// Degradation contract:
/// - same-type nested conjunctions are flattened (`all` inside `all`)
/// - opposite-type nested conjunctions (`any` inside `all` etc.) cannot be
///   expressed by the flat model → their inner rules are dropped and a note
///   is recorded (the server still resolves the authoritative song list)
/// - fields without a local mapping become `.custom(name)` rules — kept
///   for display, skipped by the local evaluator, noted as unsupported
/// - operators with no local equivalent (before/after/inPlaylist/
///   isMissing/isPresent) are dropped with a note
/// - `.nsp` files allow `//` and `/* */` comments — stripped pre-parse
public enum NspCriteriaParser {
  /// Parses `.nsp` JSON data. Returns `nil` only when the payload is not
  /// a JSON object at all — malformed rules degrade to notes, never to nil.
  public static func parse(data: Data) -> NspSmartPlaylist? {
    let stripped = stripJsonComments(data)
    guard let root = try? JSONSerialization.jsonObject(with: stripped),
          let rootDict = root as? [String: Any]
    else { return nil }

    var notes = [String]()
    var rules = [SmartPlaylistRule]()
    var combination = SmartPlaylistCriteria.Combination.matchAll

    if let all = rootDict["all"] as? [[String: Any]] {
      rules.append(contentsOf: parseConjunction(
        expressions: all,
        parentCombination: .matchAll,
        notes: &notes
      ))
    }
    if let any = rootDict["any"] as? [[String: Any]] {
      if rules.isEmpty {
        combination = .matchAny
      }
      rules.append(contentsOf: parseConjunction(
        expressions: any,
        parentCombination: .matchAny,
        notes: &notes
      ))
    }

    var sort: SmartPlaylistSort? = nil
    if let sortFieldName = rootDict["sort"] as? String {
      let normalized = sortFieldName
        .trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        .lowercased()
      if normalized == "random" {
        notes.append("sort field 'random' not supported locally")
      } else if let sortField = mapField(name: normalized).knownField {
        let ascending = (rootDict["order"] as? String)?.lowercased() != "desc"
        sort = SmartPlaylistSort(field: sortField, ascending: ascending)
      } else {
        notes.append("sort field '\(normalized)' is not supported locally")
      }
    }

    let limit = (rootDict["limit"] as? NSNumber)?.intValue

    let criteria = SmartPlaylistCriteria(
      combination: combination,
      rules: rules,
      sort: sort,
      limit: limit,
      unsupportedNotes: notes,
      isImportedFromServer: true
    )

    return NspSmartPlaylist(
      name: rootDict["name"] as? String,
      comment: rootDict["comment"] as? String,
      isPublic: (rootDict["public"] as? NSNumber)?.boolValue ?? false,
      criteria: criteria
    )
  }

  // MARK: conjunction parsing

  private static func parseConjunction(
    expressions: [[String: Any]],
    parentCombination: SmartPlaylistCriteria.Combination,
    notes: inout [String]
  ) -> [SmartPlaylistRule] {
    var rules = [SmartPlaylistRule]()
    for expression in expressions {
      for (key, rawValue) in expression {
        let normalizedKey = key.lowercased()
        if normalizedKey == "all" || normalizedKey == "any" {
          let nestedCombination: SmartPlaylistCriteria.Combination =
            normalizedKey == "all" ? .matchAll : .matchAny
          guard let nestedExpressions = rawValue as? [[String: Any]] else {
            notes.append("malformed nested conjunction '\(normalizedKey)' skipped")
            continue
          }
          if nestedCombination == parentCombination {
            // same-type nested conjunctions flatten losslessly at any
            // depth — `all(all(a, all(b)))` == `all(a, b)`
            rules.append(contentsOf: parseConjunction(
              expressions: nestedExpressions,
              parentCombination: parentCombination,
              notes: &notes
            ))
          } else {
            notes.append(
              "nested '\(normalizedKey)' group cannot be expressed by the flat criteria model"
            )
          }
          continue
        }
        if let rule = parseRule(
          operatorName: normalizedKey,
          rawValue: rawValue,
          notes: &notes
        ) {
          rules.append(rule)
        }
      }
    }
    return rules
  }

  // MARK: expression parsing

  private static func parseRule(
    operatorName: String,
    rawValue: Any,
    notes: inout [String]
  ) -> SmartPlaylistRule? {
    guard let operatorMap = mapOperator(name: operatorName) else {
      notes.append("operator '\(operatorName)' is not supported")
      return nil
    }
    guard let fieldMap = rawValue as? [String: Any], fieldMap.count == 1,
          let (fieldName, fieldValue) = fieldMap.first
    else {
      notes.append("malformed '\(operatorName)' expression skipped")
      return nil
    }

    let mappedField = mapField(name: fieldName.lowercased())
    guard let value = mapValue(fieldValue: fieldValue, for: operatorMap)
    else {
      notes.append("value of '\(operatorName).\(fieldName)' is not supported")
      return nil
    }
    if mappedField.knownField == nil {
      notes.append("field '\(fieldName)' has no local mapping — kept as custom rule")
    }
    let rule = SmartPlaylistRule(
      field: mappedField.field,
      operator: operatorMap,
      value: value
    )
    if mappedField.knownField != nil, !rule.isLocallyEvaluable {
      notes.append(
        "rule '\(operatorName).\(fieldName)' cannot be evaluated locally — kept for display"
      )
    }
    return rule
  }

  // MARK: field/operator/value mapping

  /// `.nsp` operators that CANNOT be represented return nil:
  /// before/after (absolute dates), inPlaylist/notInPlaylist (playlist ref),
  /// isMissing/isPresent (null checks newer than the classic grammar).
  private static func mapOperator(name: String) -> SmartPlaylistOperator? {
    switch name {
    case "is": return .equal
    case "isnot": return .notEqual
    case "gt": return .greaterThan
    case "lt": return .lessThan
    case "contains": return .contains
    case "notcontains": return .notContains
    case "startswith": return .startsWith
    case "endswith": return .endsWith
    case "intherange": return .inRange
    case "inthelast": return .inLastDays
    case "notinthelast": return .notInLastDays
    default: return nil
    }
  }

  private static func mapField(name: String) -> (field: SmartPlaylistField, knownField: SmartPlaylistField?) {
    switch name {
    case "rating": return (.rating, .rating)
    case "playcount": return (.playCount, .playCount)
    case "lastplayed": return (.lastPlayed, .lastPlayed)
    case "dateadded": return (.addedDate, .addedDate)
    case "genre": return (.genre, .genre)
    case "year", "originalyear", "releaseyear": return (.year, .year)
    case "artist", "albumartist": return (.artist, .artist)
    case "album": return (.album, .album)
    case "title": return (.title, .title)
    case "loved", "favorite", "starred": return (.favorite, .favorite)
    case "disliked": return (.disliked, .disliked)
    default: return (.custom(name), nil)
    }
  }

  private static func mapValue(fieldValue: Any, for op: SmartPlaylistOperator)
    -> SmartPlaylistValue? {
    switch op {
    case .inRange:
      guard let bounds = fieldValue as? [Any], bounds.count == 2,
            let lower = (bounds[0] as? NSNumber)?.intValue,
            let upper = (bounds[1] as? NSNumber)?.intValue
      else { return nil }
      return .intRange(lower: lower, upper: upper)
    case .inLastDays, .notInLastDays:
      guard let days = (fieldValue as? NSNumber)?.intValue else { return nil }
      return .days(days)
    case .greaterThan, .lessThan:
      if let number = fieldValue as? NSNumber { return .int(number.intValue) }
      return nil
    case .contains, .notContains, .startsWith, .endsWith:
      if let text = fieldValue as? String { return .text(text) }
      return nil
    case .equal, .notEqual:
      if let bool = fieldValue as? NSNumber,
         bool === kCFBooleanTrue || bool === kCFBooleanFalse {
        return .bool(bool.boolValue)
      }
      if let number = fieldValue as? NSNumber { return .int(number.intValue) }
      if let text = fieldValue as? String { return .text(text) }
      return nil
    }
  }

  // MARK: comment stripping

  /// `.nsp` supports `//` line and `/* */` block comments. Stripping is
  /// string-literal aware so a `//` inside a quoted value survives.
  static func stripJsonComments(_ data: Data) -> Data {
    guard var text = String(data: data, encoding: .utf8) else { return data }
    var result = ""
    result.reserveCapacity(text.count)
    var inString = false
    var escaped = false
    var index = text.startIndex
    while index < text.endIndex {
      let char = text[index]
      if inString {
        result.append(char)
        if escaped {
          escaped = false
        } else if char == "\\" {
          escaped = true
        } else if char == "\"" {
          inString = false
        }
        index = text.index(after: index)
        continue
      }
      if char == "\"" {
        inString = true
        result.append(char)
        index = text.index(after: index)
        continue
      }
      if char == "/", index < text.endIndex {
        let next = text.index(after: index)
        if next < text.endIndex {
          let nextChar = text[next]
          if nextChar == "/" {
            // skip to end of line
            while index < text.endIndex, text[index] != "\n" {
              index = text.index(after: index)
            }
            continue
          } else if nextChar == "*" {
            index = text.index(after: next)
            var closed = false
            while index < text.endIndex {
              if text[index] == "*" {
                let afterStar = text.index(after: index)
                if afterStar < text.endIndex, text[afterStar] == "/" {
                  index = text.index(after: afterStar)
                  closed = true
                  break
                }
              }
              index = text.index(after: index)
            }
            if !closed {
              // unterminated block comment — drop the rest
              break
            }
            continue
          }
        }
      }
      result.append(char)
      index = text.index(after: index)
    }
    return Data(result.utf8)
  }
}
