//
//  Settings.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.12.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

import UIKit

// MARK: - AppSettings

public struct AppSettings: Sendable, Codable {
  private var _isLibrarySyncInfoReadByUser: Bool = false
  public var isLibrarySyncInfoReadByUser: Bool {
    get { _isLibrarySyncInfoReadByUser }
    set { _isLibrarySyncInfoReadByUser = newValue }
  }

  private var _isLibrarySynced: Bool = false
  public var isLibrarySynced: Bool {
    get { _isLibrarySynced }
    set { _isLibrarySynced = newValue }
  }

  private var _librarySyncVersion: LibrarySyncVersion = .v6
  public var librarySyncVersion: LibrarySyncVersion {
    get { _librarySyncVersion }
    set { _librarySyncVersion = newValue }
  }

  /// Spotlight indexing (G27): set once `SpotlightIndexer` completed its
  /// first full pass. `false` again after opt-out wipes the index so a
  /// re-enable rebuilds it.
  // optional backing to stay decodable for settings stored before this key existed
  private var _hasCompletedInitialSpotlightIndex: Bool? = nil
  public var hasCompletedInitialSpotlightIndex: Bool {
    get { _hasCompletedInitialSpotlightIndex ?? false }
    set { _hasCompletedInitialSpotlightIndex = newValue }
  }
}

// MARK: - UserSettings

public struct UserSettings: Sendable, Codable {
  private var _streamingMaxBitrateWifiPreference: StreamingMaxBitratePreference = .defaultValue
  public var streamingMaxBitrateWifiPreference: StreamingMaxBitratePreference {
    get { _streamingMaxBitrateWifiPreference }
    set { _streamingMaxBitrateWifiPreference = newValue }
  }

  private var _streamingMaxBitrateCellularPreference: StreamingMaxBitratePreference = .defaultValue
  public var streamingMaxBitrateCellularPreference: StreamingMaxBitratePreference {
    get { _streamingMaxBitrateCellularPreference }
    set { _streamingMaxBitrateCellularPreference = newValue }
  }

  private var _streamingFormatWifiPreference: StreamingFormatPreference = .defaultValue
  public var streamingFormatWifiPreference: StreamingFormatPreference {
    get { _streamingFormatWifiPreference }
    set { _streamingFormatWifiPreference = newValue }
  }

  private var _streamingFormatCellularPreference: StreamingFormatPreference = .defaultValue
  public var streamingFormatCellularPreference: StreamingFormatPreference {
    get { _streamingFormatCellularPreference }
    set { _streamingFormatCellularPreference = newValue }
  }

  private var _cacheTranscodingFormatPreference: CacheTranscodingFormatPreference = .defaultValue
  public var cacheTranscodingFormatPreference: CacheTranscodingFormatPreference {
    get { _cacheTranscodingFormatPreference }
    set { _cacheTranscodingFormatPreference = newValue }
  }

  private var _isShowDetailedInfo: Bool = false
  public var isShowDetailedInfo: Bool {
    get { _isShowDetailedInfo }
    set { _isShowDetailedInfo = newValue }
  }

  private var _isShowSongDuration: Bool = false
  public var isShowSongDuration: Bool {
    get { _isShowSongDuration }
    set { _isShowSongDuration = newValue }
  }

  private var _isShowAlbumDuration: Bool = false
  public var isShowAlbumDuration: Bool {
    get { _isShowAlbumDuration }
    set { _isShowAlbumDuration = newValue }
  }

  private var _isShowArtistDuration: Bool = false
  public var isShowArtistDuration: Bool {
    get { _isShowArtistDuration }
    set { _isShowArtistDuration = newValue }
  }

  private var _isShowRating: Bool = false
  public var isShowRating: Bool {
    get { _isShowRating }
    set { _isShowRating = newValue }
  }

  private var _isPlayerShuffleButtonEnabled: Bool = true
  public var isPlayerShuffleButtonEnabled: Bool {
    get { _isPlayerShuffleButtonEnabled }
    set { _isPlayerShuffleButtonEnabled = newValue }
  }

  private var _isShowMusicPlayerSkipButtons: Bool = false
  public var isShowMusicPlayerSkipButtons: Bool {
    get { _isShowMusicPlayerSkipButtons }
    set { _isShowMusicPlayerSkipButtons = newValue }
  }

  private var _isLyricsSmoothScrolling: Bool = true
  public var isLyricsSmoothScrolling: Bool {
    get { _isLyricsSmoothScrolling }
    set { _isLyricsSmoothScrolling = newValue }
  }

  // limit in byte
  private var _cacheLimit: Int = 0
  public var cacheLimit: Int {
    get { _cacheLimit }
    set { _cacheLimit = newValue }
  }

  private var _isPlayerLyricsDisplayed: Bool = false
  public var isPlayerLyricsDisplayed: Bool {
    get { _isPlayerLyricsDisplayed }
    set { _isPlayerLyricsDisplayed = newValue }
  }

  private var _isPlayerVisualizerDisplayed: Bool = false
  public var isPlayerVisualizerDisplayed: Bool {
    get { _isPlayerVisualizerDisplayed }
    set { _isPlayerVisualizerDisplayed = newValue }
  }

  private var _selectedVisualizerType: VisualizerType = .defaultValue
  public var selectedVisualizerType: VisualizerType {
    get { _selectedVisualizerType }
    set { _selectedVisualizerType = newValue }
  }

  private var _isOfflineMode: Bool = false
  public var isOfflineMode: Bool {
    get { _isOfflineMode }
    set {
      _isOfflineMode = newValue
      // every direct assignment is a deliberate (manual or recovery) decision —
      // the auto flag is set explicitly afterwards by the unreachable monitor
      _isOfflineModeAutomaticallyActivated = false
    }
  }

  // optional backing to stay decodable for settings stored before this key existed
  private var _isOfflineModeAutomaticallyActivated: Bool? = nil
  /// True when offline mode was switched on by `ServerUnreachableMonitor` and
  /// not by the user — the basis for automatic reconnection. Persisted so a
  /// relaunch into auto-offline can resume reconnecting without user input.
  /// Callers that mean "auto" must assign this flag *after* `isOfflineMode`
  /// (its setter resets the flag).
  public var isOfflineModeAutomaticallyActivated: Bool {
    get { _isOfflineModeAutomaticallyActivated ?? false }
    set { _isOfflineModeAutomaticallyActivated = newValue }
  }

  public var isOnlineMode: Bool {
    !_isOfflineMode
  }

  private var _isPlaybackStartOnlyOnPlay: Bool = false
  public var isPlaybackStartOnlyOnPlay: Bool {
    get { _isPlaybackStartOnlyOnPlay }
    set { _isPlaybackStartOnlyOnPlay = newValue }
  }

  private var _isPlayerSongPlaybackResumeEnabled: Bool = false
  public var isPlayerSongPlaybackResumeEnabled: Bool {
    get { _isPlayerSongPlaybackResumeEnabled }
    set { _isPlayerSongPlaybackResumeEnabled = newValue }
  }

  private var _isAutoplayEnabled: Bool = false
  public var isAutoplayEnabled: Bool {
    get { _isAutoplayEnabled }
    set { _isAutoplayEnabled = newValue }
  }

  // optional backing to stay decodable for settings stored before this key existed
  private var _isRowTapPlaybackEnabled: Bool? = nil
  public var isRowTapPlaybackEnabled: Bool {
    get { _isRowTapPlaybackEnabled ?? false }
    set { _isRowTapPlaybackEnabled = newValue }
  }

  private var _isHapticsEnabled: Bool = true
  public var isHapticsEnabled: Bool {
    get { _isHapticsEnabled }
    set { _isHapticsEnabled = newValue }
  }

  /// music haptics: subtle beat-synced haptic transients during playback,
  /// synthesized from the `AudioAnalyzer` bass band via `CHHapticEngine`
  /// (`MusicHapticsService`). Defaults off — the analyzer tap costs CPU
  /// and haptics are an opt-in feel feature; no-op on devices without a
  /// haptic engine (e.g. Mac Catalyst).
  // optional backing to stay decodable for settings stored before this key existed
  private var _isMusicHapticsActive: Bool? = nil
  public var isMusicHapticsActive: Bool {
    get { _isMusicHapticsActive ?? false }
    set { _isMusicHapticsActive = newValue }
  }

  /// Live Activities (G13): shows the current track on the Lock Screen
  /// and in the Dynamic Island while playing. Defaults ON (opt-out) —
  /// progress inside the activity is `Date`-anchored so it costs no
  /// extra updates.
  // optional backing to stay decodable for settings stored before this key existed
  private var _isLiveActivityEnabled: Bool? = nil
  public var isLiveActivityEnabled: Bool {
    get { _isLiveActivityEnabled ?? true }
    set { _isLiveActivityEnabled = newValue }
  }

  private var _isEqualizerEnabled: Bool = false
  public var isEqualizerEnabled: Bool {
    get { _isEqualizerEnabled }
    set { _isEqualizerEnabled = newValue }
  }

  private var _activeEqualizerSetting: EqualizerSetting = .off
  public var activeEqualizerSetting: EqualizerSetting {
    get { _activeEqualizerSetting }
    set { _activeEqualizerSetting = newValue }
  }

  private var _equalizerSettings: [EqualizerSetting] = []
  public var equalizerSettings: [EqualizerSetting] {
    get { _equalizerSettings }
    set { _equalizerSettings = newValue }
  }

  private var _isReplayGainEnabled: Bool = true
  public var isReplayGainEnabled: Bool {
    get { _isReplayGainEnabled }
    set { _isReplayGainEnabled = newValue }
  }

  /// crossfade (G3): overlap duration in seconds between the outgoing
  /// and incoming track at a track boundary, rendered by a second
  /// `AudioStreaming` engine. `0` disables crossfading — the classic
  /// gapless queue preload stays active instead. Radios and seek-locked
  /// streams never crossfade.
  // optional backing to stay decodable for settings stored before this key existed
  private var _crossfadeDurationSeconds: Int? = nil
  public var crossfadeDurationSeconds: Int {
    get { _crossfadeDurationSeconds ?? 0 }
    set { _crossfadeDurationSeconds = max(0, newValue) }
  }

  private var _isMiniPlayerAlwaysOnTop: Bool = false
  public var isMiniPlayerAlwaysOnTop: Bool {
    get { _isMiniPlayerAlwaysOnTop }
    set { _isMiniPlayerAlwaysOnTop = newValue }
  }

  private var _playerVolume: Float = 1.0
  public var playerVolume: Float {
    get {
      (_playerVolume >= 0.0 && _playerVolume <= 1.0) ? _playerVolume : 1.0
    }
    set {
      guard newValue >= 0.0, newValue <= 1.0 else { return }
      _playerVolume = newValue
    }
  }

  private var _appearanceMode: UIUserInterfaceStyle = .unspecified
  public var appearanceMode: UIUserInterfaceStyle {
    get { _appearanceMode }
    set { _appearanceMode = newValue }
  }

  /// OLED black level (design-system §2.3): `.system` follows
  /// `appearanceMode`, `.dark` forces the dark interface, `.trueBlack`
  /// additionally swaps background surfaces to true black. Applied by
  /// `AppDelegate.setAppAppearanceMode` next to `appearanceMode`.
  // optional backing to stay decodable for settings stored before this key existed
  private var _blackModePreference: BlackModePreference? = nil
  public var blackModePreference: BlackModePreference {
    get { _blackModePreference ?? .system }
    set { _blackModePreference = newValue }
  }

  private var _screenLockPreventionPreference: ScreenLockPreventionPreference = .defaultValue
  public var screenLockPreventionPreference: ScreenLockPreventionPreference {
    get { _screenLockPreventionPreference }
    set { _screenLockPreventionPreference = newValue }
  }

  private var _playlistsSortSetting: PlaylistSortType = .defaultValue
  public var playlistsSortSetting: PlaylistSortType {
    get { _playlistsSortSetting }
    set { _playlistsSortSetting = newValue }
  }

  private var _artistsSortSetting: ArtistElementSortType = .defaultValue
  public var artistsSortSetting: ArtistElementSortType {
    get { _artistsSortSetting }
    set { _artistsSortSetting = newValue }
  }

  private var _albumsSortSetting: AlbumElementSortType = .defaultValue
  public var albumsSortSetting: AlbumElementSortType {
    get { _albumsSortSetting }
    set { _albumsSortSetting = newValue }
  }

  private var _swipeActionSettings: SwipeActionSettings = .defaultSettings
  public var swipeActionSettings: SwipeActionSettings {
    get { _swipeActionSettings }
    set { _swipeActionSettings = newValue }
  }

  private var _songsSortSetting: SongElementSortType = .defaultValue
  public var songsSortSetting: SongElementSortType {
    get { _songsSortSetting }
    set {
      if newValue == SongElementSortType.starredDate {
        _songsSortSetting = .defaultValue
      } else {
        _songsSortSetting = newValue
      }
    }
  }

  private var _favoriteSongSortSetting: SongElementSortType = .defaultValueForFavorite
  public var favoriteSongSortSetting: SongElementSortType {
    get { _favoriteSongSortSetting }
    set { _favoriteSongSortSetting = newValue }
  }

  private var _artistsFilterSetting: ArtistCategoryFilter = .defaultValue
  public var artistsFilterSetting: ArtistCategoryFilter {
    get { _artistsFilterSetting }
    set { _artistsFilterSetting = newValue }
  }

  private var _albumsStyleSetting: AlbumsDisplayStyle = .defaultValue
  public var albumsStyleSetting: AlbumsDisplayStyle {
    get { _albumsStyleSetting }
    set { _albumsStyleSetting = newValue }
  }

  private var _podcastsShowSetting: PodcastsShowType = .defaultValue
  public var podcastsShowSetting: PodcastsShowType {
    get { _podcastsShowSetting }
    set { _podcastsShowSetting = newValue }
  }

  private var _playerDisplayStyle: PlayerDisplayStyle = .defaultValue
  public var playerDisplayStyle: PlayerDisplayStyle {
    get { _playerDisplayStyle }
    set { _playerDisplayStyle = newValue }
  }

  private var _albumsGridSizeSetting: Int?
  @MainActor
  public var albumsGridSizeSetting: Int {
    get {
      _albumsGridSizeSetting ?? ((UIDevice.current.userInterfaceIdiom == .pad) ? 4 : 3)
    }
    set { _albumsGridSizeSetting = newValue }
  }

  /// Spotlight indexing (G27): mirror library entities + cached lyric
  /// text into CoreSpotlight. Defaults ON (opt-out) — disabling wipes the
  /// on-device index via `SpotlightIndexer.start()` re-evaluation.
  // optional backing to stay decodable for settings stored before this key existed
  private var _isSpotlightIndexingEnabled: Bool? = nil
  public var isSpotlightIndexingEnabled: Bool {
    get { _isSpotlightIndexingEnabled ?? true }
    set { _isSpotlightIndexingEnabled = newValue }
  }
}

// MARK: - AccountSetting

public struct AccountSetting: Sendable, Codable {
  /// default cap for the evictable `.cache` download tier (2 GB per account)
  public static let defaultCacheSizeLimitMB = 2_048

  private var _artworkDisplayPreference: ArtworkDisplayPreference = .defaultValue
  public var artworkDisplayPreference: ArtworkDisplayPreference {
    get { _artworkDisplayPreference }
    set { _artworkDisplayPreference = newValue }
  }

  private var _artworkDownloadSetting: ArtworkDownloadSetting = .defaultValue
  public var artworkDownloadSetting: ArtworkDownloadSetting {
    get { _artworkDownloadSetting }
    set { _artworkDownloadSetting = newValue }
  }

  // ordered visible Home Sections
  private var _homeSections: [HomeSection] = HomeSection.defaultValue
  public var homeSections: [HomeSection] {
    get { _homeSections }
    set { _homeSections = newValue }
  }

  private var _initialSyncCompletionStatus: SyncCompletionStatus = .defaultValue
  public var initialSyncCompletionStatus: SyncCompletionStatus {
    get { _initialSyncCompletionStatus }
    set { _initialSyncCompletionStatus = newValue }
  }

  private var _isAutoDownloadLatestPodcastEpisodesActive: Bool = false
  public var isAutoDownloadLatestPodcastEpisodesActive: Bool {
    get { _isAutoDownloadLatestPodcastEpisodesActive }
    set { _isAutoDownloadLatestPodcastEpisodesActive = newValue }
  }

  private var _isAutoDownloadLatestSongsActive: Bool = false
  public var isAutoDownloadLatestSongsActive: Bool {
    get { _isAutoDownloadLatestSongsActive }
    set { _isAutoDownloadLatestSongsActive = newValue }
  }

  /// auto-sync watch (G5): favorited songs are auto-downloaded.
  /// Backed by an Optional so that decoding older persisted `AccountSetting`s
  /// (which lack this key) does not fail and silently reset all account settings.
  private var _isAutoDownloadFavoritesActive: Bool? = nil
  public var isAutoDownloadFavoritesActive: Bool {
    get { _isAutoDownloadFavoritesActive ?? false }
    set { _isAutoDownloadFavoritesActive = newValue }
  }

  /// play-queue sync (G9): mirrors the music play queue to the server via
  /// `savePlayQueue`/`getPlayQueue` and restores newer remote queues
  /// (`PlayQueueSyncer`). Defaults to `true` — the feature shipped enabled
  /// before this toggle existed; backends without support silently no-op.
  /// Backed by an Optional so that decoding older persisted `AccountSetting`s
  /// (which lack this key) does not fail and silently reset all account settings.
  private var _isPlayQueueSyncActive: Bool? = nil
  public var isPlayQueueSyncActive: Bool {
    get { _isPlayQueueSyncActive ?? true }
    set { _isPlayQueueSyncActive = newValue }
  }

  /// two-tier storage (G6): maximum size of the evictable `.cache` download
  /// tier in megabytes — user-pinned `.pinned` downloads never count against
  /// it and are never evicted by it. `0` disables the limit (unbounded cache).
  /// Backed by an Optional so that decoding older persisted `AccountSetting`s
  /// (which lack this key) does not fail and silently reset all account settings.
  private var _cacheSizeLimitMB: Int? = nil
  public var cacheSizeLimitMB: Int {
    get { _cacheSizeLimitMB ?? AccountSetting.defaultCacheSizeLimitMB }
    set { _cacheSizeLimitMB = newValue }
  }

  /// the configured `.cache` tier cap in bytes (0 = unlimited)
  public var cacheSizeLimitBytes: Int64 {
    Int64(max(0, cacheSizeLimitMB)) * 1_048_576
  }

  /// synced lyrics (G4): allow lyric lookups against LRCLIB
  /// (`https://lrclib.net`) as the last-resort source. Third-party host —
  /// requests carry only public track metadata, never account credentials.
  /// Defaults to `false` — opt-in so self-hosted users get no third-party
  /// calls unless they explicitly enable it.
  // optional backing to stay decodable for settings stored before this key existed
  private var _isSyncedLyricsExternalLookupActive: Bool? = nil
  public var isSyncedLyricsExternalLookupActive: Bool {
    get { _isSyncedLyricsExternalLookupActive ?? false }
    set { _isSyncedLyricsExternalLookupActive = newValue }
  }

  /// album-queue shuffle (G21): when enabled, `playShuffled` on a
  /// multi-album music context queues whole albums in shuffled order and
  /// lazily appends the next shuffled album as the queue drains
  /// ("album radio"), instead of shuffling individual songs.
  // optional backing to stay decodable for settings stored before this key existed
  private var _isAlbumShuffleActive: Bool? = nil
  public var isAlbumShuffleActive: Bool {
    get { _isAlbumShuffleActive ?? false }
    set { _isAlbumShuffleActive = newValue }
  }

  private var _isScrobbleStreamedItems: Bool = false
  public var isScrobbleStreamedItems: Bool {
    get { _isScrobbleStreamedItems }
    set { _isScrobbleStreamedItems = newValue }
  }

  private var _libraryDisplaySettings: LibraryDisplaySettings = .defaultSettings
  public var libraryDisplaySettings: LibraryDisplaySettings {
    get { _libraryDisplaySettings }
    set { _libraryDisplaySettings = newValue }
  }

  private var _loginCredentials: LoginCredentials? = nil
  public var loginCredentials: LoginCredentials? {
    get { _loginCredentials }
    set { _loginCredentials = newValue }
  }

  private var _themePreference: ThemePreference = .defaultValue
  public var themePreference: ThemePreference {
    get { _themePreference }
    set { _themePreference = newValue }
  }

  /// artwork-adaptive theming (G24, design-system §2.4): how strongly the
  /// Now Playing surface absorbs the current artwork's dominant colors —
  /// `.off` = pure semantic background, `.subtle` = two-stop gradient
  /// (default), `.vivid` = four-stop gradient + accent-tinted controls.
  // optional backing to stay decodable for settings stored before this key existed
  private var _artworkTintIntensity: ArtworkTintIntensity? = nil
  public var artworkTintIntensity: ArtworkTintIntensity {
    get { _artworkTintIntensity ?? .defaultValue }
    set { _artworkTintIntensity = newValue }
  }

  /// share links (G18): public base URL for servers behind a reverse
  /// proxy — server-generated share URLs are rewritten to this host when
  /// set (`ShareUrlRewriter`). `nil` = use the server-provided URL as-is.
  private var _publicUrlOverride: String? = nil
  public var publicUrlOverride: String? {
    get { _publicUrlOverride }
    set { _publicUrlOverride = newValue }
  }
}

// MARK: - ReadOnlyAccountSetting

public struct ReadOnlyAccountSetting {
  public let read: AccountSetting
}

// MARK: - AccountSettings

public struct AccountSettings: Sendable, Codable {
  fileprivate var _accounts: [AccountInfo: AccountSetting] = [:]
  fileprivate var _activeAccount: AccountInfo?

  public mutating func switchActiveAccount(_ accountInfo: AccountInfo) {
    _activeAccount = accountInfo
  }

  public mutating func login(_ loginCredentials: LoginCredentials) {
    let accountInfo = Account.createInfo(credentials: loginCredentials)
    let newTheme = themeColorForNextNewAccount
    updateSetting(accountInfo) { accountSettings in
      accountSettings.loginCredentials = loginCredentials
      accountSettings.themePreference = newTheme
    }
    _activeAccount = accountInfo
  }

  public func getSetting(_ accountInfo: AccountInfo?) -> ReadOnlyAccountSetting {
    // Settings Priority:
    // 1.: provided account settings (if not nil)
    // 2.: active account settings (if logged in)
    // 3.: default settings
    if let info = accountInfo ?? _activeAccount, let accountSettings = _accounts[info] {
      return ReadOnlyAccountSetting(read: accountSettings)
    } else {
      return ReadOnlyAccountSetting(read: AccountSetting())
    }
  }

  public mutating func logout(_ accountInfo: AccountInfo) {
    _accounts[accountInfo] = nil
    // drop the Keychain-held secrets (password + httpHeaders) as well
    LoginCredentials.deletePersistedSecrets(accountIdent: accountInfo.ident)
    if _activeAccount == accountInfo {
      _activeAccount = _accounts.first?.key
    }
  }

  public mutating func updateSetting(
    _ accountInfo: AccountInfo,
    _ update: (inout AccountSetting) -> ()
  ) {
    var setting = _accounts[accountInfo] ?? AccountSetting()
    update(&setting)
    _accounts[accountInfo] = setting
  }

  public var active: AccountInfo? {
    _activeAccount
  }

  public var activeSetting: ReadOnlyAccountSetting {
    guard let _activeAccount else { return ReadOnlyAccountSetting(read: AccountSetting()) }
    return ReadOnlyAccountSetting(read: _accounts[_activeAccount] ?? AccountSetting())
  }

  public var availableApiTypes: Set<ServerApiType> {
    Set(_accounts.compactMap { $0.value.loginCredentials?.backendApi.asServerApiType })
  }

  public var allAccounts: [AccountInfo] {
    _accounts.compactMap { $0.key }.sorted(by: {
      guard let cred0 = getSetting($0).read.loginCredentials,
            let cred1 = getSetting($1).read.loginCredentials
      else { return false }

      if cred0.displayServerUrl != cred1.displayServerUrl {
        return cred0.displayServerUrl < cred1.displayServerUrl
      } else {
        return cred0.username < cred1.username
      }
    })
  }

  private var themeColorForNextNewAccount: ThemePreference {
    var theme = ThemePreference.blue
    let usedThemes = Set(_accounts.compactMap { $0.value.themePreference })
    let allThemes = Set(ThemePreference.allCases)
    let availableThemes = allThemes.subtracting(usedThemes)
    if let firstAvailable = availableThemes.sorted(by: { $0.rawValue < $1.rawValue }).first {
      theme = firstAvailable
    } else if let activeAccount = _activeAccount {
      let activeTheme = getSetting(activeAccount).read.themePreference
      theme = allThemes.subtracting(Set([activeTheme])).sorted(by: { $0.rawValue < $1.rawValue })
        .first ?? .blue
    }
    return theme
  }
}

// MARK: - AmperfySettings

public struct AmperfySettings: Sendable, Codable {
  // MARK: - Persistence

  private static let decoder: JSONDecoder = .init()
  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = []
    return e
  }()

  private var _appSettings: AppSettings = .init()
  public var app: AppSettings {
    get {
      guard let data = UserDefaults.standard
        .data(forKey: PersistentStorage.UserDefaultsKey.SettingsApp.rawValue)
      else { return _appSettings }
      do {
        return try Self.decoder.decode(AppSettings.self, from: data)
      } catch {
        return _appSettings
      }
    }
    set {
      _appSettings = newValue
      do {
        let data = try Self.encoder.encode(_appSettings)
        UserDefaults.standard.set(
          data,
          forKey: PersistentStorage.UserDefaultsKey.SettingsApp.rawValue
        )
      } catch {}
    }
  }

  private var _userSettings: UserSettings = .init()
  public var user: UserSettings {
    get {
      guard let data = UserDefaults.standard
        .data(forKey: PersistentStorage.UserDefaultsKey.SettingsUser.rawValue)
      else { return _userSettings }
      do {
        return try Self.decoder.decode(UserSettings.self, from: data)
      } catch {
        return _userSettings
      }
    }
    set {
      _userSettings = newValue
      do {
        let data = try Self.encoder.encode(_userSettings)
        UserDefaults.standard.set(
          data,
          forKey: PersistentStorage.UserDefaultsKey.SettingsUser.rawValue
        )
      } catch {}
    }
  }

  private var _accountSettings: AccountSettings = .init()
  public var accounts: AccountSettings {
    get {
      guard let data = UserDefaults.standard
        .data(forKey: PersistentStorage.UserDefaultsKey.SettingsAccount.rawValue)
      else { return _accountSettings }
      do {
        return try Self.decoder.decode(AccountSettings.self, from: data)
      } catch {
        return _accountSettings
      }
    }
    set {
      _accountSettings = newValue
      do {
        let data = try Self.encoder.encode(_accountSettings)
        UserDefaults.standard.set(
          data,
          forKey: PersistentStorage.UserDefaultsKey.SettingsAccount.rawValue
        )
      } catch {}
    }
  }
}
