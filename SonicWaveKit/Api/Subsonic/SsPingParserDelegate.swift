//
//  SsPingParserDelegate.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 16.05.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import os.log

class SsPingParserDelegate: SsXmlParser {
  var isAuthValid: Bool = false
  var serverApiVersion: String?
  /// G8: OpenSubsonic server product attributes emitted by Navidrome/
  /// Gonic/LMS on the root element (`type="navidrome"`,
  /// `serverVersion="0.60.2"`) — the server-product feature gate.
  var serverType: String?
  var serverProductVersion: String?

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
    case "subsonic-response":
      if let version = attributeDict["version"] {
        serverApiVersion = version
      }
      if let type = attributeDict["type"] {
        serverType = type
      }
      if let serverVersion = attributeDict["serverVersion"] {
        serverProductVersion = serverVersion
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
    switch elementName {
    case "subsonic-response":
      if error == nil {
        isAuthValid = true
      }
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
