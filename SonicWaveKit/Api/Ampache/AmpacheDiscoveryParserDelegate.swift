//
//  AmpacheDiscoveryParserDelegate.swift
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

// MARK: - AmpacheArtistInfoParserDelegate

/// G20: Ampache `artist` action response — attribute-driven DTO parse
/// (mbid + summary are the Ampache bio fields; no Last.fm equivalents).
/// Also parses `get_similar type=artist` result lists (same element shape).
class AmpacheArtistInfoParserDelegate: AmpacheXmlParser {
  private(set) var artistInfo = ArtistInfo()
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
    guard elementName == "artist" else { return }
    if let mbid = attributeDict["mbid"], !mbid.isEmpty {
      artistInfo.musicBrainzId = mbid
    }
    if let summary = attributeDict["summary"], !summary.isEmpty {
      artistInfo.biography = summary
    }
    if let name = attributeDict["name"] {
      similarArtists.append(ArtistStub(id: attributeDict["id"], name: name))
    }
  }
}

// MARK: - AmpacheAlbumInfoParserDelegate

/// G20: Ampache `album` action response — mbid is the enrichment payload;
/// Ampache albums carry no bio/notes field.
class AmpacheAlbumInfoParserDelegate: AmpacheXmlParser {
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
    guard elementName == "album" else { return }
    if let mbid = attributeDict["mbid"], !mbid.isEmpty {
      albumInfo.musicBrainzId = mbid
    }
    if let notes = attributeDict["summary"], !notes.isEmpty {
      albumInfo.notes = notes
    }
  }
}

// MARK: - AmpacheSharesParserDelegate

/// G18: Ampache `shares`/`share_create`/`share_edit` — `<share>` elements
/// with epoch-second timestamps and a `public_url` attribute.
class AmpacheSharesParserDelegate: AmpacheXmlParser {
  private(set) var shares = [ShareDescription]()

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
    guard elementName == "share", let id = attributeDict["id"] else { return }
    shares.append(ShareDescription(
      id: id,
      url: attributeDict["public_url"] ?? "",
      description: attributeDict["description"],
      username: attributeDict["owner"],
      created: epochDate(attributeDict["creation_date"]),
      expires: epochDate(attributeDict["expire"]),
      visitCount: Int(attributeDict["visit_counter"] ?? "0") ?? 0,
      sharedObjectIds: attributeDict["object_id"].map { [$0] } ?? []
    ))
  }

  private func epochDate(_ value: String?) -> Date? {
    guard let value, let seconds = TimeInterval(value), seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }
}
