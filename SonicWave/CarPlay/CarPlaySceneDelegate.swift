//
//  CarPlaySceneDelegate.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 17.08.22.
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
@preconcurrency import CarPlay
import CoreData
import Foundation
import OSLog
import UIKit

// MARK: - CarPlayShortPreference

struct CarPlayShortPreference {
  let theme: ThemePreference
  let artworkDisplayPreference: ArtworkDisplayPreference
}

// MARK: - CarPlaySceneDelegate

@MainActor
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  static let maxTreeDepth = 4

  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "CarPlay")
  private static let assistantConfig = CPAssistantCellConfiguration(
    position: .top,
    visibility: .always,
    assistantAction: .playMedia
  )
  var isOfflineMode: Bool {
    appDelegate.storage.settings.user.isOfflineMode
  }

  func getPreference(_ accountInfo: AccountInfo?) -> CarPlayShortPreference {
    CarPlayShortPreference(
      theme: appDelegate.storage.settings.accounts.getSetting(accountInfo).read.themePreference,
      artworkDisplayPreference: appDelegate.storage.settings.accounts.getSetting(accountInfo).read
        .artworkDisplayPreference
    )
  }

  var activeAccountInfo: AccountInfo!
  var activeAccount: Account!
  var accountNotificationHandler: AccountNotificationHandler?
  var sharedHome: HomeManager?

  var interfaceController: CPInterfaceController?
  var traits: UITraitCollection {
    interfaceController?.carTraitCollection ?? UITraitCollection.maxDisplayScale
  }

  /// CarPlay connected
  nonisolated func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    Task { @MainActor in
      os_log("CarPlay: didConnect", log: self.log, type: .info)
      resetFetchController()
      resetTemplates()
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(refreshSort),
        name: .fetchControllerSortChanged,
        object: nil
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(refreshOfflineMode),
        name: .offlineModeChanged,
        object: nil
      )
      accountNotificationHandler = AccountNotificationHandler(
        storage: appDelegate.storage,
        notificationHandler: appDelegate.notificationHandler
      )
      accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
        guard let self else { return }
        let meta = appDelegate.getMeta(accountInfo)
        appDelegate.notificationHandler.register(
          self,
          selector: #selector(downloadFinishedSuccessful(notification:)),
          name: .downloadFinishedSuccess,
          object: meta.artworkDownloadManager
        )
        appDelegate.notificationHandler.register(
          self,
          selector: #selector(downloadFinishedSuccessful(notification:)),
          name: .downloadFinishedSuccess,
          object: meta.playableDownloadManager
        )
      }

      appDelegate.player.addNotifier(notifier: self)
      CPNowPlayingTemplate.shared.add(self)
      self.interfaceController = interfaceController
      self.interfaceController?.delegate = self
      self.configureNowPlayingTemplate()

      accountNotificationHandler?
        .registerCallbackForActiveAccountChange { [weak self] accountInfo in
          guard let self else { return }
          resetFetchController()
          activeAccountInfo = accountInfo
          guard let accountInfo else {
            os_log(
              "CarPlay: no account available -> display Disconnected",
              log: self.log,
              type: .info
            )
            activeAccount = nil
            self.interfaceController?.setRootTemplate(
              disconnectedTemplate,
              animated: true,
              completion: nil
            )
            return
          }
          activeAccount = appDelegate.storage.main.library.getAccount(info: accountInfo)
          sharedHome = HomeManager(
            account: activeAccount,
            storage: appDelegate.storage,
            getMeta: appDelegate.getMeta,
            eventLogger: appDelegate.eventLogger
          )
          sharedHome?.applySnapshotCB = { [weak self] in
            guard let self else { return }
            updateHomeSections()
          }
          self.interfaceController?.setRootTemplate(
            rootBarTemplate,
            animated: false,
            completion: nil
          )
          Task { @MainActor in
            self.refreshOfflineMode()
          }
        }

      if self.appDelegate.player.currentlyPlaying != nil, self.appDelegate.player.isPlaying {
        self.updatePlayerQueueSection()
        self.displayNowPlaying(immediately: true) {}
      }
    }
  }

  /// CarPlay disconnected
  nonisolated func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    Task { @MainActor in
      os_log("CarPlay: didDisconnect", log: self.log, type: .info)
      // Teardown is unconditional: observers, fetch controllers and templates
      // must be released even when no account is active, otherwise they keep
      // firing callbacks into the next CarPlay session.
      self.interfaceController = nil
      appDelegate.notificationHandler.remove(self, name: .fetchControllerSortChanged, object: nil)
      appDelegate.notificationHandler.remove(self, name: .offlineModeChanged, object: nil)
      appDelegate.notificationHandler.remove(self, name: .downloadFinishedSuccess, object: nil)
      CPNowPlayingTemplate.shared.remove(self)

      resetFetchController()
      resetTemplates()

      sharedHome = nil
      activeAccount = nil
      activeAccountInfo = nil
      accountNotificationHandler = nil
    }
  }

  // CarPlay templates must never be re-pushed onto a different
  // `CPInterfaceController`. They are therefore kept in resettable storage
  // instead of `lazy var` and are invalidated by `resetTemplates()` on every
  // disconnect; each access lazily recreates a fresh template.
  private var _playerQueueSection: CPListTemplate?
  var playerQueueSection: CPListTemplate {
    if let template = _playerQueueSection { return template }
    let template = CPListTemplate(title: Self.queueButtonText, sections: [CPListSection]())
    _playerQueueSection = template
    return template
  }

  private var _disconnectedTemplate: CPListTemplate?
  var disconnectedTemplate: CPListTemplate {
    if let template = _disconnectedTemplate { return template }
    let template = CPListTemplate(title: "Disconnected", sections: [])
    _disconnectedTemplate = template
    return template
  }

  private var _rootBarTemplate: CPTabBarTemplate?
  var rootBarTemplate: CPTabBarTemplate {
    if let template = _rootBarTemplate { return template }
    let template = CPTabBarTemplate(templates: [
      homeTab,
      libraryTab,
      cachedTab,
      playlistTab,
    ].prefix(upToAsArray: CPTabBarTemplate.maximumTabCount))
    _rootBarTemplate = template
    return template
  }

  private var _playlistTab: CPListTemplate?
  var playlistTab: CPListTemplate {
    if let template = _playlistTab { return template }
    let template = CPListTemplate(title: "Playlists", sections: [CPListSection]())
    template.tabImage = UIImage.playlist
    _playlistTab = template
    return template
  }

  private var _libraryTab: CPListTemplate?
  var libraryTab: CPListTemplate {
    if let template = _libraryTab { return template }
    let template = CPListTemplate(title: "Library", sections: createLibrarySections())
    template.tabImage = UIImage.musicLibrary
    template.assistantCellConfiguration = CarPlaySceneDelegate.assistantConfig
    _libraryTab = template
    return template
  }

  private var _homeTab: CPListTemplate?
  var homeTab: CPListTemplate {
    if let template = _homeTab { return template }
    let template = CPListTemplate(title: "Home", sections: [])
    template.tabImage = UIImage.home
    template.assistantCellConfiguration = CarPlaySceneDelegate.assistantConfig
    _homeTab = template
    return template
  }

  struct EntityImageRowContainer {
    let entity: AbstractLibraryEntity
    let item: HomeItem
    var homeRow: [CPListImageRowItemRowElement]
    var detailRow: [CPListImageRowItemRowElement]
  }

  var homeImageRows: [HomeSection: CPListImageRowItem] = [:]
  var homeRowData: [HomeSection: [HomeItem]] = [:]
  var homeArtworkUpdate: [String: EntityImageRowContainer] = [:] // String is Artwork.uniqueID

  private var _cachedTab: CPListTemplate?
  var cachedTab: CPListTemplate {
    if let template = _cachedTab { return template }
    let template = CPListTemplate(title: "Cached", sections: createCachedSections())
    template.tabImage = UIImage.cache
    _cachedTab = template
    return template
  }

  private var _sectionTemplates = [String: CPListTemplate]()

  private func sectionTemplate(title: String) -> CPListTemplate {
    if let template = _sectionTemplates[title] { return template }
    let template = CPListTemplate(title: title, sections: [
      CPListSection(items: [CPListTemplateItem]()),
    ])
    _sectionTemplates[title] = template
    return template
  }

  var accountSection: CPListTemplate {
    sectionTemplate(title: "Switch Account")
  }

  var podcastSection: CPListTemplate {
    sectionTemplate(title: "Podcasts")
  }

  var podcastCachedSection: CPListTemplate {
    sectionTemplate(title: "Cached Podcasts")
  }

  var genresSection: CPListTemplate {
    sectionTemplate(title: "Genres")
  }

  var genresCachedSection: CPListTemplate {
    sectionTemplate(title: "Cached Genres")
  }

  var artistsSection: CPListTemplate {
    sectionTemplate(title: "Artists")
  }

  var artistsCachedSection: CPListTemplate {
    sectionTemplate(title: "Cached Artists")
  }

  var artistsFavoriteSection: CPListTemplate {
    sectionTemplate(title: "Favorite Artists")
  }

  var artistsFavoriteCachedSection: CPListTemplate {
    sectionTemplate(title: "Favorite Cached Artists")
  }

  var albumsSection: CPListTemplate {
    sectionTemplate(title: "Albums")
  }

  var albumsCachedSection: CPListTemplate {
    sectionTemplate(title: "Cached Albums")
  }

  var albumsFavoriteSection: CPListTemplate {
    sectionTemplate(title: "Favorite Albums")
  }

  var albumsFavoriteCachedSection: CPListTemplate {
    sectionTemplate(title: "Favorite Cached Albums")
  }

  var albumsNewestSection: CPListTemplate {
    sectionTemplate(title: "Newest Albums")
  }

  var albumsNewestCachedSection: CPListTemplate {
    sectionTemplate(title: "Newest Cached Albums")
  }

  var albumsRecentSection: CPListTemplate {
    sectionTemplate(title: "Recently Played Albums")
  }

  var albumsRecentCachedSection: CPListTemplate {
    sectionTemplate(title: "Recently Played Cached Albums")
  }

  var songsFavoriteSection: CPListTemplate {
    sectionTemplate(title: "Favorite Songs")
  }

  var songsFavoriteCachedSection: CPListTemplate {
    sectionTemplate(title: "Favorite Cached Songs")
  }

  var radioSection: CPListTemplate {
    sectionTemplate(title: "Radios")
  }

  var playlistDetailSection: CPListTemplate?
  var podcastDetailSection: CPListTemplate?

  var playlistFetchController: PlaylistFetchedResultsController?
  var radiosFetchController: RadiosFetchedResultsController?
  var podcastFetchController: PodcastFetchedResultsController?
  var podcastCachedFetchController: PodcastFetchedResultsController?
  //
  var genresFetchController: GenreFetchedResultsController?
  var genresCachedFetchController: GenreFetchedResultsController?
  var artistsFetchController: ArtistFetchedResultsController?
  var artistsCachedFetchController: ArtistFetchedResultsController?
  var artistsFavoritesFetchController: ArtistFetchedResultsController?
  var artistsFavoritesCachedFetchController: ArtistFetchedResultsController?
  var albumsFetchController: AlbumFetchedResultsController?
  var albumsCachedFetchController: AlbumFetchedResultsController?
  var albumsFavoritesFetchController: AlbumFetchedResultsController?
  var albumsFavoritesCachedFetchController: AlbumFetchedResultsController?
  var albumsNewestFetchController: AlbumFetchedResultsController?
  var albumsNewestCachedFetchController: AlbumFetchedResultsController?
  var albumsRecentFetchController: AlbumFetchedResultsController?
  var albumsRecentCachedFetchController: AlbumFetchedResultsController?
  var songsFavoritesFetchController: SongsFetchedResultsController?
  var songsFavoritesCachedFetchController: SongsFetchedResultsController?
  //
  var playlistDetailFetchController: PlaylistItemsFetchedResultsController?
  var podcastDetailFetchController: PodcastEpisodesFetchedResultsController?

  private func resetFetchController() {
    playlistFetchController?.delegate = nil
    playlistFetchController = nil
    radiosFetchController?.delegate = nil
    radiosFetchController = nil
    podcastFetchController?.delegate = nil
    podcastFetchController = nil
    podcastCachedFetchController?.delegate = nil
    podcastCachedFetchController = nil
    //
    genresFetchController?.delegate = nil
    genresFetchController = nil
    genresCachedFetchController?.delegate = nil
    genresCachedFetchController = nil
    artistsFetchController?.delegate = nil
    artistsFetchController = nil
    artistsCachedFetchController?.delegate = nil
    artistsCachedFetchController = nil
    artistsFavoritesFetchController?.delegate = nil
    artistsFavoritesFetchController = nil
    artistsFavoritesCachedFetchController?.delegate = nil
    artistsFavoritesCachedFetchController = nil
    albumsFetchController?.delegate = nil
    albumsFetchController = nil
    albumsCachedFetchController?.delegate = nil
    albumsCachedFetchController = nil
    albumsFavoritesFetchController?.delegate = nil
    albumsFavoritesFetchController = nil
    albumsFavoritesCachedFetchController?.delegate = nil
    albumsFavoritesCachedFetchController = nil
    albumsNewestFetchController?.delegate = nil
    albumsNewestFetchController = nil
    albumsNewestCachedFetchController?.delegate = nil
    albumsNewestCachedFetchController = nil
    albumsRecentFetchController?.delegate = nil
    albumsRecentFetchController = nil
    albumsRecentCachedFetchController?.delegate = nil
    albumsRecentCachedFetchController = nil
    songsFavoritesFetchController?.delegate = nil
    songsFavoritesFetchController = nil
    songsFavoritesCachedFetchController?.delegate = nil
    songsFavoritesCachedFetchController = nil
    //
    playlistDetailFetchController?.delegate = nil
    playlistDetailFetchController = nil
    podcastDetailFetchController?.delegate = nil
    podcastDetailFetchController = nil
  }

  /// Drops every cached CarPlay template instance so templates are never
  /// re-pushed across `CPInterfaceController`s (known frozen/blank-UI pitfall
  /// on newer iOS). Templates are recreated lazily on next access.
  private func resetTemplates() {
    _playerQueueSection = nil
    _disconnectedTemplate = nil
    _rootBarTemplate = nil
    _playlistTab = nil
    _libraryTab = nil
    _homeTab = nil
    _cachedTab = nil
    _sectionTemplates = [:]
    playlistDetailSection = nil
    podcastDetailSection = nil
    homeImageRows = [:]
    homeRowData = [:]
    homeArtworkUpdate = [:]
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification)
    else { return }
    guard let templates = interfaceController?.templates else { return }

    // refresh Home image rows
    if let container = homeArtworkUpdate[downloadNotification.id] {
      var imageRowImages = container.homeRow
      imageRowImages.append(contentsOf: container.detailRow)
      let image = LibraryEntityImage.getImageToDisplayImmediately(
        libraryEntity: container.entity,
        themePreference: getPreference(activeAccountInfo).theme,
        artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
        useCache: false
      )
      for rowImage in imageRowImages {
        rowImage.image = image.carPlayImage(carTraitCollection: traits)
      }
    }

    // refresh Home Detail rows
    if templates.count == 2,
       let tabBarTemplate = templates.first as? CPTabBarTemplate,
       homeTab == tabBarTemplate.selectedTemplate,
       let listTemplate = templates.last as? CPListTemplate,
       listTemplate.sections.count == 1,
       let detailRow = listTemplate.sections.first?.items.first as? CPListImageRowItem,
       var container = homeArtworkUpdate[downloadNotification.id] {
      var newCreatedRowImages = [CPListImageRowItemRowElement]()
      for detailRowImage in container.detailRow {
        if let elementIndex = detailRow.elements.firstIndex(where: { $0 == detailRowImage }) {
          let image = LibraryEntityImage.getImageToDisplayImmediately(
            libraryEntity: container.entity,
            themePreference: getPreference(activeAccountInfo).theme,
            artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
            useCache: false
          )
          let newElement = CPListImageRowItemRowElement(
            image: image.carPlayImage(carTraitCollection: traits),
            title: container.item.playableContainable.name,
            subtitle: container.item.playableContainable.subtitle
          )
          detailRow.elements[elementIndex] = newElement
          newCreatedRowImages.append(newElement)
        }
      }
      container.detailRow = newCreatedRowImages
    }

    // refresh List items
    for template in templates {
      var sections: [CPListSection]?

      if let listTemplate = template as? CPListTemplate {
        sections = listTemplate.sections
      } else if let tabBarTemplate = template as? CPTabBarTemplate,
                let selectedTemplate = tabBarTemplate.selectedTemplate as? CPListTemplate {
        sections = selectedTemplate.sections
      }

      guard let sections = sections else { continue }
      for section in sections {
        for listTemplateItem in section.items {
          guard let item = listTemplateItem as? CPListItem,
                let userInfo = item.userInfo as? [String: Any]
          else { continue }

          var isThisRelatedToTheDownload = false
          var isTrackDisplayed = false
          var playable: AbstractPlayable?
          var entity: AbstractLibraryEntity?

          for info in userInfo {
            if info.key == CarPlayListUserInfoKeys.playableDownloadID.rawValue ||
              info.key == CarPlayListUserInfoKeys.artworkDownloadID.rawValue,
              let uniqueID = info.value as? String,
              uniqueID == downloadNotification.id {
              isThisRelatedToTheDownload = true
            } else if info.key == CarPlayListUserInfoKeys.artworkOwnerType.rawValue,
                      let ownerType = info.value as? ArtworkType,
                      let objectIdInfo = userInfo
                      .first(where: {
                        $0.key == CarPlayListUserInfoKeys.artworkOwnerObjectID.rawValue
                      }),
                      let managedObjectID = objectIdInfo.value as? NSManagedObjectID {
              switch ownerType {
              case .song:
                let mo = appDelegate.storage.main.context.object(with: managedObjectID) as? SongMO
                if let mo = mo {
                  playable = Song(managedObject: mo)
                }
              case .album:
                let mo = appDelegate.storage.main.context.object(with: managedObjectID) as? AlbumMO
                if let mo = mo {
                  entity = Album(managedObject: mo)
                }
              case .artist:
                let mo = appDelegate.storage.main.context.object(with: managedObjectID) as? ArtistMO
                if let mo = mo {
                  entity = Artist(managedObject: mo)
                }
              case .podcast:
                let mo = appDelegate.storage.main.context
                  .object(with: managedObjectID) as? PodcastMO
                if let mo = mo {
                  entity = Podcast(managedObject: mo)
                }
              case .podcastEpisode:
                let mo = appDelegate.storage.main.context
                  .object(with: managedObjectID) as? PodcastEpisodeMO
                if let mo = mo {
                  playable = PodcastEpisode(managedObject: mo)
                }
              case .radio:
                let mo = appDelegate.storage.main.context.object(with: managedObjectID) as? RadioMO
                if let mo = mo {
                  playable = Radio(managedObject: mo)
                }
              default: break
              }
            } else if info.key == CarPlayListUserInfoKeys.isTrackDisplayed.rawValue {
              isTrackDisplayed = (info.value as? Bool) ?? false
            }
          }

          if isThisRelatedToTheDownload {
            if let playable = playable {
              item.setImage(getImage(for: playable, isTrackDisplayed: isTrackDisplayed))
            } else if let entity = entity {
              item.setImage(
                LibraryEntityImage.getImageToDisplayImmediately(
                  libraryEntity: entity,
                  themePreference: getPreference(activeAccountInfo).theme,
                  artworkDisplayPreference: getPreference(activeAccountInfo)
                    .artworkDisplayPreference,
                  useCache: false
                ).carPlayImage(carTraitCollection: traits)
              )
            }
          }
        }
      }
    }
  }

  @objc
  private func refreshSort() {
    guard let templates = interfaceController?.templates else { return }

    if let root = interfaceController?.rootTemplate as? CPTabBarTemplate,
       root.selectedTemplate == playlistTab,
       playlistFetchController?.sortType != appDelegate.storage.settings.user.playlistsSortSetting {
      os_log("CarPlay: RefreshSort: PlaylistFetchController", log: self.log, type: .info)
      createPlaylistFetchController()
      playlistTab.updateSections(createPlaylistsSections())
    }
    if artistsFavoritesFetchController?.sortType != appDelegate.storage.settings.user
      .artistsSortSetting {
      os_log("CarPlay: RefreshSort: ArtistsFavoritesFetchController", log: self.log, type: .info)
      createArtistsFavoritesFetchController()
      artistsFavoriteSection.updateSections(createArtistItems(
        from: artistsFavoritesFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if artistsFavoritesCachedFetchController?.sortType != appDelegate.storage.settings.user
      .artistsSortSetting {
      os_log(
        "CarPlay: RefreshSort: ArtistsFavoritesCachedFetchController",
        log: self.log,
        type: .info
      )
      createArtistsFavoritesCachedFetchController()
      artistsFavoriteCachedSection.updateSections(createArtistItems(
        from: artistsFavoritesCachedFetchController,
        onlyCached: true
      ))
    }
    if templates.contains(albumsFavoriteSection),
       albumsFavoritesFetchController?.sortType != appDelegate.storage.settings.user
       .albumsSortSetting {
      os_log("CarPlay: RefreshSort: AlbumsFavoritesFetchController", log: self.log, type: .info)
      createAlbumsFavoritesFetchController()
      albumsFavoriteSection.updateSections(createAlbumItems(
        from: albumsFavoritesFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(albumsFavoriteCachedSection),
       albumsFavoritesCachedFetchController?.sortType != appDelegate.storage.settings.user
       .albumsSortSetting {
      os_log(
        "CarPlay: RefreshSort: AlbumsFavoritesCachedFetchController",
        log: self.log,
        type: .info
      )
      createAlbumsFavoritesCachedFetchController()
      albumsFavoriteCachedSection.updateSections(createAlbumItems(
        from: albumsFavoritesCachedFetchController,
        onlyCached: true
      ))
    }
    if templates.contains(songsFavoriteSection),
       (activeAccount.apiType.asServerApiType != .ampache) ?
       (
         songsFavoritesFetchController?.sortType != appDelegate.storage.settings.user
           .favoriteSongSortSetting
       ) :
       (
         songsFavoritesFetchController?.sortType != appDelegate.storage.settings.user
           .songsSortSetting
       ) {
      os_log("CarPlay: RefreshSort: SongsFavoritesFetchController", log: self.log, type: .info)
      createSongsFavoritesFetchController()
      songsFavoriteSection
        .updateSections(
          [CPListSection(items: createSongItems(from: songsFavoritesFetchController))]
        )
    }
    if templates.contains(songsFavoriteCachedSection),
       (activeAccount.apiType.asServerApiType != .ampache) ?
       (
         songsFavoritesCachedFetchController?.sortType != appDelegate.storage.settings.user
           .favoriteSongSortSetting
       ) :
       (
         songsFavoritesCachedFetchController?.sortType != appDelegate.storage.settings.user
           .songsSortSetting
       ) {
      os_log(
        "CarPlay: RefreshSort: SongsFavoritesCachedFetchController",
        log: self.log,
        type: .info
      )
      createSongsFavoritesCachedFetchController()
      songsFavoriteCachedSection
        .updateSections(
          [CPListSection(items: createSongItems(from: songsFavoritesCachedFetchController))]
        )
    }
  }

  @objc
  private func refreshOfflineMode() {
    os_log("CarPlay: OfflineModeChanged", log: self.log, type: .info)
    guard let templates = interfaceController?.templates else { return }

    sharedHome?.createFetchController()

    if let root = interfaceController?.rootTemplate as? CPTabBarTemplate,
       root.selectedTemplate == homeTab {
      os_log("CarPlay: OfflineModeChanged: HomeSections", log: self.log, type: .info)
      updateHomeSections()
    }
    if let root = interfaceController?.rootTemplate as? CPTabBarTemplate,
       root.selectedTemplate == playlistTab {
      os_log("CarPlay: OfflineModeChanged: playlistFetchController", log: self.log, type: .info)
      createPlaylistFetchController()
      playlistTab.updateSections(createPlaylistsSections())
    }
    if templates.contains(podcastSection) {
      os_log("CarPlay: OfflineModeChanged: podcastFetchController", log: self.log, type: .info)
      createPodcastFetchController()
      podcastSection.updateSections(createPodcastsSections(
        from: podcastFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(genresSection) {
      os_log(
        "CarPlay: OfflineModeChanged: genresFetchController",
        log: self.log,
        type: .info
      )
      createGenresFetchController()
      genresSection.updateSections(createGenreSections(
        from: genresFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(artistsSection) {
      os_log(
        "CarPlay: OfflineModeChanged: artistsFetchController",
        log: self.log,
        type: .info
      )
      createArtistsFetchController()
      artistsSection.updateSections(createArtistItems(
        from: artistsFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(artistsFavoriteSection) {
      os_log(
        "CarPlay: OfflineModeChanged: artistsFavoritesFetchController",
        log: self.log,
        type: .info
      )
      createArtistsFavoritesFetchController()
      artistsFavoriteSection.updateSections(createArtistItems(
        from: artistsFavoritesFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(albumsSection) {
      os_log(
        "CarPlay: OfflineModeChanged: albumsFetchController",
        log: self.log,
        type: .info
      )
      createAlbumsFetchController()
      albumsSection.updateSections(createAlbumItems(
        from: albumsFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(albumsFavoriteSection) {
      os_log(
        "CarPlay: OfflineModeChanged: albumsFavoritesFetchController",
        log: self.log,
        type: .info
      )
      createAlbumsFavoritesFetchController()
      albumsFavoriteSection.updateSections(createAlbumItems(
        from: albumsFavoritesFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(albumsNewestSection) {
      os_log("CarPlay: OfflineModeChanged: albumsNewestFetchController", log: self.log, type: .info)
      createAlbumsNewestFetchController()
      albumsNewestSection.updateSections(createAlbumItems(
        from: albumsNewestFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(albumsRecentSection) {
      os_log("CarPlay: OfflineModeChanged: albumsRecentFetchController", log: self.log, type: .info)
      createAlbumsRecentFetchController()
      albumsRecentSection.updateSections(createAlbumItems(
        from: albumsRecentFetchController,
        onlyCached: isOfflineMode
      ))
    }
    if templates.contains(songsFavoriteSection) {
      os_log(
        "CarPlay: OfflineModeChanged: songsFavoritesFetchController",
        log: self.log,
        type: .info
      )
      createSongsFavoritesFetchController()
      songsFavoriteSection
        .updateSections(
          [CPListSection(items: createSongItems(from: songsFavoritesFetchController))]
        )
    }
    if let playlistDetailSection = playlistDetailSection, templates.contains(playlistDetailSection),
       let playlistDetailFetchController = playlistDetailFetchController {
      os_log("CarPlay: OfflineModeChanged: playlistDetailSection", log: self.log, type: .info)
      playlistDetailFetchController.search(onlyCachedSongs: isOfflineMode)
      playlistDetailSection
        .updateSections(
          [CPListSection(items: createPlaylistDetailItems(from: playlistDetailFetchController))]
        )
    }
    if let podcastDetailSection = podcastDetailSection, templates.contains(podcastDetailSection),
       let podcastDetailFetchController = podcastDetailFetchController {
      os_log("CarPlay: OfflineModeChanged: podcastDetailSection", log: self.log, type: .info)
      podcastDetailFetchController.search(searchText: "", onlyCachedSongs: isOfflineMode)
      podcastDetailSection
        .updateSections(
          [CPListSection(items: createPodcastDetailItems(from: podcastDetailFetchController))]
        )
    }
  }
}

extension CarPlaySceneDelegate: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controller is created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      guard let templates = self.interfaceController?.templates else { return }
      if let root = self.interfaceController?.rootTemplate as? CPTabBarTemplate,
         root.selectedTemplate == playlistTab,
         let playlistFetchController = playlistFetchController,
         controller == playlistFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: playlistFetchController", log: self.log, type: .info)
        playlistTab.updateSections(createPlaylistsSections())
      }
      if templates.contains(podcastSection), let podcastFetchController = podcastFetchController,
         controller == podcastFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: podcastFetchController", log: self.log, type: .info)
        podcastSection.updateSections(createPodcastsSections(
          from: podcastFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(podcastCachedSection),
         let podcastCachedFetchController = podcastCachedFetchController,
         controller == podcastCachedFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: podcastCachedFetchController", log: self.log, type: .info)
        podcastCachedSection.updateSections(createPodcastsSections(
          from: podcastCachedFetchController,
          onlyCached: true
        ))
      }

      if templates.contains(radioSection), let radiosFetchController = radiosFetchController,
         controller == radiosFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: radiosFetchController", log: self.log, type: .info)
        radioSection
          .updateSections(createRadioSections(from: radiosFetchController))
      }
      if templates.contains(genresSection),
         let genresFetchController = genresFetchController,
         controller == genresFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: genresFetchController",
          log: self.log,
          type: .info
        )
        genresSection.updateSections(createGenreSections(
          from: genresFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(genresCachedSection),
         let genresCachedFetchController = genresCachedFetchController,
         controller == genresCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: genresCachedFetchController",
          log: self.log,
          type: .info
        )
        genresCachedSection.updateSections(createGenreSections(
          from: genresCachedFetchController,
          onlyCached: true
        ))
      }
      if templates.contains(artistsSection),
         let artistsFetchController = artistsFetchController,
         controller == artistsFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: artistsFetchController",
          log: self.log,
          type: .info
        )
        artistsSection.updateSections(createArtistItems(
          from: artistsFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(artistsCachedSection),
         let artistsCachedFetchController = artistsCachedFetchController,
         controller == artistsCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: artistsCachedFetchController",
          log: self.log,
          type: .info
        )
        artistsCachedSection.updateSections(createArtistItems(
          from: artistsCachedFetchController,
          onlyCached: true
        ))
      }
      if templates.contains(artistsFavoriteSection),
         let artistsFavoritesFetchController = artistsFavoritesFetchController,
         controller == artistsFavoritesFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: artistsFavoritesFetchController",
          log: self.log,
          type: .info
        )
        artistsFavoriteSection.updateSections(createArtistItems(
          from: artistsFavoritesFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(artistsFavoriteCachedSection),
         let artistsFavoritesCachedFetchController = artistsFavoritesCachedFetchController,
         controller == artistsFavoritesCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: artistsFavoritesCachedFetchController",
          log: self.log,
          type: .info
        )
        artistsFavoriteCachedSection.updateSections(createArtistItems(
          from: artistsFavoritesCachedFetchController,
          onlyCached: true
        ))
      }
      if templates.contains(albumsSection),
         let albumsFetchController = albumsFetchController,
         controller == albumsFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: albumsFetchController",
          log: self.log,
          type: .info
        )
        albumsSection.updateSections(createAlbumItems(
          from: albumsFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(albumsCachedSection),
         let albumsCachedFetchController = albumsCachedFetchController,
         controller == albumsCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: albumsCachedFetchController",
          log: self.log,
          type: .info
        )
        albumsCachedSection.updateSections(createAlbumItems(
          from: albumsCachedFetchController,
          onlyCached: true
        ))
      }
      if templates.contains(albumsFavoriteSection),
         let albumsFavoritesFetchController = albumsFavoritesFetchController,
         controller == albumsFavoritesFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: albumsFavoritesFetchController",
          log: self.log,
          type: .info
        )
        albumsFavoriteSection.updateSections(createAlbumItems(
          from: albumsFavoritesFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(albumsFavoriteCachedSection),
         let albumsFavoritesCachedFetchController = albumsFavoritesCachedFetchController,
         controller == albumsFavoritesCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: albumsFavoritesCachedFetchController",
          log: self.log,
          type: .info
        )
        albumsFavoriteCachedSection.updateSections(createAlbumItems(
          from: albumsFavoritesCachedFetchController,
          onlyCached: true
        ))
      }
      if templates.contains(albumsNewestSection),
         let albumsNewestFetchController = albumsNewestFetchController,
         controller == albumsNewestFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: albumsNewestFetchController", log: self.log, type: .info)
        albumsNewestSection.updateSections(createAlbumItems(
          from: albumsNewestFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(albumsNewestCachedSection),
         let albumsNewestCachedFetchController = albumsNewestCachedFetchController,
         controller == albumsNewestCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: albumsNewestCachedFetchController",
          log: self.log,
          type: .info
        )
        albumsNewestCachedSection.updateSections(createAlbumItems(
          from: albumsNewestCachedFetchController,
          onlyCached: true
        ))
      }
      if templates.contains(albumsRecentSection),
         let albumsRecentFetchController = albumsRecentFetchController,
         controller == albumsRecentFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: albumsRecentFetchController", log: self.log, type: .info)
        albumsRecentSection.updateSections(createAlbumItems(
          from: albumsRecentFetchController,
          onlyCached: isOfflineMode
        ))
      }
      if templates.contains(albumsRecentCachedSection),
         let albumsRecentCachedFetchController = albumsRecentCachedFetchController,
         controller == albumsRecentCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: albumsRecentCachedFetchController",
          log: self.log,
          type: .info
        )
        albumsRecentCachedSection.updateSections(createAlbumItems(
          from: albumsRecentCachedFetchController,
          onlyCached: true
        ))
      }
      if templates.contains(songsFavoriteSection),
         let songsFavoritesFetchController = songsFavoritesFetchController,
         controller == songsFavoritesFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: songsFavoritesFetchController", log: self.log, type: .info)
        songsFavoriteSection
          .updateSections(
            [CPListSection(items: createSongItems(from: songsFavoritesFetchController))]
          )
      }
      if templates.contains(songsFavoriteCachedSection),
         let songsFavoritesCachedFetchController = songsFavoritesCachedFetchController,
         controller == songsFavoritesCachedFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: songsFavoritesCachedFetchController",
          log: self.log,
          type: .info
        )
        songsFavoriteCachedSection
          .updateSections(
            [CPListSection(items: createSongItems(from: songsFavoritesCachedFetchController))]
          )
      }
      if let playlistDetailSection = playlistDetailSection,
         templates.contains(playlistDetailSection),
         let playlistDetailFetchController = playlistDetailFetchController,
         controller == playlistDetailFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: playlistDetailSection", log: self.log, type: .info)
        playlistDetailSection
          .updateSections(
            [CPListSection(items: createPlaylistDetailItems(from: playlistDetailFetchController))]
          )
      }
      if let podcastDetailSection = podcastDetailSection, templates.contains(podcastDetailSection),
         let podcastDetailFetchController = podcastDetailFetchController,
         controller == podcastDetailFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: podcastDetailSection", log: self.log, type: .info)
        podcastDetailSection
          .updateSections(
            [CPListSection(items: createPodcastDetailItems(from: podcastDetailFetchController))]
          )
      }
    }
  }
}

// MARK: CPInterfaceControllerDelegate

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
  nonisolated func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
    Task { @MainActor in
      if aTemplate == playerQueueSection {
        os_log("CarPlay: templateWillAppear playerQueueSection", log: self.log, type: .info)
        playerQueueSection.updateSections(createPlayerQueueSections())
      } else if aTemplate == homeTab {
        os_log("CarPlay: templateWillAppear: homeTab", log: self.log, type: .info)
        self.updateHomeSections()
      } else if aTemplate == libraryTab {
        os_log("CarPlay: templateWillAppear libraryTab", log: self.log, type: .info)
        libraryTab.updateSections(createLibrarySections())
      } else if aTemplate == cachedTab {
        os_log("CarPlay: templateWillAppear cachedTab", log: self.log, type: .info)
        cachedTab.updateSections(createCachedSections())
      } else if aTemplate == playlistTab {
        os_log("CarPlay: templateWillAppear playlistTab", log: self.log, type: .info)
        Task { @MainActor in do {
          try await self.appDelegate.getMeta(activeAccountInfo).librarySyncer
            .syncDownPlaylistsWithoutSongs()
        } catch {
          self.appDelegate.eventLogger.report(topic: "CarPlay: Playlists Sync", error: error)
        }}
        if playlistFetchController == nil { createPlaylistFetchController() }
        playlistTab.updateSections(createPlaylistsSections())
      } else if aTemplate == podcastSection {
        os_log("CarPlay: templateWillAppear podcastSection", log: self.log, type: .info)
        if podcastFetchController == nil { createPodcastFetchController() }
        podcastSection.updateSections(createPodcastsSections(
          from: podcastFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == podcastCachedSection {
        os_log("CarPlay: templateWillAppear podcastCachedSection", log: self.log, type: .info)
        if podcastCachedFetchController == nil { createPodcastCachedFetchController() }
        podcastCachedSection.updateSections(createPodcastsSections(
          from: podcastCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == accountSection {
        os_log("CarPlay: templateWillAppear accountSection", log: self.log, type: .info)
        accountSection.updateSections(createAccountsSections())
      } else if aTemplate == radioSection {
        os_log("CarPlay: templateWillAppear radioSection", log: self.log, type: .info)
        if radiosFetchController == nil { createRadiosFetchController() }
        radioSection
          .updateSections(createRadioSections(from: radiosFetchController))
      } else if aTemplate == artistsFavoriteSection {
        os_log("CarPlay: templateWillAppear artistsFavoriteSection", log: self.log, type: .info)
        if artistsFavoritesFetchController == nil { createArtistsFavoritesFetchController() }
        artistsFavoriteSection.updateSections(createArtistItems(
          from: artistsFavoritesFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == genresSection {
        os_log(
          "CarPlay: templateWillAppear genresSection",
          log: self.log,
          type: .info
        )
        if genresFetchController ==
          nil { createGenresFetchController() }
        genresSection.updateSections(createGenreSections(
          from: genresFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == genresCachedSection {
        os_log(
          "CarPlay: templateWillAppear genresCachedSection",
          log: self.log,
          type: .info
        )
        if genresCachedFetchController ==
          nil { createGenresCachedFetchController() }
        genresCachedSection.updateSections(createGenreSections(
          from: genresCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == artistsSection {
        os_log(
          "CarPlay: templateWillAppear artistsSection",
          log: self.log,
          type: .info
        )
        if artistsFetchController ==
          nil { createArtistsFetchController() }
        artistsSection.updateSections(createArtistItems(
          from: artistsFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == artistsCachedSection {
        os_log(
          "CarPlay: templateWillAppear artistsCachedSection",
          log: self.log,
          type: .info
        )
        if artistsCachedFetchController ==
          nil { createArtistsCachedFetchController() }
        artistsCachedSection.updateSections(createArtistItems(
          from: artistsCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == artistsFavoriteCachedSection {
        os_log(
          "CarPlay: templateWillAppear artistsFavoriteCachedSection",
          log: self.log,
          type: .info
        )
        if artistsFavoritesCachedFetchController ==
          nil { createArtistsFavoritesCachedFetchController() }
        artistsFavoriteCachedSection.updateSections(createArtistItems(
          from: artistsFavoritesCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == albumsSection {
        os_log("CarPlay: templateWillAppear albumsSection", log: self.log, type: .info)
        if albumsFetchController == nil { createAlbumsFetchController() }
        albumsSection.updateSections(createAlbumItems(
          from: albumsFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == albumsCachedSection {
        os_log("CarPlay: templateWillAppear albumsCachedSection", log: self.log, type: .info)
        if albumsCachedFetchController == nil { createAlbumsCachedFetchController() }
        albumsCachedSection.updateSections(createAlbumItems(
          from: albumsCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == albumsFavoriteSection {
        os_log("CarPlay: templateWillAppear albumsFavoriteSection", log: self.log, type: .info)
        if albumsFavoritesFetchController == nil { createAlbumsFavoritesFetchController() }
        albumsFavoriteSection.updateSections(createAlbumItems(
          from: albumsFavoritesFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == albumsFavoriteCachedSection {
        os_log(
          "CarPlay: templateWillAppear albumsFavoriteCachedSection",
          log: self.log,
          type: .info
        )
        if albumsFavoritesCachedFetchController ==
          nil { createAlbumsFavoritesCachedFetchController() }
        albumsFavoriteCachedSection.updateSections(createAlbumItems(
          from: albumsFavoritesCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == albumsNewestSection {
        os_log("CarPlay: templateWillAppear albumsNewestSection", log: self.log, type: .info)
        if albumsNewestFetchController == nil { createAlbumsNewestFetchController() }
        albumsNewestSection.updateSections(createAlbumItems(
          from: albumsNewestFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == albumsNewestCachedSection {
        os_log("CarPlay: templateWillAppear albumsNewestCachedSection", log: self.log, type: .info)
        if albumsNewestCachedFetchController == nil { createAlbumsNewestCachedFetchController() }
        albumsNewestCachedSection.updateSections(createAlbumItems(
          from: albumsNewestCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == albumsRecentSection {
        os_log("CarPlay: templateWillAppear albumsRecentSection", log: self.log, type: .info)
        Task { @MainActor in do {
          try await self.appDelegate.getMeta(activeAccountInfo).librarySyncer
            .syncRecentAlbums(
              offset: 0,
              count: AmperKit.newestElementsFetchCount
            )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Recent Albums Sync", error: error)
        }}
        if albumsRecentFetchController == nil { createAlbumsRecentFetchController() }
        albumsRecentSection.updateSections(createAlbumItems(
          from: albumsRecentFetchController,
          onlyCached: isOfflineMode
        ))
      } else if aTemplate == albumsRecentCachedSection {
        os_log("CarPlay: templateWillAppear albumsRecentCachedSection", log: self.log, type: .info)
        if albumsRecentCachedFetchController == nil { createAlbumsRecentCachedFetchController() }
        albumsRecentCachedSection.updateSections(createAlbumItems(
          from: albumsRecentCachedFetchController,
          onlyCached: true
        ))
      } else if aTemplate == songsFavoriteSection {
        os_log("CarPlay: templateWillAppear songsFavoriteSection", log: self.log, type: .info)
        if songsFavoritesFetchController == nil { createSongsFavoritesFetchController() }
        songsFavoriteSection
          .updateSections(
            [CPListSection(items: createSongItems(from: songsFavoritesFetchController))]
          )
      } else if aTemplate == songsFavoriteCachedSection {
        os_log("CarPlay: templateWillAppear songsFavoriteCachedSection", log: self.log, type: .info)
        if songsFavoritesCachedFetchController ==
          nil { createSongsFavoritesCachedFetchController() }
        songsFavoriteCachedSection
          .updateSections(
            [CPListSection(items: createSongItems(from: songsFavoritesCachedFetchController))]
          )
      } else if aTemplate == playlistDetailSection,
                let playlistDetailFetchController = playlistDetailFetchController {
        os_log("CarPlay: templateWillAppear playlistDetailSection", log: self.log, type: .info)
        Task { @MainActor in do {
          try await playlistDetailFetchController.playlist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.activeAccountInfo).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.activeAccountInfo)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
        }}
        playlistDetailSection?
          .updateSections(
            [CPListSection(items: createPlaylistDetailItems(from: playlistDetailFetchController))]
          )
      } else if aTemplate == podcastDetailSection,
                let podcastDetailFetchController = podcastDetailFetchController {
        os_log("CarPlay: templateWillAppear podcastDetailSection", log: self.log, type: .info)
        Task { @MainActor in do {
          try await podcastDetailFetchController.podcast.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.activeAccountInfo).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.activeAccountInfo)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Podcast Sync", error: error)
        }}
        podcastDetailSection?
          .updateSections(
            [CPListSection(items: createPodcastDetailItems(from: podcastDetailFetchController))]
          )
      }
    }
  }

  nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {}
  nonisolated func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {}

  nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
    Task { @MainActor in
      if aTemplate == playlistDetailSection {
        os_log("CarPlay: templateDidDisappear playlistDetailSection", log: self.log, type: .info)
        playlistDetailFetchController = nil
        playlistDetailSection = nil
      } else if aTemplate == podcastDetailSection {
        os_log("CarPlay: templateDidDisappear podcastDetailSection", log: self.log, type: .info)
        podcastDetailFetchController = nil
        podcastDetailSection = nil
      }
    }
  }
}
