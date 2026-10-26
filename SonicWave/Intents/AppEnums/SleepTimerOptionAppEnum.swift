//
//  SleepTimerOptionAppEnum.swift
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

import AppIntents
import Foundation

enum SleepTimerOptionAppEnum: Int, AppEnum {
  case off
  case endOfTrack
  case minutes5
  case minutes10
  case minutes15
  case minutes30
  case minutes45
  case minutes60
  case minutes120
  case minutes240

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep Timer")
  /// titles come from `displayName` — single source of truth so the
  /// Shortcuts picker and the spoken dialogs can't drift
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .off: DisplayRepresentation(
      title: "\(SleepTimerOptionAppEnum.off.displayName)",
      image: .init(systemName: "moon.zzz")
    ),
    .endOfTrack: DisplayRepresentation(
      title: "\(SleepTimerOptionAppEnum.endOfTrack.displayName)",
      image: .init(systemName: "music.note"),
      synonyms: ["end of song", "end of episode", "after this track"]
    ),
    .minutes5: "\(SleepTimerOptionAppEnum.minutes5.displayName)",
    .minutes10: "\(SleepTimerOptionAppEnum.minutes10.displayName)",
    .minutes15: "\(SleepTimerOptionAppEnum.minutes15.displayName)",
    .minutes30: "\(SleepTimerOptionAppEnum.minutes30.displayName)",
    .minutes45: "\(SleepTimerOptionAppEnum.minutes45.displayName)",
    .minutes60: DisplayRepresentation(
      title: "\(SleepTimerOptionAppEnum.minutes60.displayName)",
      synonyms: ["60 minutes", "one hour"]
    ),
    .minutes120: DisplayRepresentation(
      title: "\(SleepTimerOptionAppEnum.minutes120.displayName)",
      synonyms: ["120 minutes", "two hours"]
    ),
    .minutes240: DisplayRepresentation(
      title: "\(SleepTimerOptionAppEnum.minutes240.displayName)",
      synonyms: ["240 minutes", "four hours"]
    ),
  ]

  /// countdown in seconds — `nil` for the non-timer modes (`.off` and
  /// `.endOfTrack`), which map to flag changes instead of a `Timer`
  var timeInterval: TimeInterval? {
    switch self {
    case .off, .endOfTrack: return nil
    case .minutes5: return 5 * 60
    case .minutes10: return 10 * 60
    case .minutes15: return 15 * 60
    case .minutes30: return 30 * 60
    case .minutes45: return 45 * 60
    case .minutes60: return 60 * 60
    case .minutes120: return 2 * 60 * 60
    case .minutes240: return 4 * 60 * 60
    }
  }

  var displayName: String {
    switch self {
    case .off: return "Off"
    case .endOfTrack: return "End of Track"
    case .minutes5: return "5 Minutes"
    case .minutes10: return "10 Minutes"
    case .minutes15: return "15 Minutes"
    case .minutes30: return "30 Minutes"
    case .minutes45: return "45 Minutes"
    case .minutes60: return "1 Hour"
    case .minutes120: return "2 Hours"
    case .minutes240: return "4 Hours"
    }
  }
}
