//
//  DecadeAlbumsVC.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 28.02.26.
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

import SonicWaveKit
import UIKit

// MARK: - DecadeAlbumsVC

/// G20: decade browse via `getAlbums(fromYear:toYear:)` (Subsonic
/// `getAlbumList2 type=byYear`). Server entries resolve to local
/// `Album`s (`getAlbum(for:id:)`) — unsynced catalog entries are
/// display-only in the API contract and skipped here rather than
/// shown as dead cards. `.notSupported` hides the entry point
/// upstream (menu is Subsonic-gated); an empty fetch is an empty state.
final class DecadeAlbumsVC: UICollectionViewController {
  override var sceneTitle: String? {
    String(
      format: NSLocalizedString(
        "%lds Albums",
        comment: "Title of the decade album browse screen (e.g. \"1980s Albums\")"
      ),
      selectedDecade
    )
  }

  private let account: Account
  private var albums = [Album]()
  private var selectedDecade: Int
  private var loadTask: Task<Void, Never>?
  private let decades: [Int]

  private static let itemWidth: CGFloat = 160.0

  init(account: Account, initialDecade: Int? = nil) {
    self.account = account
    let currentYear = Calendar.current.component(.year, from: Date())
    var list = [Int]()
    var decade = 1950
    while decade <= currentYear {
      list.append(decade)
      decade += 10
    }
    decades = list
    let defaultDecade = ((initialDecade ?? currentYear - 30) / 10) * 10
    selectedDecade = decades.contains(defaultDecade) ? defaultDecade : (decades.last ?? 2020)
    super.init(collectionViewLayout: DecadeAlbumsVC.createLayout())
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func createLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { _, layoutEnvironment in
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .fractionalHeight(1.0)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)
      let columnCount = max(
        2,
        Int(layoutEnvironment.container.effectiveContentSize.width / 170.0)
      )
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(210)
      )
      let group = NSCollectionLayoutGroup.horizontal(
        layoutSize: groupSize,
        subitem: item,
        count: columnCount
      )
      group.interItemSpacing = .fixed(12)
      let section = NSCollectionLayoutSection(group: group)
      section.interGroupSpacing = 12
      section.contentInsets = NSDirectionalEdgeInsets(
        top: 16,
        leading: 16,
        bottom: 24,
        trailing: 16
      )
      return section
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setNavBarTitle(title: sceneTitle ?? "")
    collectionView.backgroundColor = .sonicSystemBackground
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: NSLocalizedString("Decade", comment: "Decade picker button title"),
      menu: createDecadeMenu()
    )
    registerOfflineModeIndicator()
    loadAlbums()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  deinit {
    loadTask?.cancel()
  }

  private func createDecadeMenu() -> UIMenu {
    let actions = decades.reversed().map { decade in
      UIAction(
        title: String(
          format: NSLocalizedString("%lds", comment: "Decade label (e.g. \"1980s\")"),
          decade
        ),
        state: decade == self.selectedDecade ? .on : .off
      ) { _ in
        self.selectedDecade = decade
        self.setNavBarTitle(title: self.sceneTitle ?? "")
        self.navigationItem.rightBarButtonItem?.menu = self.createDecadeMenu()
        self.loadAlbums()
      }
    }
    return UIMenu(
      title: NSLocalizedString("Decade", comment: "Decade picker menu title"),
      children: actions
    )
  }

  private func loadAlbums() {
    guard appDelegate.storage.settings.user.isOnlineMode else {
      albums = []
      collectionView.reloadData()
      updateContentUnavailable()
      return
    }
    loadTask?.cancel()
    loadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await self.appDelegate.getMeta(self.account.info).backendApi
          .getAlbums(
            fromYear: self.selectedDecade,
            toYear: self.selectedDecade + 9,
            offset: 0,
            count: 100
          )
        switch result {
        case .supported(let remoteAlbums):
          self.albums = remoteAlbums.compactMap {
            self.appDelegate.storage.main.library.getAlbum(
              for: self.account,
              id: $0.id,
              isDetailFaultResolution: false
            )
          }
        case .notSupported:
          self.albums = []
        }
      } catch {
        self.appDelegate.eventLogger.report(topic: "Decade Albums", error: error)
        return
      }
      guard !Task.isCancelled else { return }
      self.collectionView.reloadData()
      self.updateContentUnavailable()
    }
  }

  private func updateContentUnavailable() {
    if albums.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = .album
      config.text = String(
        format: NSLocalizedString(
          "No Albums in the %lds",
          comment: "Empty state title for decade browse"
        ),
        selectedDecade
      )
      config.secondaryText = NSLocalizedString(
        "Albums appear here once they are synced to your library.",
        comment: "Empty state subtitle for decade browse"
      )
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    numberOfItemsInSection section: Int
  )
    -> Int {
    albums.count
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  )
    -> UICollectionViewCell {
    guard let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: AlbumCollectionCell.typeName,
      for: indexPath
    ) as? AlbumCollectionCell else { return UICollectionViewCell() }
    guard let album = albums.element(at: indexPath.item) else { return cell }
    cell.display(
      container: album,
      rootView: self,
      itemWidth: Self.itemWidth,
      initialIndexPath: indexPath
    )
    return cell
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard let album = albums.element(at: indexPath.item) else { return }
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
      animated: true
    )
  }
}
