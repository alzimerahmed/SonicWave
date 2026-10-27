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
/// to server-generated share links. Scheme/host/port/userinfo are replaced
/// and the override's path component is prepended so a subpath-proxied
/// server (`https://example.com/music/`) hands out working links — query
/// and fragment are preserved untouched. Pure function for testability.
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
    // the override may carry a subpath (reverse proxy) — prepend it so
    // `/share/<id>` resolves under `/music/share/<id>`, not the domain root
    let basePath = baseComp.path
    if !basePath.isEmpty, basePath != "/" {
      urlComp.path = basePath.hasSuffix("/")
        ? basePath + urlComp.path.dropFirst()
        : basePath + urlComp.path
    }
    return urlComp.string ?? urlString
  }
}

// MARK: - JukeboxEntry

/// G11/G19: a media entry as reported inside server playlists — jukebox
/// playlist entries and bookmark `<entry>` children share this shape.
/// Display-only DTO: resolve to a local `Song`/`PodcastEpisode` via
/// `LibraryStorage` when a playable object is needed.
public struct JukeboxEntry: Sendable, Equatable {
  /// media file id on the server (song / podcast episode / video id)
  public var id: String
  public var title: String?
  public var artistName: String?
  public var albumName: String?
  public var durationSeconds: Int

  public init(
    id: String,
    title: String? = nil,
    artistName: String? = nil,
    albumName: String? = nil,
    durationSeconds: Int = 0
  ) {
    self.id = id
    self.title = title
    self.artistName = artistName
    self.albumName = albumName
    self.durationSeconds = durationSeconds
  }
}

// MARK: - JukeboxPlaylist

/// G11: server-side jukebox playlist state (Subsonic `jukeboxControl
/// action=get` / Ampache `localplay` + `localplay_songs`). `isPlaying` is
/// real transport state for Subsonic only — Ampache `localplay_songs`
/// carries no play state at all, so Ampache payloads always report
/// `false` rather than guess.
public struct JukeboxPlaylist: Sendable, Equatable {
  public var currentIndex: Int
  public var isPlaying: Bool
  /// playback gain 0...1 — Subsonic only (`setGain`); `nil` when the
  /// backend reports no absolute volume (Ampache localplay)
  public var gain: Double?
  /// position of the currently playing track in seconds (Subsonic only)
  public var positionSeconds: Int?
  public var entries: [JukeboxEntry]

  public init(
    currentIndex: Int = 0,
    isPlaying: Bool = false,
    gain: Double? = nil,
    positionSeconds: Int? = nil,
    entries: [JukeboxEntry] = []
  ) {
    self.currentIndex = currentIndex
    self.isPlaying = isPlaying
    self.gain = gain
    self.positionSeconds = positionSeconds
    self.entries = entries
  }
}

// MARK: - JukeboxAction

/// G11: remote jukebox commands mapped onto `BackendApi.jukeboxControl`.
/// Per-backend mapping: Subsonic `jukeboxControl` takes every action;
/// Ampache `localplay` maps `.start`→`play`, `.stop`→`stop`,
/// `.skip`→`skip`, `.add`→`add&oid` (repeated), `.clear`→`delete_all` —
/// `.set` and `.setGain` have no honest Ampache equivalent (no positional
/// select, volume is relative only) and answer `.notSupported`.
public enum JukeboxAction: Sendable, Equatable {
  /// `jukeboxControl action=get` — reads the playlist without touching
  /// transport state (Subsonic answers `<jukeboxStatus>`)
  case get
  case start
  case stop
  /// jump to the playlist entry at `index` (0-based), `offsetSeconds`
  /// into it — Subsonic only; Ampache has a next-only `skip` command, so
  /// it verifies `index == currentIndex + 1` before issuing the request
  /// (any other target has no honest Ampache equivalent → `.notSupported`)
  case skip(index: Int, offsetSeconds: Int)
  /// append media file ids to the jukebox playlist
  case add(ids: [String])
  case clear
  /// select the current entry without changing play state (Subsonic only)
  case set(index: Int)
  /// absolute playback gain 0...1 (Subsonic only)
  case setGain(Float)
}

// MARK: - ServerBookmark

/// G19: a server-side bookmark (saved playback position). Subsonic
/// `getBookmarks`/`createBookmark`/`deleteBookmark`; Ampache `bookmarks`/
/// `bookmark_create`/`bookmark_delete`. Positions are SECONDS — Subsonic
/// transports them in milliseconds and the API layer converts.
public struct ServerBookmark: Sendable, Equatable, Identifiable {
  /// media file id the bookmark points at (song/podcast episode id)
  public var id: String
  /// `"song"`/`"podcast_episode"`/`"video"` — Subsonic does not carry a
  /// type, so it is empty there and the UI resolves id → local entity
  public var objectType: String
  public var positionSeconds: Int
  public var username: String?
  public var clientName: String?
  public var created: Date?
  public var changed: Date?
  public var comment: String?
  /// display hints from the `<entry>` child (Subsonic only)
  public var entry: JukeboxEntry?

  public init(
    id: String,
    objectType: String = "",
    positionSeconds: Int = 0,
    username: String? = nil,
    clientName: String? = nil,
    created: Date? = nil,
    changed: Date? = nil,
    comment: String? = nil,
    entry: JukeboxEntry? = nil
  ) {
    self.id = id
    self.objectType = objectType
    self.positionSeconds = positionSeconds
    self.username = username
    self.clientName = clientName
    self.created = created
    self.changed = changed
    self.comment = comment
    self.entry = entry
  }
}

// MARK: - MusicFolderStub

/// G23: a server music folder (Subsonic `getMusicFolders` / Ampache
/// catalogs) as a lightweight DTO for pickers — unlike the `MusicFolder`
/// CoreData mirror it exists without a library sync.
public struct MusicFolderStub: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
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
