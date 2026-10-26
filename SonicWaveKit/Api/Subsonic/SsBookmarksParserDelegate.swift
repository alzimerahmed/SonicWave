//
//  SsBookmarksParserDelegate.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 27.02.26.
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

// MARK: - SsBookmarksParserDelegate

/// Parses the `getBookmarks` response (G19) into DTOs — no CoreData:
/// bookmarked media ids are resolved to local entities by the caller,
/// entries not synced locally stay display-only.
///
/// Response shape:
/// `<bookmarks>`
///   `<bookmark position="ms" username="…" comment="…" created="ISO8601" changed="ISO8601">`
///     `<entry id="…" title="…" artist="…" album="…" duration="s"/>`
///   `</bookmark>`
/// `</bookmarks>`
class SsBookmarksParserDelegate: SsXmlParser {
  private(set) var bookmarks = [ServerBookmark]()
  private var currentBookmark: ServerBookmark?

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

    if elementName == "bookmark" {
      currentBookmark = ServerBookmark(
        id: "",
        positionSeconds: (Int(attributeDict["position"] ?? "0") ?? 0) / 1000,
        username: attributeDict["username"],
        created: SubsonicDateParser.parse(attributeDict["created"]),
        changed: SubsonicDateParser.parse(attributeDict["changed"]),
        comment: attributeDict["comment"]
      )
      return
    }

    if currentBookmark != nil, elementName == "entry", let mediaId = attributeDict["id"] {
      currentBookmark?.id = mediaId
      currentBookmark?.entry = JukeboxEntry(
        id: mediaId,
        title: attributeDict["title"],
        artistName: attributeDict["artist"],
        albumName: attributeDict["album"],
        durationSeconds: Int(attributeDict["duration"] ?? "0") ?? 0
      )
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "bookmark", let bookmark = currentBookmark {
      // a bookmark without a media entry is useless — keep only resolvable ones
      if !bookmark.id.isEmpty {
        bookmarks.append(bookmark)
      }
      currentBookmark = nil
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
