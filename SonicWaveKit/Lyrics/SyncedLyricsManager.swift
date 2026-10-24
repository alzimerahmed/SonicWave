//
//  SyncedLyricsManager.swift
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
import os.log

// MARK: - SyncedLyricsManager

/// Multi-source synced-lyrics provider (G4) — one per account, vended lazily
/// by `MetaManager.syncedLyricsManager`.
///
/// Source chain (priority order, first hit wins):
/// 1. disk cache `lyrics/synced/<md5(playableId)>.swlyrics.json` — resolved
///    `SyncedLyrics` JSON, excluded-from-backup like every cache file
/// 2. server lyrics — Subsonic `getLyricsBySongId` (cached XML via
///    `Song.lyricsRelFilePath` first, live fetch otherwise; `songLyrics`
///    OpenSubsonic extension-gated) / Ampache `song` lyrics field (plain)
/// 3. embedded USLT frames of the downloaded file (plain)
/// 4. `.lrc` sidecar next to the downloaded file
/// 5. LRCLIB `/api/get` — third-party host, requires the per-account
///    `AccountSetting.isSyncedLyricsExternalLookupActive` toggle + online
///
/// Degrades to the existing plain-lyrics behavior: no synced source yields
/// `.plain(...)` or `.none`, and `fetchLyrics` still writes the server XML
/// cache that `LyricsVC`/`PlainDetailsVC`/`getCachedLyrics` consume.
@MainActor
public final class SyncedLyricsManager {
  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "SyncedLyricsManager"
  )
  private let account: Account
  private let networkMonitor: NetworkMonitorFacade
  private let storage: PersistentStorage
  private let librarySyncer: LibrarySyncer
  private let eventLogger: EventLogger
  private let fileManager = CacheFileManager.shared
  private let embeddedLyricsExtractor = EmbeddedLyricsExtractor()
  private let lrclibApi = LrclibApi()
  /// session-scoped result cache (hits + misses) keyed by song id —
  /// positive results are additionally persisted on disk
  private var sessionResultCache = [String: LyricsResult]()

  init(
    account: Account,
    networkMonitor: NetworkMonitorFacade,
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    eventLogger: EventLogger
  ) {
    self.account = account
    self.networkMonitor = networkMonitor
    self.storage = storage
    self.librarySyncer = librarySyncer
    self.eventLogger = eventLogger
  }

  /// Resolves lyrics for `playable` through the source chain.
  /// Returns `.none` for non-song playables (podcast episodes, radios).
  public func lyrics(for playable: AbstractPlayable) async -> LyricsResult {
    guard let song = playable.asSong else { return .none }
    if let cached = sessionResultCache[song.id] { return cached }
    let result = await resolveLyrics(song: song)
    // misses are not session-cached — a download finishing or a flipped
    // lookup toggle must re-run the source chain on the next request,
    // and unbounded `.none` entries would grow the cache needlessly
    if result != .none {
      sessionResultCache[song.id] = result
    }
    return result
  }

  /// Drops session + disk cache for one playable — the next `lyrics(for:)`
  /// re-runs the full source chain (e.g. after a manual refresh).
  public func invalidateCache(for playable: AbstractPlayable) {
    sessionResultCache[playable.id] = nil
    guard let relPath = fileManager.createRelPathForSyncedLyricsCache(
      playableId: playable.id,
      account: account.info
    ), let absPath = fileManager.getAbsoluteAmperfyPath(relFilePath: relPath)
    else { return }
    try? fileManager.removeItem(at: absPath, accountInfo: account.info)
  }

  private var isOnline: Bool {
    storage.settings.user.isOnlineMode && networkMonitor.isConnectedToNetwork
  }

  private var isLrclibLookupAllowed: Bool {
    isOnline && storage.settings.accounts.getSetting(account.info).read
      .isSyncedLyricsExternalLookupActive
  }

  private var sourceForServerApi: LyricsSource {
    account.apiType == .ampache ? .ampache : .subsonic
  }

  private func resolveLyrics(song: Song) async -> LyricsResult {
    if let cached = readCachedLyrics(playableId: song.id) {
      return LyricsResult(wrapping: cached)
    }
    if let lyrics = await fetchServerLyrics(song: song) {
      return storeAndWrap(lyrics, song: song)
    }
    if let lyrics = await fetchLocalFileLyrics(song: song) {
      return storeAndWrap(lyrics, song: song)
    }
    if let lyrics = await fetchLrclibLyrics(song: song) {
      return storeAndWrap(lyrics, song: song)
    }
    return .none
  }

  /// Sources (a)+(b): server-side lyrics.
  /// First the lyrics XML the library syncer already persisted
  /// (`Song.lyricsRelFilePath`), then a live backend fetch — Subsonic
  /// (`getLyricsBySongId`, `songLyrics` extension-gated) resp. Ampache
  /// (plain `<lyrics>` field of the `song` action).
  private func fetchServerLyrics(song: Song) async -> SyncedLyrics? {
    if let lyricsRelFilePath = song.lyricsRelFilePath,
       let lyricsList = try? await librarySyncer.parseLyrics(relFilePath: lyricsRelFilePath),
       let structured = lyricsList.getFirstSyncedLyricsOrUnsyncedAsDefault() {
      return SyncedLyrics(from: structured, source: sourceForServerApi)
    }

    guard isOnline else { return nil }
    do {
      let lyricsList = try await librarySyncer.fetchLyrics(song: song)
      guard let structured = lyricsList.getFirstSyncedLyricsOrUnsyncedAsDefault()
      else { return nil }
      return SyncedLyrics(from: structured, source: sourceForServerApi)
    } catch {
      // lyrics are optional — a failed lookup degrades to the next source
      os_log(
        "Server lyrics fetch failed for <%s>: %s",
        log: self.log,
        type: .info,
        song.displayString,
        error.localizedDescription
      )
      return nil
    }
  }

  /// Sources (c)+(d): lyrics shipped with the local file — only for
  /// downloaded/cached playables. Embedded USLT first, then the `.lrc`
  /// sidecar next to the playable file.
  private func fetchLocalFileLyrics(song: Song) async -> SyncedLyrics? {
    guard song.isCached,
          let relFilePath = song.relFilePath,
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return nil }

    // ID3TagEditor does synchronous whole-file I/O — keep it off the
    // MainActor so a large download doesn't stall the UI
    let embedded = await Task.detached(priority: .utility) {
      [extractor = embeddedLyricsExtractor] in
      extractor.extractLyrics(absFilePath: absFilePath)
    }.value
    if let first = embedded.first {
      return first // first stored language frame wins
    }

    let sidecarPath = absFilePath.deletingPathExtension().appendingPathExtension("lrc")
    if let lrcData = fileManager.getFileDataIfNotToBig(url: sidecarPath),
       let lrcString = String(data: lrcData, encoding: .utf8),
       !lrcString.isEmpty {
      var lyrics = LrcParser.parse(lrcString)
      lyrics.source = .sidecarFile
      return lyrics
    }
    return nil
  }

  /// Source (e): LRCLIB fallback — own credential-free session, per-account
  /// toggle (`isSyncedLyricsExternalLookupActive`), skipped in offline mode.
  private func fetchLrclibLyrics(song: Song) async -> SyncedLyrics? {
    guard isLrclibLookupAllowed else { return nil }
    // artist_name is required by LRCLIB — without a real artist the
    // signature can't match; "Unknown Artist" lookups are pointless
    guard let artistName = song.artist?.name, !artistName.isEmpty,
          !song.title.isEmpty else { return nil }
    do {
      guard let track = try await lrclibApi.fetchLyrics(
        trackName: song.title,
        artistName: artistName,
        albumName: song.album?.name,
        durationSeconds: song.duration
      ), track.instrumental != true else { return nil }

      if let syncedLyrics = track.syncedLyrics, !syncedLyrics.isEmpty {
        var lyrics = LrcParser.parse(syncedLyrics)
        lyrics.source = .lrclib
        return lyrics
      }
      if let plainLyrics = track.plainLyrics, !plainLyrics.isEmpty {
        return SyncedLyrics(plainText: plainLyrics, source: .lrclib)
      }
      return nil
    } catch {
      os_log(
        "LRCLIB lookup failed for <%s>: %s",
        log: self.log,
        type: .info,
        song.displayString,
        error.localizedDescription
      )
      return nil
    }
  }

  private func readCachedLyrics(playableId: String) -> SyncedLyrics? {
    guard let relPath = fileManager.createRelPathForSyncedLyricsCache(
      playableId: playableId,
      account: account.info
    ),
      let absPath = fileManager.getAbsoluteAmperfyPath(relFilePath: relPath),
      let data = fileManager.getFileDataIfNotToBig(url: absPath),
      let lyrics = try? JSONDecoder().decode(SyncedLyrics.self, from: data)
    else { return nil }
    return lyrics
  }

  private func storeAndWrap(_ lyrics: SyncedLyrics, song: Song) -> LyricsResult {
    if let relPath = fileManager.createRelPathForSyncedLyricsCache(
      playableId: song.id,
      account: account.info
    ),
      let absPath = fileManager.getAbsoluteAmperfyPath(relFilePath: relPath),
      let data = try? JSONEncoder().encode(lyrics) {
      try? fileManager.writeDataExcludedFromBackup(
        data: data,
        to: absPath,
        accountInfo: account.info
      )
    }
    return LyricsResult(wrapping: lyrics)
  }
}
