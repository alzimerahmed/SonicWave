//
//  SmartPlaylistEvaluator.swift
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

// MARK: - SmartPlaylistResolution

/// Result of resolving a playlist through `SmartPlaylistEvaluator`:
/// - `.localCriteria`: evaluated against the CoreData mirror — authoritative
///   for user-authored smart playlists and for imported `.nsp` playlists
///   whose rules mapped completely.
/// - `.serverResolved`: the playlist items synced from the server — used
///   when no criteria exist or when imported rules were only partially
///   mappable (`partiallyEvaluated` flags it so the UI can badge it).
public enum SmartPlaylistResolution {
  case localCriteria(songs: [Song])
  case serverResolved(playables: [AbstractPlayable], partiallyEvaluated: Bool)
}

// MARK: - SmartPlaylistEvaluator

/// G8: resolves `SmartPlaylistCriteria` into playable songs.
///
/// - Local criteria → `SongMO` fetch (account-scoped, server-delete filtered,
///   criteria predicate + sort + limit).
/// - Imported server playlists → criteria are evaluated locally when the
///   rules mapped; the server-resolved `Playlist` items are the fallback
///   (and the ONLY correct answer when `unsupportedNotes` is non-empty —
///   the server evaluates fields we can't, like `bpm` or `inPlaylist`).
///
/// All reads happen on the main context via `PersistentStorage.main` —
/// matches the wrapper-entity access pattern used by the VCs.
@MainActor
public class SmartPlaylistEvaluator {
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "SmartPlaylist")
  private let storage: PersistentStorage
  private let account: Account

  public init(storage: PersistentStorage, account: Account) {
    self.storage = storage
    self.account = account
  }

  /// Evaluates criteria against the local library mirror. Random-limit picks
  /// (`.nsp` `sort: random` imports note as unsupported and arrive here with
  /// `sort == nil`) are handled by `randomPickLimit` — pass a count to get
  /// a random subset instead of the full match set.
  public func evaluate(criteria: SmartPlaylistCriteria, randomPickLimit: Int? = nil) -> [Song] {
    var songs = [Song]()
    // `CoreDataCompanion.perform` wraps `performAndWait` — safe to capture
    // the result out of the closure like the syncers do
    storage.main.perform { companion in
      let basePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        companion.library.getFetchPredicate(forAccount: self.account),
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
        criteria.predicate(),
      ])
      if let randomPickLimit {
        // fetch all matches, pick randomly — keeps `sort: random` mixes fresh
        let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
        fetchRequest.predicate = basePredicate
        let found = (try? companion.context.fetch(fetchRequest)) ?? []
        songs = found[randomPick: randomPickLimit].compactMap { Song(managedObject: $0) }
      } else {
        let fetchRequest = criteria.songFetchRequest()
        fetchRequest.predicate = basePredicate
        let found = (try? companion.context.fetch(fetchRequest)) ?? []
        songs = found.compactMap { Song(managedObject: $0) }
      }
    }
    return songs
  }

  /// Resolves a playlist to its playable list. `criteria` is `nil` for plain
  /// playlists; when present it is used for local evaluation only if every
  /// rule is locally evaluable — partially-mapped `.nsp` imports keep the
  /// server-resolved item list so the playlist matches Navidrome's view.
  public func resolve(
    playlist: Playlist,
    criteria: SmartPlaylistCriteria?
  ) -> SmartPlaylistResolution {
    guard let criteria, !criteria.rules.isEmpty else {
      return .serverResolved(playables: playlist.playables, partiallyEvaluated: false)
    }
    let isFullyEvaluable = criteria.unsupportedNotes.isEmpty
      && criteria.rules.allSatisfy { $0.isLocallyEvaluable }
    if isFullyEvaluable {
      let songs = evaluate(criteria: criteria)
      // an imported smart playlist whose local eval is empty can mean the
      // mirror is behind the server — degrade to synced items, don't empty-play
      if !songs.isEmpty || !criteria.isImportedFromServer {
        return .localCriteria(songs: songs)
      }
      return .serverResolved(playables: playlist.playables, partiallyEvaluated: true)
    }
    return .serverResolved(playables: playlist.playables, partiallyEvaluated: true)
  }
}
