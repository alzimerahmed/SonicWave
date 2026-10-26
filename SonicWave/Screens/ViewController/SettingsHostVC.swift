//
//  SettingsHostVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
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
import Combine
import Foundation
import SwiftUI
import UIKit

class SettingsHostVC: UIViewController {
  lazy var settings: Settings = {
    Settings()
  }()

  var changesAgent: [AnyCancellable] = []
  private var isForOwnWindow = false
  private var accountNotificationHandler: AccountNotificationHandler?

  override var sceneTitle: String { windowSettingsTitle }

  init(isForOwnWindow: Bool) {
    super.init(nibName: nil, bundle: nil)
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] accountInfo in
      guard let self else { return }
      settings.activeAccountInfo = accountInfo
      refreshAccountSettings(accountInfo: accountInfo)
    }

    self.isForOwnWindow = isForOwnWindow

    var settingsRootView: AnyView? = nil
    if isForOwnWindow {
      settingsRootView = AnyView(
        SettingsTabView()
          .environmentObject(settings)
          .environment(\.managedObjectContext, appDelegate.storage.main.context)
      )
    } else {
      settingsRootView = AnyView(
        SettingsView()
          .environmentObject(settings)
          .environment(\.managedObjectContext, appDelegate.storage.main.context)
      )
    }

    let hostingVC = UIHostingController(
      rootView: settingsRootView
    )
    view.backgroundColor = .clear
    hostingVC.view.frame = view.bounds
    hostingVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostingVC.view.backgroundColor = .clear

    hostingVC.willMove(toParent: self)
    addChild(hostingVC)
    view.addSubview(hostingVC.view)
    hostingVC.didMove(toParent: self)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    changesAgent = [AnyCancellable]()

    if !isForOwnWindow {
      extendSafeAreaToAccountForMiniPlayer()
    }

    settings.isOfflineMode = appDelegate.storage.settings.user.isOfflineMode
    changesAgent.append(settings.$isOfflineMode.sink(receiveValue: { newValue in
      let hasValueChanged = self.appDelegate.storage.settings.user.isOfflineMode != newValue
      guard hasValueChanged else { return }
      self.appDelegate.switchOnlineOfflineMode(isOfflineMode: newValue)
    }))

    settings.isShowDetailedInfo = appDelegate.storage.settings.user.isShowDetailedInfo
    changesAgent.append(settings.$isShowDetailedInfo.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isShowDetailedInfo = newValue
    }))

    settings.isShowSongDuration = appDelegate.storage.settings.user.isShowSongDuration
    changesAgent.append(settings.$isShowSongDuration.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isShowSongDuration = newValue
    }))

    settings.isShowAlbumDuration = appDelegate.storage.settings.user.isShowAlbumDuration
    changesAgent.append(settings.$isShowAlbumDuration.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isShowAlbumDuration = newValue
    }))

    settings.isShowArtistDuration = appDelegate.storage.settings.user.isShowArtistDuration
    changesAgent.append(settings.$isShowArtistDuration.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isShowArtistDuration = newValue
    }))

    settings.isShowRating = appDelegate.storage.settings.user.isShowRating
    changesAgent.append(settings.$isShowRating.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isShowRating = newValue
    }))

    settings.isPlayerShuffleButtonEnabled = appDelegate.storage.settings.user
      .isPlayerShuffleButtonEnabled
    changesAgent.append(settings.$isPlayerShuffleButtonEnabled.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled = newValue
    }))

    settings.isShowMusicPlayerSkipButtons = appDelegate.storage.settings.user
      .isShowMusicPlayerSkipButtons
    changesAgent.append(settings.$isShowMusicPlayerSkipButtons.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isShowMusicPlayerSkipButtons = newValue
    }))

    settings.isLyricsSmoothScrolling = appDelegate.storage.settings.user.isLyricsSmoothScrolling
    changesAgent.append(settings.$isLyricsSmoothScrolling.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isLyricsSmoothScrolling = newValue
    }))

    settings.screenLockPreventionPreference = appDelegate.storage.settings.user
      .screenLockPreventionPreference
    changesAgent.append(settings.$screenLockPreventionPreference.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.screenLockPreventionPreference = newValue
    }))

    settings.streamingMaxBitrateWifiPreference = appDelegate.storage.settings.user
      .streamingMaxBitrateWifiPreference
    changesAgent.append(settings.$streamingMaxBitrateWifiPreference.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.streamingMaxBitrateWifiPreference = newValue
    }))

    settings.streamingMaxBitrateCellularPreference = appDelegate.storage.settings.user
      .streamingMaxBitrateCellularPreference
    changesAgent
      .append(settings.$streamingMaxBitrateCellularPreference.sink(receiveValue: { newValue in
        self.appDelegate.storage.settings.user.streamingMaxBitrateCellularPreference = newValue
      }))

    settings.streamingFormatCellularPreference = appDelegate.storage.settings.user
      .streamingFormatCellularPreference
    changesAgent.append(settings.$streamingFormatCellularPreference.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.streamingFormatCellularPreference = newValue
    }))

    settings.streamingFormatWifiPreference = appDelegate.storage.settings.user
      .streamingFormatWifiPreference
    changesAgent.append(settings.$streamingFormatWifiPreference.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.streamingFormatWifiPreference = newValue
    }))

    settings.cacheTranscodingFormatPreference = appDelegate.storage.settings.user
      .cacheTranscodingFormatPreference
    changesAgent.append(settings.$cacheTranscodingFormatPreference.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.cacheTranscodingFormatPreference = newValue
    }))

    settings.isPlayerAutoCachePlayedItems = appDelegate.player.isAutoCachePlayedItems
    changesAgent.append(settings.$isPlayerAutoCachePlayedItems.sink(receiveValue: { newValue in
      self.appDelegate.player.isAutoCachePlayedItems = newValue
    }))

    settings.isPlaybackStartOnlyOnPlay = appDelegate.storage.settings.user.isPlaybackStartOnlyOnPlay
    changesAgent.append(settings.$isPlaybackStartOnlyOnPlay.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isPlaybackStartOnlyOnPlay = newValue
    }))

    settings.isRowTapPlaybackEnabled = appDelegate.storage.settings.user.isRowTapPlaybackEnabled
    changesAgent.append(settings.$isRowTapPlaybackEnabled.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isRowTapPlaybackEnabled = newValue
    }))
    settings.isPlayerSongPlaybackResumeEnabled = appDelegate.storage.settings.user
      .isPlayerSongPlaybackResumeEnabled
    changesAgent.append(settings.$isPlayerSongPlaybackResumeEnabled.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isPlayerSongPlaybackResumeEnabled = newValue
    }))

    settings.isAutoplayEnabled = appDelegate.storage.settings.user.isAutoplayEnabled
    changesAgent.append(settings.$isAutoplayEnabled.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isAutoplayEnabled = newValue
    }))

    settings.crossfadeDurationInSec = appDelegate.player.crossfadeDurationInSec
    changesAgent.append(settings.$crossfadeDurationInSec.sink(receiveValue: { newValue in
      // guarded: the sink fires on the initial assignment too — only
      // persist + re-apply on a real user change
      let hasValueChanged = self.appDelegate.player.crossfadeDurationInSec != newValue
      guard hasValueChanged else { return }
      // the facade setter persists `user.crossfadeDurationSeconds` and
      // pushes the duration to the engine in one call
      self.appDelegate.player.crossfadeDurationInSec = newValue
    }))

    settings.isSkipSilenceEnabled = appDelegate.player.isSkipSilenceEnabled
    changesAgent.append(settings.$isSkipSilenceEnabled.sink(receiveValue: { newValue in
      let hasValueChanged = self.appDelegate.player.isSkipSilenceEnabled != newValue
      guard hasValueChanged else { return }
      // persists the flag; `SkipSilenceService` re-evaluates it on its
      // 1s tick and only ever engages in `.podcast` player mode
      self.appDelegate.player.isSkipSilenceEnabled = newValue
    }))

    settings.swipeActionSettings = appDelegate.storage.settings.user.swipeActionSettings

    settings.isReplayGainEnabled = appDelegate.storage.settings.user.isReplayGainEnabled
    changesAgent.append(settings.$isReplayGainEnabled.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isReplayGainEnabled = newValue
      self.appDelegate.player.updateReplayGainEnabled(isEnabled: newValue)
    }))

    settings.isEqualizerEnabled = appDelegate.storage.settings.user.isEqualizerEnabled
    changesAgent.append(settings.$isEqualizerEnabled.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isEqualizerEnabled = newValue
      self.appDelegate.player.updateEqualizerEnabled(isEnabled: newValue)
    }))

    settings.activeEqualizerSetting = appDelegate.storage.settings.user.activeEqualizerSetting
    changesAgent.append(settings.$activeEqualizerSetting.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.activeEqualizerSetting = newValue
      self.appDelegate.player.updateEqualizerSetting(eqSetting: newValue)
    }))

    settings.equalizerSettings = appDelegate.storage.settings.user.equalizerSettings
    changesAgent.append(settings.$equalizerSettings.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.equalizerSettings = newValue
    }))

    settings.activeParametricEqualizerSetting = appDelegate.storage.settings.user
      .activeParametricEqualizerSetting
    changesAgent.append(
      settings.$activeParametricEqualizerSetting.sink(receiveValue: { newValue in
        // guarded: the sink fires on the initial assignment too — only
        // persist + re-apply on a real user change
        let hasValueChanged = self.appDelegate.storage.settings.user
          .activeParametricEqualizerSetting != newValue
        guard hasValueChanged else { return }
        self.appDelegate.storage.settings.user.activeParametricEqualizerSetting = newValue
        if let newValue {
          self.appDelegate.player.updateEqualizerProfile(newValue)
        } else {
          // profile-kind switch back to the graphic curve — without this
          // a stale parametric profile would keep applying in the engine
          self.appDelegate.player.updateEqualizerSetting(
            eqSetting: self.appDelegate.storage.settings.user.activeEqualizerSetting
          )
        }
      })
    )

    settings.parametricEqualizerSettings = appDelegate.storage.settings.user
      .parametricEqualizerSettings
    changesAgent.append(settings.$parametricEqualizerSettings.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.parametricEqualizerSettings = newValue
    }))

    // the route→profile map is only ever written through
    // `player.setRouteEqualizerProfile` (persists + pushes engine
    // overrides in one call) — mirrored here for the EQ settings UI
    settings.routeEqualizerProfileNames = appDelegate.player.routeEqualizerProfileNames

    changesAgent.append(settings.$swipeActionSettings.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.swipeActionSettings = newValue
    }))

    settings.cacheSizeLimit = appDelegate.storage.settings.user.cacheLimit
    changesAgent.append(settings.$cacheSizeLimit.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.cacheLimit = newValue
    }))

    settings.isHapticsEnabled = appDelegate.storage.settings.user.isHapticsEnabled
    changesAgent.append(settings.$isHapticsEnabled.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isHapticsEnabled = newValue
    }))

    settings.isMiniPlayerAlwaysOnTop = appDelegate.storage.settings.user.isMiniPlayerAlwaysOnTop
    changesAgent.append(settings.$isMiniPlayerAlwaysOnTop.sink(receiveValue: { newValue in
      let hasValueChanged = self.appDelegate.storage.settings.user
        .isMiniPlayerAlwaysOnTop != newValue
      guard hasValueChanged else { return }
      self.appDelegate.storage.settings.user.isMiniPlayerAlwaysOnTop = newValue
      self.appDelegate.updateMiniPlayerAlwaysOnTop()
    }))

    settings.appearanceMode = appDelegate.storage.settings.user.appearanceMode
    changesAgent.append(settings.$appearanceMode.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.appearanceMode = newValue
      self.appDelegate.setAppAppearanceMode(style: newValue)
    }))

    settings.blackModePreference = appDelegate.storage.settings.user.blackModePreference
    changesAgent.append(settings.$blackModePreference.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.blackModePreference = newValue
      // re-resolve the override — `.dark`/`.trueBlack` force the dark
      // interface, `.trueBlack` additionally swaps surfaces to pure black
      self.appDelegate
        .setAppAppearanceMode(style: self.appDelegate.storage.settings.user.appearanceMode)
    }))

    settings.isMusicHapticsActive = appDelegate.storage.settings.user.isMusicHapticsActive
    changesAgent.append(settings.$isMusicHapticsActive.sink(receiveValue: { newValue in
      self.appDelegate.storage.settings.user.isMusicHapticsActive = newValue
    }))

    settings.isLiveActivityEnabled = appDelegate.storage.settings.user.isLiveActivityEnabled
    changesAgent.append(settings.$isLiveActivityEnabled.sink(receiveValue: { newValue in
      // guarded: the sink fires on the initial assignment too — only
      // persist + re-evaluate on a real user change
      let hasValueChanged = self.appDelegate.storage.settings.user
        .isLiveActivityEnabled != newValue
      guard hasValueChanged else { return }
      self.appDelegate.storage.settings.user.isLiveActivityEnabled = newValue
      // a running activity honors the opt-out on the next player event;
      // nudge it now so disabling takes effect immediately
      self.appDelegate.widgetBridge.notifyLiveActivitySettingChanged()
    }))

    settings.isSpotlightIndexingEnabled = appDelegate.storage.settings.user
      .isSpotlightIndexingEnabled
    changesAgent.append(settings.$isSpotlightIndexingEnabled.sink(receiveValue: { newValue in
      // guarded: the sink fires on the initial assignment too — only
      // persist + re-evaluate on a real user change
      let hasValueChanged = self.appDelegate.storage.settings.user
        .isSpotlightIndexingEnabled != newValue
      guard hasValueChanged else { return }
      self.appDelegate.storage.settings.user.isSpotlightIndexingEnabled = newValue
      // `start()` re-evaluates the flag both ways — disabling stops the
      // indexer and wipes the index, enabling re-arms the full pass
      Task { await AmperKit.shared.spotlightIndexer.start() }
    }))

    // following account specific setting sinks are assigned.
    // the correct assignment is done in the account switched callback

    changesAgent.append(settings.$themePreference.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.themePreference = newValue
        }
    }))
    changesAgent.append(settings.$isAutoCacheLatestSongs.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.isAutoDownloadLatestSongsActive = newValue
        }
    }))
    changesAgent.append(settings.$isAutoCacheLatestPodcastEpisodes.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.isAutoDownloadLatestPodcastEpisodesActive = newValue
        }
    }))
    changesAgent.append(settings.$isScrobbleStreamedItems.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.isScrobbleStreamedItems = newValue
        }
    }))
    changesAgent.append(settings.$isAutoDownloadFavorites.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.isAutoDownloadFavoritesActive = newValue
        }
    }))
    changesAgent.append(settings.$isPlayQueueSyncActive.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.isPlayQueueSyncActive = newValue
        }
    }))
    changesAgent.append(settings.$artworkTintIntensity.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.artworkTintIntensity = newValue
        }
    }))
    changesAgent
      .append(settings.$isSyncedLyricsExternalLookupActive.sink(receiveValue: { newValue in
        guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
        self.appDelegate.storage.settings.accounts
          .updateSetting(activeAccountInfo) { accountSettings in
            accountSettings.isSyncedLyricsExternalLookupActive = newValue
          }
      }))
    changesAgent.append(settings.$isAlbumShuffleActive.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.isAlbumShuffleActive = newValue
        }
    }))
    changesAgent.append(settings.$cacheSizeLimitMB.sink(receiveValue: { newValue in
      guard let activeAccountInfo = self.settings.activeAccountInfo else { return }
      // guarded: the sink fires on the initial assignment too — only
      // persist + trim on a real user change
      let hasValueChanged = self.appDelegate.storage.settings.accounts
        .getSetting(activeAccountInfo).read.cacheSizeLimitMB != newValue
      guard hasValueChanged else { return }
      self.appDelegate.storage.settings.accounts
        .updateSetting(activeAccountInfo) { accountSettings in
          accountSettings.cacheSizeLimitMB = newValue
        }
      // retire the legacy global hard-stop (user.cacheLimit) — the
      // per-account LRU cap is now the single user-facing cache limit
      self.appDelegate.storage.settings.user.cacheLimit = 0
      Task { @MainActor in
        await self.appDelegate.getMeta(activeAccountInfo).playableDownloadManager
          .trimCacheToLimit()
      }
    }))
  }

  // account is changed via the active account changed callback
  func refreshAccountSettings(accountInfo: AccountInfo?) {
    settings.activeAccountInfo = accountInfo

    settings.themePreference = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .themePreference

    settings.isAutoCacheLatestSongs = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .isAutoDownloadLatestSongsActive

    settings.isAutoCacheLatestPodcastEpisodes = appDelegate.storage.settings.accounts
      .getSetting(accountInfo)
      .read
      .isAutoDownloadLatestPodcastEpisodesActive

    settings.isScrobbleStreamedItems = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .isScrobbleStreamedItems

    settings.isAutoDownloadFavorites = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .isAutoDownloadFavoritesActive

    settings.isPlayQueueSyncActive = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .isPlayQueueSyncActive

    settings.cacheSizeLimitMB = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .cacheSizeLimitMB

    settings.artworkTintIntensity = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .artworkTintIntensity

    settings.isSyncedLyricsExternalLookupActive = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .isSyncedLyricsExternalLookupActive

    settings.isAlbumShuffleActive = appDelegate.storage.settings.accounts
      .getSetting(accountInfo).read
      .isAlbumShuffleActive
  }

  @IBSegueAction
  func segueToSwiftUI(_ coder: NSCoder) -> UIViewController? {
    UIHostingController(
      coder: coder,
      rootView:
      SettingsView()
        .environmentObject(settings)
        .environment(\.managedObjectContext, appDelegate.storage.main.context)
    )
  }
}
