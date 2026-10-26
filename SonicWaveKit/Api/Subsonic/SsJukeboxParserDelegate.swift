//
//  SsJukeboxParserDelegate.swift
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

// MARK: - SsJukeboxParserDelegate

/// Parses the `jukeboxControl` response (G11). Since Subsonic API 1.2.0
/// every action answers `<jukeboxStatus …><entry …/></jukeboxStatus>`;
/// older servers answer `<jukeboxPlaylist>` for `action=get` — both
/// element names carry the same attribute set and are accepted.
class SsJukeboxParserDelegate: SsXmlParser {
  private var isInsidePlaylist = false
  private var entries = [JukeboxEntry]()
  private var currentIndex = 0
  private var isPlaying = false
  private var gain: Double?
  private var positionSeconds: Int?
  private var playlistDetected = false

  /// `nil` when the response carried no playlist element at all
  var jukeboxPlaylist: JukeboxPlaylist? {
    guard playlistDetected else { return nil }
    return JukeboxPlaylist(
      currentIndex: currentIndex,
      isPlaying: isPlaying,
      gain: gain,
      positionSeconds: positionSeconds,
      entries: entries
    )
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

    if elementName == "jukeboxStatus" || elementName == "jukeboxPlaylist" {
      playlistDetected = true
      isInsidePlaylist = true
      currentIndex = Int(attributeDict["currentIndex"] ?? "0") ?? 0
      isPlaying = Bool(attributeDict["playing"] ?? "false") ?? false
      gain = Double(attributeDict["gain"] ?? "")
      positionSeconds = Int(attributeDict["position"] ?? "")
      return
    }

    if isInsidePlaylist, elementName == "entry", let mediaId = attributeDict["id"] {
      entries.append(JukeboxEntry(
        id: mediaId,
        title: attributeDict["title"],
        artistName: attributeDict["artist"],
        albumName: attributeDict["album"],
        durationSeconds: Int(attributeDict["duration"] ?? "0") ?? 0
      ))
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "jukeboxStatus" || elementName == "jukeboxPlaylist" {
      isInsidePlaylist = false
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
