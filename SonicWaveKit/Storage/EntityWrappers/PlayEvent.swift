//
//  PlayEvent.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 26.10.26.
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

// MARK: - PlayEvent

/// G14 listening analytics: one row per finished listening session of a
/// song (start → pause/resume cycles → track change/stop). On-device
/// only — never uploaded; `ScrobbleEntry` stays the server-sync seam.
///
/// Track metadata is denormalized onto the row (`title`/`artistName`/
/// `albumName`/`genreName`) so history survives the playable's deletion:
/// the `playable` relationship is Nullify, not Cascade. Aggregation
/// groups by `playableId` when present, else by the denormalized names.
public class PlayEvent: NSObject {
  public let managedObject: PlayEventMO

  public init(managedObject: PlayEventMO) {
    self.managedObject = managedObject
  }

  public var account: Account? {
    get {
      guard let accountMO = managedObject.account else { return nil }
      return Account(managedObject: accountMO)
    }
    set {
      if managedObject.account != newValue?
        .managedObject { managedObject.account = newValue?.managedObject }
    }
  }

  /// the song that was playing; nil once the playable was deleted from
  /// the library — denormalized fields keep the event meaningful
  public var playable: AbstractPlayable? {
    get {
      guard let playableMO = managedObject.playable else { return nil }
      return AbstractPlayable(managedObject: playableMO)
    }
    set { managedObject.playable = newValue?.playableManagedObject }
  }

  public var date: Date? {
    get { managedObject.date }
    set { managedObject.date = newValue }
  }

  public var title: String? {
    get { managedObject.title }
    set { managedObject.title = newValue }
  }

  public var artistName: String? {
    get { managedObject.artistName }
    set { managedObject.artistName = newValue }
  }

  public var albumName: String? {
    get { managedObject.albumName }
    set { managedObject.albumName = newValue }
  }

  public var genreName: String? {
    get { managedObject.genreName }
    set { managedObject.genreName = newValue }
  }

  /// wall-clock seconds the song was actually audible (pauses excluded)
  public var secondsListened: Int {
    get { Int(managedObject.secondsListened) }
    set { managedObject.secondsListened = Int32(newValue) }
  }

  /// the track's library duration at record time (0 = unknown)
  public var trackDuration: Int {
    get { Int(managedObject.trackDuration) }
    set { managedObject.trackDuration = Int32(newValue) }
  }

  /// met the last.fm-style play threshold (`PlayCountingRule`) —
  /// "counted" plays feed top-N charts; uncounted events are skips
  public var isCountedAsPlay: Bool {
    get { managedObject.isCountedAsPlay }
    set { managedObject.isCountedAsPlay = newValue }
  }

  /// CoreData-free view for `ListeningStatsAggregator` — keeps the
  /// stats pipeline `Sendable` and unit-testable without a live store
  public var asSnapshot: PlayEventSnapshot {
    PlayEventSnapshot(
      date: date ?? .distantPast,
      secondsListened: secondsListened,
      trackDuration: trackDuration,
      isCountedAsPlay: isCountedAsPlay,
      title: title,
      artistName: artistName,
      albumName: albumName,
      genreName: genreName,
      playableId: playable?.id
    )
  }

  override public func isEqual(_ object: Any?) -> Bool {
    guard let object = object as? PlayEvent else { return false }
    return managedObject == object.managedObject
  }
}
