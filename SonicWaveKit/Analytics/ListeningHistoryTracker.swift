//
//  ListeningHistoryTracker.swift
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
import os.log

// MARK: - PlayCountingRule

/// G14: last.fm-style play threshold — a listening session counts as a
/// "play" once the song was audible for at least half its duration, or
/// 4 minutes, whichever comes first. `ScrobbleSyncer` applies the same
/// rule server-side with its own private copy of the constant — a
/// deliberate policy change must touch both places.
public enum PlayCountingRule {
  /// 4 minutes — the same cap `ScrobbleSyncer.maximumWaitDurationInSec` uses
  public static let maximumCountedListenSeconds: TimeInterval = 240

  public static func thresholdSeconds(forTrackDuration trackDurationSeconds: Int) -> TimeInterval {
    min(TimeInterval(trackDurationSeconds) / 2, maximumCountedListenSeconds)
  }

  /// `trackDuration <= 0` (unknown length) collapses the threshold to 0 —
  /// any recorded listen counts, mirroring the scrobbler whose zero-duration
  /// timer fires immediately
  public static func isCountedAsPlay(secondsListened: TimeInterval, trackDuration: Int) -> Bool {
    secondsListened >= thresholdSeconds(forTrackDuration: trackDuration)
  }
}

// MARK: - ListeningSession

/// Pure per-song listening-session bookkeeping — no player, no CoreData,
/// fully deterministic for tests. One instance covers one contiguous
/// track context: from `didStartPlayingFromBeginning` until the next
/// track starts or playback stops. Pause/resume cycles accumulate into
/// the same session (audible-time accounting, seeks irrelevant), so a
/// session can never produce more than one `PlayEvent` row — that is
/// the dedup guarantee.
struct ListeningSession {
  /// sessions below this produce no row at all — sub-second churn
  /// (queue edits, aborted preloads) is noise, not history
  static let minimumRecordedSeconds: TimeInterval = 1

  private(set) var listenedSeconds: TimeInterval = 0
  private var audibleSince: Date?

  var isAudible: Bool { audibleSince != nil }

  /// idempotent — the FromBeginning→StartedPlaying callback pair and
  /// pause→resume both land here without double-opening the clock
  mutating func markAudible(at date: Date) {
    audibleSince ??= date
  }

  mutating func pause(at date: Date) {
    guard let since = audibleSince else { return }
    listenedSeconds += max(0, date.timeIntervalSince(since))
    audibleSince = nil
  }

  /// total audible seconds if the session were sealed `now` — includes
  /// the currently running leg when the player is not paused
  func elapsedSeconds(until date: Date) -> TimeInterval {
    guard let since = audibleSince else { return listenedSeconds }
    return listenedSeconds + max(0, date.timeIntervalSince(since))
  }
}

// MARK: - ListeningHistoryTracker

/// G14 listening analytics: writes one `PlayEvent` row per finished
/// listening session of a song. Registered as a `MusicPlayable`
/// notifier through `MetaManager` — the same sanctioned seam
/// `ScrobbleSyncer` uses — so session boundaries come straight from
/// the player: no parallel listeners, no timers, no polling.
///
/// Event ordering in `AudioPlayer`: a fresh track emits
/// `didStartPlayingFromBeginning` then `didStartPlaying`; a pause emits
/// `didPause`; resume emits `didStartPlaying` again; a hard stop emits
/// `didStopPlaying`. Track changes (incl. gapless) do NOT emit
/// `didStopPlaying` — the next `didStartPlayingFromBeginning` seals the
/// outgoing session.
///
/// Sessions are per-account like the scrobbler's: one tracker instance
/// per `MetaManager`, keyed to its `account`; a song of another account
/// never opens a session here. Rows record both counted plays and
/// sub-threshold skips (`isCountedAsPlay` distinguishes them) — skip
/// data is honest history, not waste.
///
/// On-device only — nothing here ever leaves the app.
@MainActor
public class ListeningHistoryTracker {
  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "ListeningHistoryTracker"
  )
  private let player: PlayerFacade
  private let account: Account
  private let storage: PersistentStorage

  private var sessionSong: Song?
  private var session = ListeningSession()

  init(
    player: PlayerFacade,
    account: Account,
    storage: PersistentStorage
  ) {
    self.player = player
    self.account = account
    self.storage = storage
  }

  /// seals the open session (if any) — the single place a `PlayEvent`
  /// row is written. The collection setting is honored at write time so
  /// a session that started while tracking was enabled is still dropped
  /// when the user opted out mid-play. Sub-second sessions produce no
  /// row (`ListeningSession.minimumRecordedSeconds`).
  private func finishSession() {
    defer {
      sessionSong = nil
      session = ListeningSession()
    }
    guard let song = sessionSong else { return }
    let listenedSeconds = session.elapsedSeconds(until: Date())
    guard listenedSeconds >= ListeningSession.minimumRecordedSeconds else { return }
    guard storage.settings.user.isListeningHistoryEnabled else { return }

    let event = storage.main.library.createPlayEvent(account: account)
    // stamped at session END on purpose: a play that spans a period
    // boundary counts in the window where it finished — the listener
    // still had the track audible then. (Session-start stamping would
    // hide a just-finished play behind the cutoff instead.)
    event.date = Date()
    event.playable = song
    event.title = song.title
    event.artistName = song.artist?.name
    event.albumName = song.album?.name
    event.genreName = song.genre?.name
    event.secondsListened = Int(listenedSeconds.rounded())
    event.trackDuration = song.duration
    event.isCountedAsPlay = PlayCountingRule.isCountedAsPlay(
      secondsListened: listenedSeconds,
      trackDuration: song.duration
    )
    storage.main.saveContext()
  }

  /// opens a session for the currently playing song of this account —
  /// marks it audible immediately: `didStartPlayingFromBeginning` is
  /// only emitted when playback actually commences
  private func beginSession() {
    guard let song = player.currentlyPlaying?.asSong,
          song.account == account
    else { return }
    sessionSong = song
    session = ListeningSession()
    session.markAudible(at: Date())
  }

  /// flushes the in-flight session — called from
  /// `MetaManager.stopManager` on teardown (logout, resync) so a song
  /// that was playing at shutdown still lands in history
  public func stop() {
    finishSession()
  }
}

// MARK: MusicPlayable

extension ListeningHistoryTracker: MusicPlayable {
  public func didStartPlayingFromBeginning() {
    // a new track context always seals the previous one — track
    // changes do not emit didStopPlaying on (gapless) boundaries
    finishSession()
    beginSession()
  }

  public func didStartPlaying() {
    guard let song = player.currentlyPlaying?.asSong,
          song.account == account
    else { return }
    if sessionSong == nil {
      // notifier attached mid-play (manager started after playback) —
      // open late; the unknown earlier portion is simply not counted
      sessionSong = song
    }
    guard sessionSong == song else { return }
    // resume (or the FromBeginning→Started pair): idempotent
    session.markAudible(at: Date())
  }

  public func didPause() {
    session.pause(at: Date())
  }

  public func didStopPlaying() {
    finishSession()
  }

  public func didElapsedTimeChange() {}
  public func didPlaylistChange() {}
  public func didArtworkChange() {}
  public func didShuffleChange() {}
  public func didRepeatChange() {}
  public func didPlaybackRateChange() {}
}
