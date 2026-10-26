//
//  PlaybackRateAppEnum.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 25.10.26.
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

import SonicWaveKit
import AppIntents
import Foundation

enum PlaybackRateAppEnum: Int, AppEnum {
  case dot5 = 0
  case dot75
  case one
  case oneDot25
  case oneDot5
  case oneDot75
  case two

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Rate")
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .dot5: DisplayRepresentation(
      title: "0.5x",
      synonyms: ["half speed", "half-speed"]
    ),
    .dot75: DisplayRepresentation(
      title: "0.75x",
      synonyms: ["three-quarter speed", "three quarter speed"]
    ),
    .one: DisplayRepresentation(
      title: "1x",
      synonyms: ["normal speed", "regular speed"]
    ),
    .oneDot25: DisplayRepresentation(
      title: "1.25x",
      synonyms: ["one and a quarter speed", "one point two five"]
    ),
    .oneDot5: DisplayRepresentation(
      title: "1.5x",
      synonyms: ["one and a half speed", "one point five"]
    ),
    .oneDot75: DisplayRepresentation(
      title: "1.75x",
      synonyms: ["one and three-quarter speed", "one point seven five"]
    ),
    .two: DisplayRepresentation(
      title: "2x",
      synonyms: ["double speed", "twice as fast"]
    ),
  ]

  /// `PlaybackRateAppEnum` mirrors `PlaybackRate`'s raw values one-to-one
  var playbackRate: PlaybackRate {
    PlaybackRate(rawValue: rawValue) ?? .one
  }
}
