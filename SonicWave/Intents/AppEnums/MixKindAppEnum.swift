//
//  MixKindAppEnum.swift
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

/// intent-facing mirror of `MixKind` (G7) — every case maps 1:1; the
/// seeded kinds (decade/genre) take their seed from the intent's
/// `mixParameter` string
enum MixKindAppEnum: Int, AppEnum {
  case favoritesRadio
  case decadeMix
  case genreBlend
  case deepCuts
  case timeOfDay

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mix")
  /// titles come from `displayName` — single source of truth so the
  /// Shortcuts picker and the spoken dialogs can't drift
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .favoritesRadio: DisplayRepresentation(
      title: "Favorites Radio",
      image: .init(systemName: "heart.fill")
    ),
    .decadeMix: DisplayRepresentation(
      title: "Decade Mix",
      image: .init(systemName: "calendar")
    ),
    .genreBlend: DisplayRepresentation(
      title: "Genre Blend",
      image: .init(systemName: "guitars.fill")
    ),
    .deepCuts: DisplayRepresentation(
      title: "Deep Cuts",
      image: .init(systemName: "sparkles")
    ),
    .timeOfDay: DisplayRepresentation(
      title: "Time Machine",
      image: .init(systemName: "clock")
    ),
  ]

  var mixKind: MixKind {
    switch self {
    case .favoritesRadio: return .favoritesRadio
    case .decadeMix: return .decadeMix
    case .genreBlend: return .genreBlend
    case .deepCuts: return .deepCuts
    case .timeOfDay: return .timeOfDay
    }
  }

  var displayName: String {
    switch self {
    case .favoritesRadio: return "Favorites Radio"
    case .decadeMix: return "Decade Mix"
    case .genreBlend: return "Genre Blend"
    case .deepCuts: return "Deep Cuts"
    case .timeOfDay: return "Time Machine"
    }
  }
}
