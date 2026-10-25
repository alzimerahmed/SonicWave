//
//  MixesVC.swift
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
import OSLog
import UIKit

// MARK: - MixesVC

/// G7: the mixes discovery hub. Cards come from
/// `MixProvider.availableMixes()` — kinds that cannot resolve for this
/// account (no favorites, no decade/genre coverage, offline server mix)
/// simply never appear as cards. Tapping resolves async (`resolve(mix:)`)
/// and pushes the shared `PlayableListVC` — no bespoke list machinery.
final class MixesVC: UICollectionViewController {
  override var sceneTitle: String? {
    NSLocalizedString("Mixes", comment: "Title of the mixes discovery screen")
  }

  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "MixesVC")
  private let account: Account
  private var mixes = [Mix]()
  private var resolveTask: Task<Void, Never>?

  private var mixProvider: MixProvider {
    appDelegate.getMeta(account.info).mixProvider
  }

  init(account: Account) {
    self.account = account
    super.init(collectionViewLayout: MixesVC.createLayout())
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    resolveTask?.cancel()
  }

  private static func createLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { _, layoutEnvironment in
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .fractionalHeight(1.0)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)

      // ~170pt target card width — same silhouette as the Home shelves,
      // wrapping to however many columns the container allows
      let containerWidth = layoutEnvironment.container.effectiveContentSize.width
      let columnCount = max(2, Int(containerWidth / 170.0))
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(230)
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
      DiscoveryShelfCell.self,
      forCellWithReuseIdentifier: DiscoveryShelfCell.reuseID
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: .refresh,
      style: .plain,
      target: self,
      action: #selector(refreshMixes)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = NSLocalizedString(
      "Refresh Mixes",
      comment: "VoiceOver label for the mixes refresh button"
    )
    registerOfflineModeIndicator()
    reloadMixes()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  @objc
  private func refreshMixes() {
    reloadMixes()
  }

  private func reloadMixes() {
    mixes = mixProvider.availableMixes()
    collectionView.reloadData()
    updateContentUnavailable()
  }

  private func updateContentUnavailable() {
    if mixes.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = .musicalNotes
      config.text = NSLocalizedString(
        "No Mixes Available",
        comment: "Empty state title on the mixes screen"
      )
      config.secondaryText = NSLocalizedString(
        "Mixes appear once your library has enough songs, favorites and play history.",
        comment: "Empty state subtitle on the mixes screen"
      )
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  private func artworkType(for kind: MixKind) -> ArtworkType {
    switch kind {
    case .favoritesRadio: return .song
    case .decadeMix: return .album
    case .genreBlend: return .genre
    case .deepCuts: return .artist
    case .timeOfDay: return .radio
    }
  }

  // MARK: - UICollectionViewDataSource

  override func collectionView(
    _ collectionView: UICollectionView,
    numberOfItemsInSection section: Int
  )
    -> Int {
    mixes.count
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  )
    -> UICollectionViewCell {
    guard let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: DiscoveryShelfCell.reuseID,
      for: indexPath
    ) as? DiscoveryShelfCell else { return UICollectionViewCell() }
    guard let mix = mixes.element(at: indexPath.item) else { return cell }
    cell.display(artworkType: artworkType(for: mix.kind), title: mix.title, subtitle: mix.subtitle)
    return cell
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard let mix = mixes.element(at: indexPath.item) else { return }
    collectionView.deselectItem(at: indexPath, animated: true)
    let cell = collectionView.cellForItem(at: indexPath) as? DiscoveryShelfCell
    cell?.isLoading = true
    resolveTask?.cancel()
    resolveTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.collectionView.indexPathsForVisibleItems
          .compactMap { self.collectionView.cellForItem(at: $0) as? DiscoveryShelfCell }
          .forEach { $0.isLoading = false }
      }
      do {
        // an empty resolution means the mix cannot be built right now —
        // that is an empty state, never an error (per kit contract)
        let songs = try await self.mixProvider.resolve(
          mix: mix,
          count: MixProvider.defaultSongCount
        )
        if songs.isEmpty {
          self.appDelegate.eventLogger.info(
            topic: "Mixes",
            message: NSLocalizedString(
              "This mix has no songs right now.",
              comment: "Toast when a mix resolves to an empty song list"
            ),
            displayPopup: true
          )
          return
        }
        self.navigationController?.pushViewController(
          PlayableListVC(
            account: self.account,
            title: mix.title,
            playables: songs
          ),
          animated: true
        )
      } catch {
        os_log("Mix resolve failed: %{public}@", log: self.log, type: .error,
               error.localizedDescription)
        self.appDelegate.eventLogger.report(topic: "Mixes", error: error)
      }
    }
  }
}
