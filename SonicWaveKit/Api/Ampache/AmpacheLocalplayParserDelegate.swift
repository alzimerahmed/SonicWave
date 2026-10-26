//
//  AmpacheLocalplayParserDelegate.swift
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

// MARK: - AmpacheLocalplaySongsParserDelegate

/// Parses `localplay_songs` (G11) into display DTOs — no CoreData.
/// Ampache emits standard `<song>` elements with nested `<artist>`/
/// `<album>` containers; their `<name>` children land in the same text
/// buffer, so the parent element is tracked to route names correctly.
class AmpacheLocalplaySongsParserDelegate: AmpacheXmlParser {
  private(set) var entries = [JukeboxEntry]()
  private var currentEntry: JukeboxEntry?
  /// which container's `<name>` we are reading: song/artist/album
  private var nameOwner = ""

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
    case "song":
      currentEntry = JukeboxEntry(id: attributeDict["id"] ?? "")
      nameOwner = "song"
    case "artist" where currentEntry != nil:
      nameOwner = "artist"
    case "album" where currentEntry != nil:
      nameOwner = "album"
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
    let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "name":
      switch nameOwner {
      case "song": currentEntry?.title = text
      case "artist": currentEntry?.artistName = text
      case "album": currentEntry?.albumName = text
      default: break
      }
    case "title" where nameOwner == "song":
      currentEntry?.title = text
    case "time":
      currentEntry?.durationSeconds = Int(text) ?? 0
    case "artist", "album":
      nameOwner = "song"
    case "song":
      if let entry = currentEntry, !entry.id.isEmpty {
        entries.append(entry)
      }
      currentEntry = nil
      nameOwner = ""
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
