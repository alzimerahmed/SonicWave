//
//  PopupPlayer+Visuals.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 11.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import DominantColors
import UIKit

extension PopupPlayerVC {
  func refresh() {
    refreshContextQueueSectionHeader()
    refreshUserQueueSectionHeader()
    refreshCellMasks()
    refreshCellsContent()
    refreshCurrentlyPlayingInfoView()
  }

  func refreshCurrentlyPlayingInfoView() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refresh()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refresh()
        break
      }
    }
  }

  func refreshCurrentlyPlayingArtworks() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refreshArtwork()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refreshArtwork()
        break
      }
    }
  }

  func refreshOptionButton(button: UIButton, rootView: UIViewController?) {
    var config = UIButton.Configuration.playerRound()
    config.image = .ellipsis
    config.baseForegroundColor = .label
    button.isEnabled = true
    button.configuration = config

    if let currentlyPlaying = appDelegate.player.currentlyPlaying,
       let rootView = rootView {
      button.showsMenuAsPrimaryAction = true
      button.menu = UIMenu.lazyMenu {
        EntityPreviewActionBuilder(container: currentlyPlaying, on: rootView).createMenuActions()
      }
      button.isEnabled = true
    } else {
      button.isEnabled = false
    }
  }

  func refreshFavoriteButton(button: UIButton) {
    var config = UIButton.Configuration.playerRound()
    switch player.playerMode {
    case .music:
      if let playableInfo = player.currentlyPlaying,
         playableInfo.isSong {
        config.image = playableInfo.isFavorite ? .heartFill : .heartEmpty
        config.baseForegroundColor = appDelegate.storage.settings.user
          .isOnlineMode ? .redHeart : .label
        button.isEnabled = appDelegate.storage.settings.user.isOnlineMode
      } else if let playableInfo = player.currentlyPlaying,
                let radio = playableInfo.asRadio {
        config.image = .followLink
        config.baseForegroundColor = .label
        button.isEnabled = radio.siteURL != nil
      } else {
        config.image = .heartEmpty
        config.baseForegroundColor = .redHeart
        button.isEnabled = false
      }
    case .podcast:
      config.image = .info
      config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .large)
      config.baseForegroundColor = .label
      button.isEnabled = true
    }
    if #available(iOS 17.0, *) {
      button.isSymbolAnimationEnabled = true
    }
    button.configuration = config
  }

  func refreshBackgroundItemArtwork() {
    var artwork: UIImage?
    var accountSetting: AccountSetting = appDelegate.storage.settings.accounts.activeSetting.read
    if let playableInfo = player.currentlyPlaying, let accountInfo = playableInfo.account?.info {
      accountSetting = appDelegate.storage.settings.accounts.getSetting(accountInfo).read
      artwork = LibraryEntityImage.getImageToDisplayImmediately(
        libraryEntity: playableInfo,
        themePreference: accountSetting.themePreference,
        artworkDisplayPreference: accountSetting.artworkDisplayPreference,
        useCache: true
      )
    } else {
      switch player.playerMode {
      case .music:
        artwork = .getGeneratedArtwork(
          theme: accountSetting.themePreference,
          artworkType: .song
        )
      case .podcast:
        artwork = .getGeneratedArtwork(
          theme: accountSetting.themePreference,
          artworkType: .podcastEpisode
        )
      }
    }
    guard let artwork = artwork else { return }
    backgroundImage.image = artwork

    // §2.4 artwork-adaptive layer: extract up to four dominant colors so
    // the most saturated one can become the accent; the account's
    // `artworkTintIntensity` decides how far the tint reaches.
    let extracted = (try? artwork.dominantColors(max: 4)) ?? []
    artworkTint = ArtworkTintPalette(
      extractedColors: extracted,
      fallbackTheme: accountSetting.themePreference,
      intensity: accountSetting.artworkTintIntensity,
      isTrueBlack: appDelegate.isTrueBlackActive(in: traitCollection)
    )
    artworkGradientColors = artworkTint.gradientColors
    applyGradientBackground(isAnimated: true)
    applyArtworkTint()
  }

  /// pushes the resolved `sonicArtwork*` palette into the surfaces that
  /// consume it — controls (slider tint, codec chip) and hero metadata
  func applyArtworkTint() {
    controlView?.applyArtworkTint(artworkTint)
    largeCurrentlyPlayingView?.applyArtworkTint(artworkTint)
  }

  /// §2.4 — persistent gradient layer; color swaps ride the 2s linear
  /// `AnimatedGradientLayer` crossfade on track change and go instant
  /// under Reduce Motion. `.off` drops the artwork surface entirely and
  /// leaves a pure semantic (or true-black) background.
  internal func applyGradientBackground(isAnimated: Bool = false) {
    let isTinted = artworkTint.isArtworkTinted
    backgroundImage.isHidden = !isTinted
    view.backgroundColor = isTinted
      ? .clear
      : .sonicSystemBackground(in: traitCollection)
    guard isTinted else { return }

    if artworkGradientLayer == nil {
      let layer = AnimatedGradientLayer(view: backgroundImage)
      layer.animationDuration = SonicMotion.artworkCrossfadeDuration
      layer.animationStyle = .linear
      artworkGradientLayer = layer
    }
    artworkGradientLayer?.adjustTo(size: backgroundImage.bounds.size)
    artworkGradientLayer?.setColors(
      artworkGradientColors.compactMap { $0.cgColor },
      at: artworkTint.gradientLocations,
      isAnimated: isAnimated && !SonicMotion.isReduceMotionEnabled
    )
  }

  @objc
  internal func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification),
          let curPlayable = player.currentlyPlaying
    else { return }
    if curPlayable.uniqueID == downloadNotification.id {
      Task { @MainActor in
        refreshBackgroundItemArtwork()
      }
    }
    if let artwork = curPlayable.artwork,
       artwork.uniqueID == downloadNotification.id {
      Task { @MainActor in
        refreshBackgroundItemArtwork()
      }
    }
  }

  func adjustLayoutMargins() {
    view.layoutMargins = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
  }
}
