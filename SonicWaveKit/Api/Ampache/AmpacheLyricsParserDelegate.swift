//
//  AmpacheLyricsParserDelegate.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 24.10.26.
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

// MARK: - AmpacheLyricsParserDelegate

/// Extracts the plain `<lyrics>` field from an Ampache `song` response —
/// available since Ampache API 5.4.1 ("Include lyrics in Song objects").
/// Lyrics are plain text on Ampache (multi-line CDATA) — no timestamps.
class AmpacheLyricsParserDelegate: AmpacheXmlParser {
  var lyricsText: String?
  private var isInsideLyricsElement = false

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
    if elementName == "lyrics" {
      isInsideLyricsElement = true
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "lyrics", isInsideLyricsElement {
      isInsideLyricsElement = false
      let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        lyricsText = text
      }
    }
    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
