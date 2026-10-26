//
//  AmpacheBookmarksParserDelegate.swift
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

// MARK: - AmpacheBookmarksParserDelegate

/// Parses the Ampache `bookmarks` answer (G19) into DTOs — no CoreData.
///
/// Response shape:
/// `<root><bookmark id="3"><user>…</user><object_type>song</object_type>`
/// `<object_id>115</object_id><position>10</position><client>…</client>`
/// `<creation_date>unixtime</creation_date><update_date>…</update_date>`
/// `</bookmark>…</root>`
/// `position` is SECONDS (Ampache) — no millisecond conversion here.
class AmpacheBookmarksParserDelegate: AmpacheXmlParser {
  private(set) var bookmarks = [ServerBookmark]()
  private var currentBookmark: ServerBookmark?
  /// `update_date` beats `creation_date` for "when was it touched"
  private var currentUpdateDate: Date?

  private static func unixDate(_ raw: String) -> Date? {
    guard let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

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
      currentBookmark = ServerBookmark(id: "")
      currentUpdateDate = nil
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch elementName {
    case "user":
      currentBookmark?.username = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    case "object_type":
      currentBookmark?.objectType = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    case "object_id":
      currentBookmark?.id = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    case "position":
      currentBookmark?.positionSeconds = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    case "client":
      currentBookmark?.clientName = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    case "creation_date":
      currentBookmark?.created = Self.unixDate(buffer)
    case "update_date":
      currentUpdateDate = Self.unixDate(buffer)
    case "bookmark":
      if var bookmark = currentBookmark, !bookmark.id.isEmpty {
        bookmark.changed = currentUpdateDate
        bookmarks.append(bookmark)
      }
      currentBookmark = nil
    default:
      break
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
