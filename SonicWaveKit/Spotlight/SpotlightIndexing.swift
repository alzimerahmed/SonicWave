//
//  SpotlightIndexing.swift
//  SonicWaveKit
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

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// `CSSearchableItem`/`CSSearchableIndex` are immutable-in-practice CoreSpotlight
// types that carry no Sendable annotations — hand-off to the indexer actor is
// safe once the item is fully constructed.
extension CSSearchableItem: @unchecked @retroactive Sendable {}
extension CSSearchableIndex: @unchecked @retroactive Sendable {}

// MARK: - SpotlightItemType

/// Library entity kinds mirrored into CoreSpotlight (G27).
/// The raw value doubles as the type tag inside
/// `SpotlightItemIdentifier.encoded`; the app target maps it 1:1 onto
/// `PlayableContainerTypeAppEnum` for tap-through resolution.
public enum SpotlightItemType: String, Sendable, CaseIterable {
  case song
  case podcastEpisode
  case album
  case artist
  case playlist
  case podcast

  /// CoreData entity name (model v51: no `MO` suffix) used by the
  /// initial full-index fetch.
  var entityName: String {
    switch self {
    case .song:
      return "Song"
    case .podcastEpisode:
      return "PodcastEpisode"
    case .album:
      return "Album"
    case .artist:
      return "Artist"
    case .playlist:
      return "Playlist"
    case .podcast:
      return "Podcast"
    }
  }
}

// MARK: - SpotlightItemIdentifier

/// Encoded `CSSearchableItem.uniqueIdentifier` — carries everything the
/// tap-through path needs because Spotlight only hands the identifier back
/// (no userInfo): `<type>:<accountIdent>:<entityId>`.
///
/// `accountIdent` is `serverHash-userHash` (SHA256 hex pairs — never
/// contains `:`), so splitting at the first two `:` keeps opaque server ids
/// intact even if they contain `:` themselves. `domainIdentifier` =
/// `accountIdent` so a deleted account can be purged via
/// `deleteSearchableItems(withDomainIdentifiers:)`.
public struct SpotlightItemIdentifier: Sendable, Hashable {
  public let type: SpotlightItemType
  public let accountIdent: String
  /// server-side entity id (`AbstractLibraryEntity.id`)
  public let id: String

  public init(type: SpotlightItemType, accountIdent: String, id: String) {
    self.type = type
    self.accountIdent = accountIdent
    self.id = id
  }

  public init?(encoded: String) {
    let parts = encoded.split(
      separator: ":",
      maxSplits: 2,
      omittingEmptySubsequences: false
    )
    guard parts.count == 3,
          let type = SpotlightItemType(rawValue: String(parts[0])),
          !parts[1].isEmpty,
          !parts[2].isEmpty
    else { return nil }
    self.type = type
    accountIdent = String(parts[1])
    id = String(parts[2])
  }

  public var encoded: String {
    "\(type.rawValue):\(accountIdent):\(id)"
  }

  /// per-account grouping — every item of one account shares the domain so
  /// account teardown maps to a single domain delete
  public var domainIdentifier: String {
    accountIdent
  }
}

// MARK: - SpotlightEntityDescriptor

/// Sendable snapshot of everything a `CSSearchableItem` needs — built on the
/// CoreData context queue, materialized into an item afterwards so no
/// managed object ever leaves its context.
struct SpotlightEntityDescriptor: Sendable {
  let identifier: SpotlightItemIdentifier
  let title: String
  let contentDescription: String?
  let keywords: [String]
  /// cached lyric text (songs only), already length-capped
  let textContent: String?
  let rating: Int
  let playCount: Int
  let lastUsedDate: Date?
  let thumbnailFileURL: URL?
  let isAudioContent: Bool

  func makeSearchableItem() -> CSSearchableItem {
    let attributeSet = CSSearchableItemAttributeSet(
      contentType: isAudioContent ? .audio : .content
    )
    attributeSet.title = title
    attributeSet.contentDescription = contentDescription
    attributeSet.keywords = keywords
    attributeSet.textContent = textContent
    if rating > 0 {
      attributeSet.rating = NSNumber(value: rating)
    }
    if playCount > 0 {
      attributeSet.playCount = NSNumber(value: playCount)
    }
    attributeSet.lastUsedDate = lastUsedDate
    attributeSet.thumbnailURL = thumbnailFileURL
    return CSSearchableItem(
      uniqueIdentifier: identifier.encoded,
      domainIdentifier: identifier.domainIdentifier,
      attributeSet: attributeSet
    )
  }
}

// MARK: - SearchableIndexing

/// Thin async abstraction over `CSSearchableIndex` so the indexer logic is
/// unit-testable without a device/index (`MOCK_SearchableIndex` in tests).
public protocol SearchableIndexing: Sendable {
  func indexItems(_ items: [CSSearchableItem]) async throws
  func deleteItems(identifiers: [String]) async throws
  func deleteItems(domainIdentifiers: [String]) async throws
  func deleteAllItems() async throws
}

// MARK: - CSSearchableIndex + SearchableIndexing

extension CSSearchableIndex: SearchableIndexing {
  public func indexItems(_ items: [CSSearchableItem]) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      indexSearchableItems(items) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  public func deleteItems(identifiers: [String]) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      deleteSearchableItems(withIdentifiers: identifiers) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  public func deleteItems(domainIdentifiers: [String]) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  public func deleteAllItems() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      deleteAllSearchableItems { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}
