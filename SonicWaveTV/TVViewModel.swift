//
//  TVViewModel.swift
//  SonicWaveTV
//
//  Created by Alzimer Ahmed on 28.10.26.
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
import SonicWaveKit

// MARK: - TVPlayerSnapshot

/// Value-type mirror of the player's now-playing state for SwiftUI —
/// refreshed on every `MusicPlayable` tick including the ~1s
/// `didElapsedTimeChange`, so `elapsed` stays live without a local timer.
struct TVPlayerSnapshot: Equatable {
  var hasTrack = false
  var title = ""
  var artist = ""
  var album = ""
  var isPlaying = false
  var isRadio = false
  var elapsed: Double = 0
  var duration: Double = 0
  var contextName = ""
}

// MARK: - TVViewModel

/// Single @MainActor state owner for the tvOS app (G28): account/login,
/// initial library sync, browse fetches and the player mirror. All logic
/// is delegated to `AmperKit.shared` — the tvOS target adds no duplicate
/// business logic, it only adapts the kit's MainActor services to
/// SwiftUI.
///
/// Flow mirrors the iOS launch path: settings migrations → account
/// cleanup → per-account `startManagerForNormalOperation` when a synced
/// account exists; login runs `BackendProxy` autodetect +
/// `syncInitial` like `LoginVC`/`SyncVC` do.
@MainActor
final class TVViewModel: ObservableObject {
  @Published private(set) var hasAccount = false
  @Published private(set) var isLibrarySynced = false
  @Published private(set) var isConnecting = false
  @Published private(set) var isSyncing = false
  @Published private(set) var syncProgress = ""
  @Published private(set) var errorMessage: String?
  @Published private(set) var albums: [Album] = []
  @Published private(set) var artists: [Artist] = []
  @Published private(set) var playlists: [Playlist] = []
  @Published private(set) var snapshot = TVPlayerSnapshot()

  private var isBootstrapped = false
  private var isPlayerNotifierRegistered = false
  private var syncState: ParsedObjectType = .genre
  private var syncParsedCount = 0
  private var syncExpectedCount = 1

  private var storage: PersistentStorage { AmperKit.shared.storage }
  private var player: PlayerFacade { AmperKit.shared.player }

  private let log = OSLog(
    subsystem: "com.alzimerahmed.SonicWave",
    category: "TVViewModel"
  )

  /// nonisolated so `@StateObject`'s nonisolated autoclosure can build
  /// it — all kit access happens in `bootstrap()` on the main actor
  nonisolated init() {}

  var activeAccount: Account? {
    guard let info = storage.settings.accounts.active else { return nil }
    return storage.main.library.getAccount(info: info)
  }

  /// the live playable behind `snapshot` — Now Playing artwork needs the
  /// entity itself for the generated-placeholder fallback chain
  var currentPlayable: AbstractPlayable? {
    guard hasAccount else { return nil }
    return player.currentlyPlaying
  }

  /// per-account artwork/theming prefs for `TVArtworkImage` — read
  /// through the entity's own account, never `activeSetting`
  func themePreference(for entity: AbstractLibraryEntity) -> ThemePreference {
    storage.settings.accounts.getSetting(entity.account?.info).read.themePreference
  }

  /// theme for surfaces with no entity (empty-library states, the
  /// no-playable artwork branch) — `getSetting(nil)` reads the
  /// account-agnostic defaults
  var defaultThemePreference: ThemePreference {
    storage.settings.accounts.getSetting(nil).read.themePreference
  }

  func artworkDisplayPreference(
    for entity: AbstractLibraryEntity
  ) -> ArtworkDisplayPreference {
    storage.settings.accounts.getSetting(entity.account?.info).read
      .artworkDisplayPreference
  }

  // MARK: bootstrap (iOS didFinishLaunching equivalent)

  func bootstrap() {
    guard !isBootstrapped else { return }
    isBootstrapped = true
    storage.applyMultiAccountSettingsUpdateIfNeeded()
    storage.applyCredentialsKeychainMigrationIfNeeded()
    AmperKit.shared.libraryUpdater.performAccountCleanUpIfNeccessaryInBackground()
    AmperKit.shared.libraryUpdater.performSmallBlockingLibraryUpdatesIfNeeded()
    AmperKit.shared.eventLogger.supressAlerts = true

    // NOTE: `libraryUpdater.isVisualUpadateNeeded` is deliberately NOT
    // checked (no `UpdateVC` surface on tvOS) — a fresh tvOS container is
    // always `.newestVersion` today, but a future `LibrarySyncVersion`
    // bump must revisit this for upgraded installs
    refreshAccountState()
    guard hasAccount else { return }
    for accountInfo in storage.settings.accounts.allAccounts {
      AmperKit.shared.getMeta(accountInfo).startManagerForNormalOperation(player: player)
    }
    registerPlayerNotifierIfNeeded()
    if isLibrarySynced {
      loadLibrary()
    }
    refreshSnapshot()
  }

  private func refreshAccountState() {
    hasAccount = storage.settings.accounts.active != nil
    isLibrarySynced = storage.settings.app.isLibrarySynced
  }

  private func registerPlayerNotifierIfNeeded() {
    guard !isPlayerNotifierRegistered, hasAccount else { return }
    isPlayerNotifierRegistered = true
    player.addNotifier(notifier: self)
  }

  // MARK: login (LoginVC.login equivalent)

  /// `allowUntrustedCertificates` mirrors `LoginVC`'s toggle — self-hosted
  /// servers with self-signed certs fail validation otherwise; the kit's
  /// `AccountSessionSecurity` TOFU pinning handles them from there.
  /// (`httpHeaders` stay iOS-only for now — no tvOS editing surface.)
  func login(
    serverUrl: String,
    username: String,
    password: String,
    allowUntrustedCertificates: Bool = false
  ) async {
    errorMessage = nil
    let trimmedUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUrl.isEmpty else {
      errorMessage = "No server URL given!"
      return
    }
    guard trimmedUrl.hasPrefix("https://") || trimmedUrl.hasPrefix("http://") else {
      errorMessage = "Please provide either 'https://' or 'http://' in your server URL."
      return
    }
    guard !username.isEmpty else {
      errorMessage = "No username given!"
      return
    }
    guard !password.isEmpty else {
      errorMessage = "No password given!"
      return
    }

    var credentials = LoginCredentials(
      serverUrl: trimmedUrl,
      username: username,
      password: password
    )
    credentials.allowUntrustedServerCertificates = allowUntrustedCertificates
    var accountInfo = Account.createInfo(credentials: credentials)
    guard !storage.settings.accounts.allAccounts.contains(accountInfo) else {
      errorMessage = "Account already added!"
      return
    }

    isConnecting = true
    do {
      let meta = AmperKit.shared.getMeta(accountInfo)
      let authenticatedApiType = try await meta.backendApi.login(
        apiType: .notDetected,
        credentials: credentials
      )
      credentials.backendApi = authenticatedApiType
      accountInfo = Account.createInfo(credentials: credentials)
      meta.backendApi.selectedApi = authenticatedApiType
      meta.account.assignInfo(info: accountInfo)
      storage.main.saveContext()
      storage.settings.accounts.login(credentials)
      meta.backendApi.provideCredentials(credentials: credentials)
      AmperKit.shared.notificationHandler.post(
        name: .accountAdded,
        object: nil,
        userInfo: nil
      )
      AmperKit.shared.notificationHandler.post(
        name: .accountActiveChanged,
        object: nil,
        userInfo: nil
      )
      isConnecting = false
      // flip `hasAccount` BEFORE `syncInitial` — the root router needs it
      // to leave `TVLoginView` for `TVSyncView`, otherwise the live
      // Connect button invites a duplicate login while sync runs
      refreshAccountState()
      await syncInitial(account: meta.account)
    } catch {
      isConnecting = false
      AmperKit.shared.resetMeta(accountInfo)
      errorMessage = error is AuthenticationError
        ? error.localizedDescription
        : "Not able to login!"
    }
    refreshAccountState()
  }

  // MARK: sync (SyncVC equivalent)

  /// re-run for an existing-but-unsynced account — the login path enters
  /// here automatically; `SyncRequiredView` exposes it for relaunches
  func syncActiveAccount() async {
    guard let account = activeAccount else { return }
    await syncInitial(account: account)
  }

  private func syncInitial(account: Account) async {
    guard !isSyncing else { return }
    isSyncing = true
    syncProgress = "Starting sync ..."

    storage.main.library.cleanStorageOfObsoleteAccountEntries(account: account)
    do {
      try await AmperKit.shared.getMeta(account.info).librarySyncer
        .syncInitial(statusNotifyier: self)
      storage.settings.accounts.updateSetting(account.info) { accountSettings in
        accountSettings.initialSyncCompletionStatus = .completed
      }
    } catch {
      storage.settings.accounts.updateSetting(account.info) { accountSettings in
        accountSettings.initialSyncCompletionStatus = .aborted
      }
      AmperKit.shared.eventLogger.report(
        topic: "Initial Sync",
        error: error,
        displayPopup: false
      )
      errorMessage = "Library sync failed — check the server and try again."
      isSyncing = false
      refreshAccountState()
      return
    }

    storage.settings.app.librarySyncVersion = .newestVersion
    storage.settings.app.isLibrarySynced = true
    AmperKit.shared.getMeta(account.info).startManagerAfterSync(player: player)
    isSyncing = false
    refreshAccountState()
    registerPlayerNotifierIfNeeded()
    loadLibrary()
    refreshSnapshot()
  }

  // MARK: library browse

  /// full browse fetches — `getAlbums`/`getArtists`/`getPlaylists` return
  /// name-sorted wrapper structs; grids render them lazily
  func loadLibrary() {
    guard let account = activeAccount else {
      albums = []
      artists = []
      playlists = []
      return
    }
    let library = storage.main.library
    albums = library.getAlbums(for: account)
    artists = library.getArtists(for: account)
    playlists = library.getPlaylists(for: account)
  }

  // MARK: playback

  func playAll(of containable: PlayableContainable) {
    registerPlayerNotifierIfNeeded()
    player.play(context: PlayContext(containable: containable))
    refreshSnapshot()
  }

  func play(playables: [AbstractPlayable], at index: Int, contextName: String) {
    guard playables.indices.contains(index) else { return }
    registerPlayerNotifierIfNeeded()
    player.play(context: PlayContext(
      name: contextName,
      index: index,
      playables: playables
    ))
    refreshSnapshot()
  }

  func togglePlayPause() {
    player.togglePlayPause()
    refreshSnapshot()
  }

  func playNext() {
    player.playNext()
    refreshSnapshot()
  }

  func playPreviousOrReplay() {
    player.playPreviousOrReplay()
    refreshSnapshot()
  }

  private func refreshSnapshot() {
    guard let playable = player.currentlyPlaying else {
      snapshot = TVPlayerSnapshot()
      return
    }
    let radioInfo = playable.isRadio ? player.currentRadioNowPlaying : nil
    snapshot = TVPlayerSnapshot(
      hasTrack: true,
      title: radioInfo?.title ?? playable.title,
      artist: playable.isRadio
        ? (radioInfo?.artist ?? "")
        : playable.creatorName,
      album: playable.asSong?.album?.name ?? "",
      isPlaying: player.isPlaying,
      isRadio: playable.isRadio,
      elapsed: player.elapsedTime,
      duration: player.duration,
      contextName: player.contextName
    )
  }
}

// MARK: MusicPlayable

extension TVViewModel: MusicPlayable {
  func didStartPlayingFromBeginning() { refreshSnapshot() }
  func didStartPlaying() { refreshSnapshot() }
  func didPause() { refreshSnapshot() }
  func didStopPlaying() { refreshSnapshot() }
  /// the 1s elapsed tick drives the progress readout — the snapshot
  /// rebuild is a handful of property reads, cheap on the main actor
  func didElapsedTimeChange() { refreshSnapshot() }
  func didPlaylistChange() { refreshSnapshot() }
  func didArtworkChange() { refreshSnapshot() }
  func didNowPlayingInfoChange() { refreshSnapshot() }
  /// the kit's defaults for these live in a non-public extension —
  /// invisible cross-module, so they must be implemented here;
  /// the snapshot carries no shuffle/repeat/rate state → honest no-ops
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
}

// MARK: SyncCallbacks

extension TVViewModel: SyncCallbacks {
  nonisolated func notifyParsedObject(ofType parsedObjectType: ParsedObjectType) {
    Task { @MainActor in
      guard parsedObjectType == syncState else { return }
      syncParsedCount += 1
      let percent = syncExpectedCount > 0
        ? min(Float(syncParsedCount) / Float(syncExpectedCount), 1.0)
        : 0
      syncProgress = String(
        format: "%@ ... %.0f%%",
        Self.label(for: parsedObjectType),
        percent * 100
      )
    }
  }

  nonisolated func notifySyncStarted(
    ofType parsedObjectType: ParsedObjectType,
    totalCount: Int
  ) {
    Task { @MainActor in
      syncState = parsedObjectType
      syncParsedCount = 0
      syncExpectedCount = max(totalCount, 1)
      syncProgress = "\(Self.label(for: parsedObjectType)) ..."
    }
  }

  private static func label(for type: ParsedObjectType) -> String {
    switch type {
    case .artist: "Syncing artists"
    case .album: "Syncing albums"
    case .song: "Syncing songs"
    case .playlist: "Syncing playlists"
    case .genre: "Syncing genres"
    case .podcast: "Syncing podcasts"
    case .cache: "Applying cache"
    }
  }
}
