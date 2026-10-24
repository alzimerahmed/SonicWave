//
//  LrcParser.swift
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

import Foundation

// MARK: - LrcParser

/// Tolerant LRC parser — pure value types, no I/O.
///
/// Supported:
/// - line timestamps `[mm:ss.xx]` and `[mm:ss.xxx]` (also `[mm:ss]`,
///   1-digit fractions, and the `[hh:mm:ss.xx]` variant)
/// - multi-timestamp lines (`[t1][t2]text` -> one line per timestamp)
/// - metadata tags `ti/ar/al/lang/la/offset` (other tags are consumed and
///   ignored — `by/au/lr/length/re/tool/ve`, unknown `[x:y]` tags)
/// - enhanced / A2 word timestamps `<mm:ss.xx>` inside the line text
/// - malformed lines: skipped; untimed text lines are kept as unsynced
///   `LyricLine`s so a plain-text document degrades to `.plain` lyrics
enum LrcParser {
  /// Parses LRC content (or plain text) into `SyncedLyrics`.
  /// `synced` is true when at least one line carries a timestamp.
  /// `lines` is sorted by `start` ascending, unsynced lines last (the
  /// `activeLine` binary-search invariant).
  static func parse(_ lrcString: String) -> SyncedLyrics {
    var lyrics = SyncedLyrics()
    var indexedLines = [(order: Int, line: LyricLine)]()

    for (order, rawLine) in lrcString.components(separatedBy: .newlines).enumerated() {
      var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
      guard !rest.isEmpty else { continue }

      // consume all leading [..] tags — timestamps and metadata
      var timestamps = [Int]()
      while rest.hasPrefix("["), let closing = rest.firstIndex(of: "]") {
        let tagContent = rest[rest.index(after: rest.startIndex) ..< closing]
        if let start = parseTimestampContent(tagContent) {
          timestamps.append(start)
        } else {
          applyMetadataTag(tagContent, to: &lyrics)
        }
        rest = rest[rest.index(after: closing) ...]
      }

      let (plainText, words) = parseWordSegments(rest)
      if !timestamps.isEmpty {
        for timestamp in timestamps {
          indexedLines.append((
            order,
            LyricLine(start: timestamp, value: plainText, words: words)
          ))
        }
      } else if !plainText.isEmpty {
        indexedLines.append((order, LyricLine(start: nil, value: plainText, words: [])))
      }
    }

    lyrics.lines = indexedLines
      .sorted { lhs, rhs in
        let left = lhs.line.start ?? Int.max
        let right = rhs.line.start ?? Int.max
        return left != right ? left < right : lhs.order < rhs.order
      }
      .map { $0.line }
    lyrics.synced = lyrics.lines.contains { $0.start != nil }
    return lyrics
  }

  /// `[hh:]mm:ss[.xx]` tag content -> milliseconds.
  /// Returns nil for anything that is not a timestamp (metadata tags like
  /// `ti:`, `offset:`, garbage).
  static func parseTimestampContent(_ content: Substring) -> Int? {
    let parts = content.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    var hours = 0
    if parts.count == 3 {
      guard let parsedHours = Int(parts[0]), parsedHours >= 0 else { return nil }
      hours = parsedHours
    }
    guard let minutes = Int(parts[parts.count - 2]), minutes >= 0 else { return nil }
    let secondParts = parts[parts.count - 1]
      .split(separator: ".", omittingEmptySubsequences: false)
    guard secondParts.count == 1 || secondParts.count == 2,
          let seconds = Int(secondParts[0]), seconds >= 0 else { return nil }
    var fractionMs = 0
    if secondParts.count == 2 {
      let fraction = secondParts[1]
      guard !fraction.isEmpty, fraction.count <= 3, let fractionInt = Int(fraction)
      else { return nil }
      // 1-2 digits are centiseconds, 3 digits are milliseconds
      fractionMs = fraction.count == 3 ? fractionInt : fractionInt * (fraction.count == 2 ? 10 : 100)
    }
    return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + fractionMs
  }

  /// Applies `[key:value]` metadata to `title`/`artist`/`album`/`lang`/
  /// `offset`. All other tags are silently dropped.
  private static func applyMetadataTag(_ content: Substring, to lyrics: inout SyncedLyrics) {
    guard let separator = content.firstIndex(of: ":") else { return }
    let key = content[..<separator].lowercased()
    let value = String(content[content.index(after: separator)...])
      .trimmingCharacters(in: .whitespaces)
    switch key {
    case "ti": lyrics.title = value
    case "ar": lyrics.artist = value
    case "al": lyrics.album = value
    case "lang", "la": lyrics.lang = value
    case "offset": if let offset = Int(value) { lyrics.offset = offset }
    default: break
    }
  }

  /// Splits enhanced `<mm:ss.xx>` word stamps out of `input`.
  /// Returns the line's plain display text plus the word list. Lines without
  /// word stamps come back unchanged with an empty word list.
  private static func parseWordSegments(_ input: Substring) -> (text: String, words: [LyricWord]) {
    // locate every <mm:ss.xx> marker
    var markers = [(ms: Int, tagStart: Substring.Index, contentStart: Substring.Index)]()
    var scan = input.startIndex
    while scan < input.endIndex {
      guard let open = input[scan...].firstIndex(of: "<"),
            let close = input[open...].firstIndex(of: ">") else { break }
      let content = input[input.index(after: open) ..< close]
      if let ms = parseTimestampContent(content) {
        markers.append((ms, open, input.index(after: close)))
        scan = input.index(after: close)
      } else {
        // not a timestamp tag — skip the '<' and keep scanning
        scan = input.index(after: open)
      }
    }
    guard !markers.isEmpty else {
      return (String(input), [])
    }

    var plain = ""
    var words = [LyricWord]()
    for (index, marker) in markers.enumerated() {
      let end = index + 1 < markers.count ? markers[index + 1].tagStart : input.endIndex
      let segment = String(input[marker.contentStart ..< end])
      let wordText = segment.trimmingCharacters(in: .whitespaces)
      if !wordText.isEmpty {
        words.append(LyricWord(start: marker.ms, value: wordText))
      }
      plain += segment
    }
    // keep any leading text before the first word stamp
    if markers[0].tagStart > input.startIndex {
      plain = String(input[input.startIndex ..< markers[0].tagStart]) + plain
    }
    let trimmedPlain = plain.trimmingCharacters(in: .whitespaces)
    if trimmedPlain.isEmpty, !words.isEmpty {
      // word-only line — reconstruct display text from the words
      return (words.map { $0.value }.joined(separator: " "), words)
    }
    return (trimmedPlain, words)
  }
}
