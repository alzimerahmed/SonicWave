//
//  SsPlayQueueParserDelegate.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 15.02.26.
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

// MARK: - SsPlayQueueParserDelegate

/// Parses the `getPlayQueue` response (G9). Unlike the other delegates it
/// intentionally touches no CoreData objects: the play queue is resolved
/// to existing Song entities by `PlayQueueSyncer` — queue entries whose
/// songs are not synced locally yet must not spawn stub entities.
///
/// Response shape:
/// `<playQueue current="id" position="ms" changed="ISO8601" changedBy="client">`
///   `<entry .../>` (ordered song children)
/// `</playQueue>`
class SsPlayQueueParserDelegate: SsXmlParser {
  private var isInsidePlayQueue = false
  private var orderedSongIds = [String]()
  private var currentSongId: String?
  private var positionInMilliseconds = 0
  private var changedDate: Date?
  private var changedBy: String?
  private var playQueueDetected = false

  /// `nil` when the response carried no `<playQueue>` element at all
  var remotePlayQueue: RemotePlayQueue? {
    guard playQueueDetected else { return nil }
    return RemotePlayQueue(
      songIds: orderedSongIds,
      currentSongId: currentSongId,
      positionInMilliseconds: positionInMilliseconds,
      changedDate: changedDate,
      changedBy: changedBy
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

    if elementName == "playQueue" {
      playQueueDetected = true
      isInsidePlayQueue = true
      currentSongId = attributeDict["current"]
      positionInMilliseconds = Int(attributeDict["position"] ?? "0") ?? 0
      changedDate = SubsonicDateParser.parse(attributeDict["changed"])
      changedBy = attributeDict["changedBy"]
      return
    }

    if isInsidePlayQueue,
       elementName == "entry" || elementName == "song" || elementName == "child",
       let songId = attributeDict["id"] {
      let isDirectory = Bool(attributeDict["isDir"] ?? "false") ?? false
      if !isDirectory {
        orderedSongIds.append(songId)
      }
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "playQueue" {
      isInsidePlayQueue = false
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
