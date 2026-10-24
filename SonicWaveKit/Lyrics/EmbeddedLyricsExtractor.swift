//
//  EmbeddedLyricsExtractor.swift
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

@preconcurrency import ID3TagEditor
import Foundation

// MARK: - EmbeddedLyricsExtractor

/// Embedded lyrics of a downloaded playable, read via ID3TagEditor.
/// Only USLT (unsynchronised lyrics) frames are read — ID3TagEditor has no
/// SYLT parser, so embedded lyrics always resolve to plain text.
/// One `SyncedLyrics` per stored language frame (USLT is keyed by
/// ISO-639-2 language, a tag can hold several).
final class EmbeddedLyricsExtractor: Sendable {
  private let id3TagEditor = ID3TagEditor()

  func extractLyrics(absFilePath: URL) -> [SyncedLyrics] {
    guard let id3Tag = try? id3TagEditor.read(from: absFilePath.path) else { return [] }
    let reader = ID3TagContentReader(id3Tag: id3Tag)
    return reader.unsynchronizedLyrics().compactMap { frame in
      guard !frame.content.isEmpty else { return nil }
      var lyrics = SyncedLyrics(plainText: frame.content, source: .embeddedTag)
      lyrics.lang = String(describing: frame.language)
      return lyrics
    }
  }
}
