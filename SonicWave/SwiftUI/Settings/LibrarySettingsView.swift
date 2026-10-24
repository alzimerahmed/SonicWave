//
//  LibrarySettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 15.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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
import SwiftUI

// MARK: - LibrarySettingsView

struct LibrarySettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  let fileManager = CacheFileManager.shared

  @State
  var playlistCount = 0
  @State
  var artistCount = 0
  @State
  var albumCount = 0
  @State
  var songCount = 0
  @State
  var podcastCount = 0
  @State
  var podcastEpisodeCount = 0
  @State
  var albumWithSyncedSongsCount = 0
  @State
  var pinnedUsageText = ""
  @State
  var cacheUsageText = ""
  @State
  var totalUsageText = ""
  @State
  var autoSyncProgressText = ""

  @State
  var isShowClearCacheAlert = false
  @State
  var isShowDeleteCacheAlert = false
  @State
  var isShowDownloadSongsAlert = false

  /// one preset for the account's `.cache` tier cap
  /// (`AccountSetting.cacheSizeLimitMB`, G6) — 0 renders as "Unlimited"
  private struct CacheLimitPreset: Hashable {
    let title: String
    let mb: Int
  }

  private static let cacheLimitPresets: [CacheLimitPreset] = [
    CacheLimitPreset(title: "512 MB", mb: 512),
    CacheLimitPreset(title: "1 GB", mb: 1_024),
    CacheLimitPreset(title: "2 GB", mb: 2_048),
    CacheLimitPreset(title: "5 GB", mb: 5_120),
    CacheLimitPreset(title: "Unlimited", mb: 0),
  ]

  private var cacheLimitText: String {
    let mb = settings.cacheSizeLimitMB
    if let preset = Self.cacheLimitPresets.first(where: { $0.mb == mb }) {
      return preset.title
    }
    return mb <= 0 ? "Unlimited" : (Int64(mb) * 1_048_576).asByteString
  }

  private static func usageText(itemCount: Int, byteCount: Int64) -> String {
    "\(itemCount) item\(itemCount == 1 ? "" : "s"), \(byteCount.asByteString)"
  }

  private func setCacheLimit(mb: Int) {
    settings.cacheSizeLimitMB = mb
  }

  private func updateValues() {
    Task { @MainActor in do {
      guard let activeAccountInfo = settings.activeAccountInfo else { return }
      let accountObjectId = appDelegate.storage.main.library
        .getAccount(info: activeAccountInfo).managedObject.objectID
      playlistCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getPlaylistCount(for: accountAsync)
      }
      artistCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getArtistCount(for: accountAsync)
      }
      albumCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getAlbumCount(for: accountAsync)
      }
      podcastCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getPodcastCount(for: accountAsync)
      }
      podcastEpisodeCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getPodcastEpisodeCount(for: accountAsync)
      }
      songCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getSongCount(for: accountAsync)
      }
      albumWithSyncedSongsCount = try await appDelegate.storage.async
        .performAndGet { asyncCompanion in
          let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          return asyncCompanion.library.getAlbumWithSyncedSongsCount(for: accountAsync)
        }

      if albumCount < 1 {
        autoSyncProgressText = String(format: "%.1f", 0.0) + "%"
      } else {
        let progress = Float(albumWithSyncedSongsCount) * 100.0 / Float(albumCount)
        autoSyncProgressText = String(format: "%.1f", progress) + "%"
      }

      let usage = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getPlayableStorageUsage(for: accountAsync)
      }
      pinnedUsageText = Self.usageText(
        itemCount: usage.pinnedTierItemCount,
        byteCount: usage.pinnedTierByteCount
      )
      cacheUsageText = Self.usageText(
        itemCount: usage.cacheTierItemCount,
        byteCount: usage.cacheTierByteCount
      )
      totalUsageText = usage.totalByteCount.asByteString
    } catch {
      // do nothing
    }}
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(content: {
          SettingsRow(title: "Playlists") {
            SecondaryText(playlistCount.description)
          }
          SettingsRow(title: "Artists") {
            SecondaryText(artistCount.description)
          }
          SettingsRow(title: "Albums") {
            SecondaryText(albumCount.description)
          }
          SettingsRow(title: "Songs") {
            SecondaryText(songCount.description)
          }
          SettingsRow(title: "Podcasts") {
            SecondaryText(podcastCount.description)
          }
          SettingsRow(title: "Podcast Episodes") {
            SecondaryText(podcastEpisodeCount.description)
          }
          SettingsRow(title: "Initial Sync") {
            SecondaryText(
              appDelegate.storage.settings.accounts.getSetting(settings.activeAccountInfo).read
                .initialSyncCompletionStatus.description
            )
          }
        })

        let progressTitle = "Progress"

        SettingsSection(content: {
          SettingsRow(title: progressTitle) {
            SecondaryText(autoSyncProgressText)
          }
        }, header: "Background song sync")

        SettingsSection(content: {
          SettingsRow(title: "Downloads") { SecondaryText(pinnedUsageText) }
          SettingsRow(title: "Cache") { SecondaryText(cacheUsageText) }
          SettingsRow(title: "Total") { SecondaryText(totalUsageText) }
        }, header: "Storage", footer:
        "Downloads are kept until you delete them. The cache holds automatically saved songs and podcast episodes and frees space on its own.")

        SettingsSection(content: {
          SettingsRow(title: "Cache Limit") {
            Menu(cacheLimitText) {
              ForEach(Self.cacheLimitPresets, id: \.self) { preset in
                Button {
                  setCacheLimit(mb: preset.mb)
                } label: {
                  if settings.cacheSizeLimitMB == preset.mb {
                    Label(preset.title, systemImage: "checkmark")
                  } else {
                    Text(preset.title)
                  }
                }
              }
            }
            .accessibilityLabel("Cache limit")
            .accessibilityValue(cacheLimitText)
          }
          if let activeAccountInfo = settings.activeAccountInfo {
            SettingsButtonRow(title: "Clear Cache", actionType: .destructive) {
              isShowClearCacheAlert = true
            }.alert(isPresented: $isShowClearCacheAlert) {
              Alert(
                title: Text("Clear Cache"),
                message: Text(
                  "This removes all automatically cached songs and podcast episodes. Your downloads are kept."
                ),
                primaryButton: .destructive(Text("Clear")) {
                  // mirror the "Delete all downloads" path: stop playback
                  // first so a cached file can't be deleted from under an
                  // in-flight play, and run the per-item file deletes on
                  // the async context instead of blocking the main thread
                  appDelegate.player.stop()
                  let accountObjectId = appDelegate.storage.main.library
                    .getAccount(info: activeAccountInfo).managedObject.objectID
                  Task { @MainActor in
                    // `AsyncCoreDataAccessWrapper.perform` swallows errors
                    // then saves — acceptable here (same trade-off as
                    // CacheEvictionHandler): a failed file delete leaves
                    // the file on disk while the cache bookkeeping resets
                    try? await appDelegate.storage.async.perform { asyncCompanion in
                      let accountAsync = asyncCompanion.library
                        .getAccount(managedObjectId: accountObjectId)
                      let cachedPlayables = asyncCompanion.library
                        .getCachedPlayables(for: accountAsync, downloadTier: .cache)
                      asyncCompanion.library.deleteCache(of: cachedPlayables)
                      asyncCompanion.saveContext()
                    }
                    updateValues()
                  }
                },
                secondaryButton: .cancel()
              )
            }
          }
        }, header: "Cache", footer:
        "When the cache exceeds the limit, the least recently played items are removed automatically. Downloads are never removed.")

        if settings.activeAccountInfo != nil {
          SettingsSection(content: {
            SettingsButtonRow(title: "Download all songs in library") {
              isShowDownloadSongsAlert = true
            }
            .alert(isPresented: $isShowDownloadSongsAlert) {
              Alert(
                title: Text("Download all songs in library"),
                message: Text(
                  "This will add all uncached songs in your library to the download queue. This may use a lot of data and storage. Continue?"
                ),
                primaryButton: .default(Text("OK")) {
                  if let activeAccountInfo = settings.activeAccountInfo {
                    let account = appDelegate.storage.main.library
                      .getAccount(info: activeAccountInfo)
                    let allSongsToDownload = appDelegate.storage.main.library
                      .getSongsForCompleteLibraryDownload(for: account)
                    appDelegate.getMeta(account.info).playableDownloadManager
                      .download(objects: allSongsToDownload)
                  }
                },
                secondaryButton: .cancel()
              )
            }

            SettingsButtonRow(
              title: "Delete all downloads and cached files",
              actionType: .destructive
            ) {
              isShowDeleteCacheAlert = true
            }.alert(isPresented: $isShowDeleteCacheAlert) {
              Alert(
                title: Text("Delete All Downloads"),
                message: Text(
                  "This removes all downloaded and cached songs and podcast episodes for this account."
                ),
                primaryButton: .destructive(Text("Delete")) {
                  if let activeAccountInfo = settings.activeAccountInfo {
                    appDelegate.player.stop()
                    let account = appDelegate.storage.main.library
                      .getAccount(info: activeAccountInfo)
                    appDelegate.getMeta(account.info).playableDownloadManager.stop()
                    appDelegate.storage.main.library
                      .deletePlayableCachePaths(for: account)
                    appDelegate.storage.main.library.saveContext()
                    fileManager.deletePlayableCache(accountInfo: account.info)
                    appDelegate.getMeta(account.info).playableDownloadManager.start()
                  }
                }, secondaryButton: .cancel()
              )
            }
          })
        }
      }
    }
    .navigationTitle("Library")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      updateValues()
      appDelegate.userStatistics.visited(.settingsLibrary)
    }
    .onReceive(timer) { _ in
      updateValues()
    }
    .onDisappear {
      timer.upstream.connect().cancel()
    }
  }
}

// MARK: - LibrarySettingsView_Previews

struct LibrarySettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    LibrarySettingsView().environmentObject(settings)
  }
}
