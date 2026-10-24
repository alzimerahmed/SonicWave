//
//  DiscoveryModels.swift
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

// MARK: - BackendFeatureResult

/// Typed capability-degradation envelope for the Phase-8 discovery surface
/// (G7/G8/G18/G20 + dislike). "Server can't do this" is data, not an error —
/// callers pattern-match `.notSupported` to hide UI affordances instead of
/// showing error banners. Real failures (network, auth, parse) still throw.
public enum BackendFeatureResult<Payload: Sendable>: Sendable {
  case supported(Payload)
  case notSupported

  public var payload: Payload? {
    if case .supported(let payload) = self { return payload }
    return nil
  }

  public var isSupported: Bool {
    payload != nil
  }

  public func map<T: Sendable>(_ transform: (Payload) -> T) -> BackendFeatureResult<T> {
    switch self {
    case .supported(let payload): return .supported(transform(payload))
    case .notSupported: return .notSupported
    }
  }
}

// MARK: - ArtistStub

/// Minimal remote artist reference returned by `getSimilarArtists` and inside
/// `ArtistInfo.similarArtists`. `id` may be nil when the server only provides
/// a name (e.g. Last.fm-sourced similar artists not in the user's library).
public struct ArtistStub: Sendable, Equatable {
  public var id: String?
  public var name: String

  public init(id: String?, name: String) {
    self.id = id
    self.name = name
  }
}

// MARK: - ArtistInfo

/// G20: `getArtistInfo2`/`getAlbumInfo` style enrichment payload. All fields
/// optional — Navidrome answers this endpoint only when external integrations
/// (Last.fm) are configured, so an all-nil payload is a valid `.supported`
/// result and must not be treated as failure.
public struct ArtistInfo: Sendable, Equatable {
  public var biography: String?
  public var musicBrainzId: String?
  public var lastFmUrl: String?
  public var smallImageUrl: String?
  public var mediumImageUrl: String?
  public var largeImageUrl: String?
  public var similarArtists: [ArtistStub]

  public init(
    biography: String? = nil,
    musicBrainzId: String? = nil,
    lastFmUrl: String? = nil,
    smallImageUrl: String? = nil,
    mediumImageUrl: String? = nil,
    largeImageUrl: String? = nil,
    similarArtists: [ArtistStub] = []
  ) {
    self.biography = biography
    self.musicBrainzId = musicBrainzId
    self.lastFmUrl = lastFmUrl
    self.smallImageUrl = smallImageUrl
    self.mediumImageUrl = mediumImageUrl
    self.largeImageUrl = largeImageUrl
    self.similarArtists = similarArtists
  }
}

// MARK: - AlbumInfo

/// G20: `getAlbumInfo`/`getAlbumInfo2` enrichment payload.
public struct AlbumInfo: Sendable, Equatable {
  public var notes: String?
  public var musicBrainzId: String?
  public var lastFmUrl: String?
  public var smallImageUrl: String?
  public var mediumImageUrl: String?
  public var largeImageUrl: String?

  public init(
    notes: String? = nil,
    musicBrainzId: String? = nil,
    lastFmUrl: String? = nil,
    smallImageUrl: String? = nil,
    mediumImageUrl: String? = nil,
    largeImageUrl: String? = nil
  ) {
    self.notes = notes
    self.musicBrainzId = musicBrainzId
    self.lastFmUrl = lastFmUrl
    self.smallImageUrl = smallImageUrl
    self.mediumImageUrl = mediumImageUrl
    self.largeImageUrl = largeImageUrl
  }
}

// MARK: - RemoteSongInfo

/// G20: song entry as returned by `getTopSongs` — a server-side descriptor,
/// NOT a CoreData-backed entity. Resolve to local `Song` via
/// `LibraryStorage.getSong(for:id:)` when a playable object is needed;
/// unsynced entries stay display-only.
public struct RemoteSongInfo: Sendable, Equatable {
  public var id: String
  public var title: String
  public var artistName: String?
  public var albumName: String?
  public var duration: Int
  public var year: Int
  public var coverArtId: String?

  public init(
    id: String,
    title: String,
    artistName: String? = nil,
    albumName: String? = nil,
    duration: Int = 0,
    year: Int = 0,
    coverArtId: String? = nil
  ) {
    self.id = id
    self.title = title
    self.artistName = artistName
    self.albumName = albumName
    self.duration = duration
    self.year = year
    self.coverArtId = coverArtId
  }
}

// MARK: - RemoteAlbumInfo

/// G20: album entry as returned by `getAlbumList2 type=byYear` (decade
/// browse). Same resolve-via-`getAlbum` contract as `RemoteSongInfo`.
public struct RemoteAlbumInfo: Sendable, Equatable {
  public var id: String
  public var name: String
  public var artistName: String?
  public var artistId: String?
  public var year: Int
  public var coverArtId: String?

  public init(
    id: String,
    name: String,
    artistName: String? = nil,
    artistId: String? = nil,
    year: Int = 0,
    coverArtId: String? = nil
  ) {
    self.id = id
    self.name = name
    self.artistName = artistName
    self.artistId = artistId
    self.year = year
    self.coverArtId = coverArtId
  }
}

// MARK: - ShareableType

/// G18: entity classes that can be shared via `createShare`. Ampache needs
/// the type as an explicit API parameter; Subsonic infers it from the id.
public enum ShareableType: String, Sendable, Codable, CaseIterable {
  case song
  case album
  case artist
  case playlist
}

// MARK: - ShareDescription

/// G18: a public share link as reported by `getShares`/`createShare`/
/// `updateShare`. `url` is the post-override URL — when the account's
/// `publicUrlOverride` is set the API layer rewrites scheme+host+port so
/// reverse-proxied servers hand out reachable links.
public struct ShareDescription: Sendable, Equatable {
  public var id: String
  public var url: String
  public var description: String?
  public var username: String?
  public var created: Date?
  public var expires: Date?
  public var visitCount: Int
  /// ids of the shared objects (Subsonic `entry` children, Ampache object_id)
  public var sharedObjectIds: [String]

  public init(
    id: String,
    url: String,
    description: String? = nil,
    username: String? = nil,
    created: Date? = nil,
    expires: Date? = nil,
    visitCount: Int = 0,
    sharedObjectIds: [String] = []
  ) {
    self.id = id
    self.url = url
    self.description = description
    self.username = username
    self.created = created
    self.expires = expires
    self.visitCount = visitCount
    self.sharedObjectIds = sharedObjectIds
  }
}

// MARK: - ShareUrlRewriter

/// G18: applies the per-account `publicUrlOverride` (reverse-proxy base URL)
/// to server-generated share links. Only scheme/host/port/userinfo are
/// replaced — path, query and fragment are preserved so `/share/<id>`-style
/// server paths keep working. Pure function for testability.
public enum ShareUrlRewriter {
  public static func rewrite(urlString: String, publicBaseUrl override: String?) -> String {
    guard let override, !override.isEmpty,
          let baseComp = URLComponents(string: override),
          baseComp.host != nil,
          var urlComp = URLComponents(string: urlString)
    else { return urlString }
    urlComp.scheme = baseComp.scheme ?? urlComp.scheme
    urlComp.host = baseComp.host
    urlComp.port = baseComp.port
    urlComp.user = baseComp.user
    urlComp.password = baseComp.password
    return urlComp.string ?? urlString
  }
}

// MARK: - DislikeResolution

/// Dislike/thumbs-down (#587) server mapping outcome. Neither supported
/// backend exposes a real "dislike" concept: Subsonic `setRating(id, 0)`
/// would destroy the user's 0–5 star rating, and Ampache `flag` is already
/// the favorites channel (`requestSetFavorite`). The dislike flag is
/// therefore LOCAL-ONLY (`AbstractPlayableMO.isDisliked`, schema v51) on
/// both backends — `setDislike`/`clearDislike` report `.localOnly` so app
/// code persists the flag without a server round-trip. The enum stays for
/// future backends with a true server-side dislike.
public enum DislikeResolution: Sendable, Equatable {
  /// server accepted the dislike
  case serverSynced
  /// persist the flag locally only — no server call made
  case localOnly
}
