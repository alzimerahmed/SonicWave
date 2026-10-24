//
//  SyncedLyrics.swift
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

import CoreMedia
import Foundation

// MARK: - LyricWord

/// Word-level timestamp inside a synced lyric line (enhanced / A2 LRC
/// `<mm:ss.xx>` segments). Only populated by sources with word timings —
/// OpenSubsonic structured lyrics are line-level only.
public struct LyricWord: Sendable, Equatable, Codable {
  /// start time relative to the track start, in milliseconds
  public var start: Int
  public var value: String

  public init(start: Int, value: String) {
    self.start = start
    self.value = value
  }
}

// MARK: - LyricLine

/// One lyric line. `start` is nil for unsynced lines — unsynced lines are
/// sorted after all timed lines (parser + conversion invariants) so the
/// timed prefix stays binary-searchable.
public struct LyricLine: Sendable, Equatable, Codable {
  /// start time relative to the track start, in milliseconds
  public var start: Int?
  public var value: String
  /// word-level timestamps (enhanced LRC); empty for line-level sync
  public var words: [LyricWord]

  public init(start: Int? = nil, value: String = "", words: [LyricWord] = []) {
    self.start = start
    self.value = value
    self.words = words
  }

  public var startTime: CMTime {
    guard let start else { return CMTime(value: 0, timescale: 1) }
    return CMTime(value: Int64(start), timescale: 1_000)
  }

  /// Binary search over `words` — the word the UI should highlight at `time`
  /// (ms, already offset-adjusted) plus the progress through that word
  /// (0...1, derived from the next word's start; 0 for the last word).
  /// Returns nil when the line has no word timings.
  public func activeWord(atMilliseconds time: Int) -> (index: Int, progress: Double)? {
    guard !words.isEmpty else { return nil }
    var lo = 0
    var hi = words.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if words[mid].start <= time {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    let index = lo - 1
    guard index >= 0 else { return nil }
    let start = words[index].start
    var progress = 0.0
    if index + 1 < words.count {
      let end = words[index + 1].start
      if end > start {
        progress = min(max(Double(time - start) / Double(end - start), 0), 1)
      }
    }
    return (index, progress)
  }
}

// MARK: - ActiveLyricLine

/// Result of `SyncedLyrics.activeLine` — index into `lines`, the line itself
/// and the playback progress through it (0...1, derived from the next timed
/// line's start; 0 for the last timed line).
public struct ActiveLyricLine: Sendable, Equatable {
  public let index: Int
  public let line: LyricLine
  public let progress: Double

  public init(index: Int, line: LyricLine, progress: Double) {
    self.index = index
    self.line = line
    self.progress = progress
  }
}

// MARK: - LyricsSource

/// Where a `SyncedLyrics` was resolved from — kept for display/debug.
public enum LyricsSource: String, Sendable, Codable {
  case unknown
  /// OpenSubsonic `getLyricsBySongId` structured lyrics
  case subsonic
  /// Ampache `song` lyrics field (always plain)
  case ampache
  /// ID3 USLT frame of a downloaded file (always plain — ID3TagEditor
  /// cannot read SYLT)
  case embeddedTag
  /// `.lrc` sidecar file next to a downloaded file
  case sidecarFile
  /// LRCLIB (`https://lrclib.net/api/get`) — third-party host, gated by
  /// `AccountSetting.isSyncedLyricsExternalLookupActive`
  case lrclib
}

// MARK: - SyncedLyrics

/// Unified lyrics model for the G4 multi-source synced-lyrics subsystem.
/// `Codable` because the resolved result is persisted verbatim as the disk
/// cache file (`lyrics/synced/<md5(playableId)>.swlyrics.json`).
///
/// Invariant for `activeLine` lookups: `lines` is sorted by `start`
/// ascending and every timed line precedes every unsynced (`start == nil`)
/// line. `LrcParser` and the `StructuredLyrics` conversion both uphold it.
public struct SyncedLyrics: Sendable, Equatable, Codable {
  public var source = LyricsSource.unknown
  /// language code (ISO 639 or `und`/`xxx`), "" when unknown
  public var lang = ""
  /// true when at least one line carries a timestamp
  public var synced = false
  /// milliseconds offset — positive shifts lyrics *earlier* (OpenSubsonic
  /// `offset` and LRC `[offset:+xx]` agree on this). Applied inside
  /// `activeLine`, never baked into `lines.start`.
  public var offset = 0
  public var title: String?
  public var artist: String?
  public var album: String?
  public var lines = [LyricLine]()

  public init() {}

  /// Bridges the OpenSubsonic `StructuredLyrics` model (server XML / cached
  /// `Song.lyricsRelFilePath`) into the unified model — OpenSubsonic has no
  /// word timings, `words` stays empty.
  public init(from structuredLyrics: StructuredLyrics, source: LyricsSource) {
    self.source = source
    lang = structuredLyrics.lang
    synced = structuredLyrics.synced
    offset = structuredLyrics.offset
    title = structuredLyrics.displayTitle
    artist = structuredLyrics.displayArtist
    lines = structuredLyrics.line.map { line in
      LyricLine(start: line.start, value: line.value, words: [])
    }
  }

  /// Builds a plain-text lyrics object from raw text (USLT frames, Ampache
  /// plain lyrics, LRCLIB `plainLyrics`) — one line per source line.
  public init(plainText: String, source: LyricsSource, lang: String = "") {
    self.source = source
    self.lang = lang
    synced = false
    lines = plainText.components(separatedBy: .newlines).map { line in
      LyricLine(start: nil, value: line, words: [])
    }
  }

  /// Back-conversion so the existing `LyricsView`/`PlainDetailsVC` rendering
  /// path (`display(lyrics: StructuredLyrics)`) can be reused by the UI layer.
  public var asStructuredLyrics: StructuredLyrics {
    var structured = StructuredLyrics()
    structured.lang = lang
    structured.synced = synced
    structured.offset = offset
    structured.displayTitle = title
    structured.displayArtist = artist
    structured.line = lines.map { line in
      var converted = LyricsLine()
      converted.start = line.start
      converted.value = line.value
      return converted
    }
    return structured
  }

  /// The active line at `seconds` (raw playback position) — binary search
  /// over the timed prefix of `lines`. `offset` is applied here: positive
  /// values make lines active earlier. Returns nil for unsynced lyrics or
  /// before the first line.
  public func activeLine(atSeconds seconds: Double) -> ActiveLyricLine? {
    activeLine(atMilliseconds: Int((seconds * 1_000).rounded()))
  }

  /// The active line at `time` (raw playback position in ms) — see
  /// `activeLine(atSeconds:)`.
  public func activeLine(atMilliseconds time: Int) -> ActiveLyricLine? {
    guard synced, !lines.isEmpty else { return nil }
    let adjustedTime = time + offset
    // last line with start <= adjustedTime; nil starts sort to `.max`
    var lo = 0
    var hi = lines.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if (lines[mid].start ?? .max) <= adjustedTime {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    let index = lo - 1
    guard index >= 0 else { return nil }
    let line = lines[index]
    guard let start = line.start else { return nil }
    var progress = 0.0
    if index + 1 < lines.count, let end = lines[index + 1].start, end > start {
      progress = min(max(Double(adjustedTime - start) / Double(end - start), 0), 1)
    }
    return ActiveLyricLine(index: index, line: line, progress: progress)
  }
}

// MARK: - LyricsResult

/// Outcome of `SyncedLyricsManager.lyrics(for:)` — the enum the UI consumes.
public enum LyricsResult: Sendable, Equatable {
  /// no source produced lyrics
  case none
  /// unsynced lyrics (Ampache, USLT, LRCLIB `plainLyrics`)
  case plain(SyncedLyrics)
  /// line-synced lyrics (`words` may additionally carry word timings)
  case synced(SyncedLyrics)

  public var syncedLyrics: SyncedLyrics? {
    switch self {
    case .none:
      return nil
    case .plain(let lyrics), .synced(let lyrics):
      return lyrics
    }
  }

  init(wrapping lyrics: SyncedLyrics) {
    self = lyrics.synced ? .synced(lyrics) : .plain(lyrics)
  }
}
