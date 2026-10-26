//
//  SsMusicFolderListParserDelegate.swift
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

// MARK: - SsMusicFolderListParserDelegate

/// Parses `getMusicFolders` into lightweight DTOs (G23) — unlike
/// `SsMusicFolderParserDelegate` it touches no CoreData: the folder
/// picker must work before any library sync ran.
class SsMusicFolderListParserDelegate: SsXmlParser {
  private(set) var musicFolders = [MusicFolderStub]()

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

    if elementName == "musicFolder",
       let id = attributeDict["id"], let name = attributeDict["name"] {
      musicFolders.append(MusicFolderStub(id: id, name: name))
    }
  }
}
