//
//  SsDiscoveryParserDelegate.swift
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

// MARK: - SsArtistInfoParserDelegate

/// G20: `getArtistInfo2`/`getArtistInfo` — DTO-only, touches no CoreData.
///
///     <artistInfo2 biography="..." musicBrainzId="..." lastFmUrl="..."
///                  smallImageUrl="..." mediumImageUrl="..." largeImageUrl="...">
///       <similarArtist id="..." name="..."/>
///     </artistInfo2>
class SsArtistInfoParserDelegate: SsXmlParser {
  private(set) var artistInfo = ArtistInfo()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    switch elementName {
    case "artistInfo", "artistInfo2":
      artistInfo.biography = attributeDict["biography"]
      artistInfo.musicBrainzId = attributeDict["musicBrainzId"]
      artistInfo.lastFmUrl = attributeDict["lastFmUrl"]
      artistInfo.smallImageUrl = attributeDict["smallImageUrl"]
      artistInfo.mediumImageUrl = attributeDict["mediumImageUrl"]
      artistInfo.largeImageUrl = attributeDict["largeImageUrl"]
    case "similarArtist":
      if let name = attributeDict["name"] {
        artistInfo.similarArtists.append(
          ArtistStub(id: attributeDict["id"], name: name)
        )
      }
    default:
      break
    }
  }
}

// MARK: - SsAlbumInfoParserDelegate

/// G20: `getAlbumInfo`/`getAlbumInfo2`.
///
///     <albumInfo notes="..." musicBrainzId="..." lastFmUrl="..."
///                smallImageUrl="..." mediumImageUrl="..." largeImageUrl="..."/>
class SsAlbumInfoParserDelegate: SsXmlParser {
  private(set) var albumInfo = AlbumInfo()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    if elementName == "albumInfo" || elementName == "albumInfo2" {
      albumInfo.notes = attributeDict["notes"]
      albumInfo.musicBrainzId = attributeDict["musicBrainzId"]
      albumInfo.lastFmUrl = attributeDict["lastFmUrl"]
      albumInfo.smallImageUrl = attributeDict["smallImageUrl"]
      albumInfo.mediumImageUrl = attributeDict["mediumImageUrl"]
      albumInfo.largeImageUrl = attributeDict["largeImageUrl"]
    }
  }
}

// MARK: - SsTopSongsParserDelegate

/// G20: `getTopSongs` — remote song descriptors, no CoreData writes
/// (unsynced top songs stay display-only by design).
///
///     <topSongs>
///       <song id="..." title="..." artist="..." album="..."
///             duration="..." year="..." coverArt="..."/>
///     </topSongs>
class SsTopSongsParserDelegate: SsXmlParser {
  private(set) var topSongs = [RemoteSongInfo]()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    guard elementName == "song", let id = attributeDict["id"] else { return }
    topSongs.append(RemoteSongInfo(
      id: id,
      title: attributeDict["title"] ?? "",
      artistName: attributeDict["artist"],
      albumName: attributeDict["album"],
      duration: Int(attributeDict["duration"] ?? "0") ?? 0,
      year: Int(attributeDict["year"] ?? "0") ?? 0,
      coverArtId: attributeDict["coverArt"]
    ))
  }
}

// MARK: - SsAlbumListParserDelegate

/// G20: `getAlbumList2 type=byYear` (decade browse) — remote album
/// descriptors, no CoreData writes.
///
///     <albumList2>
///       <album id="..." name="..." artist="..." artistId="..."
///              year="..." coverArt="..."/>
///     </albumList2>
class SsAlbumListParserDelegate: SsXmlParser {
  private(set) var albums = [RemoteAlbumInfo]()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    guard elementName == "album", let id = attributeDict["id"] else { return }
    albums.append(RemoteAlbumInfo(
      id: id,
      name: attributeDict["name"] ?? "",
      artistName: attributeDict["artist"],
      artistId: attributeDict["artistId"],
      year: Int(attributeDict["year"] ?? "0") ?? 0,
      coverArtId: attributeDict["coverArt"]
    ))
  }
}

// MARK: - SsSimilarArtistsParserDelegate

/// G20: `getSimilarArtists2` — remote artist stubs.
///
///     <similarArtists2>
///       <artist id="..." name="..."/>
///     </similarArtists2>
class SsSimilarArtistsParserDelegate: SsXmlParser {
  private(set) var similarArtists = [ArtistStub]()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    guard elementName == "artist", let name = attributeDict["name"] else { return }
    similarArtists.append(ArtistStub(id: attributeDict["id"], name: name))
  }
}

// MARK: - SsSharesParserDelegate

/// G18: `getShares`/`createShare`/`updateShare` — DTO-only.
///
///     <shares>
///       <share id="..." url="..." description="..." username="..."
///              created="ISO8601" expires="ISO8601" visitCount="0">
///         <entry id="..."/>
///       </share>
///     </shares>
class SsSharesParserDelegate: SsXmlParser {
  private(set) var shares = [ShareDescription]()
  private var currentEntryIds = [String]()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    switch elementName {
    case "share":
      currentEntryIds = []
      guard let id = attributeDict["id"] else { return }
      shares.append(ShareDescription(
        id: id,
        url: attributeDict["url"] ?? "",
        description: attributeDict["description"],
        username: attributeDict["username"],
        created: SubsonicDateParser.parse(attributeDict["created"]),
        expires: SubsonicDateParser.parse(attributeDict["expires"]),
        visitCount: Int(attributeDict["visitCount"] ?? "0") ?? 0,
        sharedObjectIds: []
      ))
    case "entry":
      if let entryId = attributeDict["id"] {
        currentEntryIds.append(entryId)
      }
    default:
      break
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "share", !shares.isEmpty {
      shares[shares.count - 1].sharedObjectIds = currentEntryIds
      currentEntryIds = []
    }
    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
