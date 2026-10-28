//
//  PlayableListVC.swift
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

// MARK: - PlayableListVC

/// Phase-8 (G7/G8/G20): a plain song list for playables resolved
/// outside a fetched-results controller — mixes, smart-playlist
/// evaluations, server top-songs. Same row machinery as `SongsVC`
/// (`PlayableTableCell`, swipe/context actions, Play/Shuffle header,
/// offline indicator) minus the CoreData binding.
class PlayableListVC: BasicTableViewController {
  let account: Account
  override var sceneTitle: String? { listTitle }

  private var playables: [AbstractPlayable]
  private let listTitle: String
  private let emptyTitle: String
  private let emptySubtitle: String
  private var detailHeaderView: LibraryElementDetailTableHeaderView?

  init(
    account: Account,
    title: String,
    playables: [AbstractPlayable],
    emptyTitle: String? = nil,
    emptySubtitle: String? = nil
  ) {
    self.account = account
    self.playables = playables
    self.listTitle = title
    self.emptyTitle = emptyTitle ?? NSLocalizedString(
      "No Songs",
      comment: "Empty state title for a resolved song list (mix, smart playlist)"
    )
    self.emptySubtitle = emptySubtitle ?? NSLocalizedString(
      "Nothing could be resolved here right now.",
      comment: "Empty state subtitle for a resolved song list"
    )
    super.init(style: .grouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.backgroundColor = .backgroundColor
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    setNavBarTitle(title: listTitle)

    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        String(
          format: NSLocalizedString(
            "%lld Songs",
            comment: "Song count label on the resolved-list header (play/shuffle row)"
          ),
          self.playables.count
        )
      },
      playContextCb: { PlayContext(name: self.listTitle, playables: self.playables) },
      player: appDelegate.player,
      isInfoAlwaysHidden: false,
      shuffleContextCb: {
        PlayContext(
          name: self.listTitle,
          playables: self.playables.count > self.appDelegate.player.maxSongsToAddOnce
            ? self.playables[randomPick: self.appDelegate.player.maxSongsToAddOnce]
            : self.playables
        )
      }
    )
    detailHeaderView = LibraryElementDetailTableHeaderView.createTableHeader(
      rootView: self,
      configuration: playShuffleInfoConfig
    )

    containableAtIndexPathCallback = { indexPath in
      self.playables.element(at: indexPath.row)
    }
    playContextAtIndexPathCallback = { indexPath in
      guard let playable = self.playables.element(at: indexPath.row) else { return nil }
      let contextPlayables = self.playables
        .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
      guard let contextIndex = contextPlayables.firstIndex(of: playable) else { return nil }
      return PlayContext(
        name: self.listTitle,
        index: contextIndex,
        playables: contextPlayables
      )
    }
    swipeCallback = { indexPath, completionHandler in
      guard let playable = self.playables.element(at: indexPath.row) else {
        completionHandler(nil)
        return
      }
      let contextPlayables = self.playables
        .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
      let contextIndex = contextPlayables.firstIndex(of: playable) ?? 0
      completionHandler(SwipeActionContext(
        containable: playable,
        playContext: PlayContext(
          name: self.listTitle,
          index: contextIndex,
          playables: contextPlayables
        )
      ))
    }

    updateContentUnavailable()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  func update(playables: [AbstractPlayable]) {
    self.playables = playables
    tableView.reloadData()
    detailHeaderView?.refresh()
    updateContentUnavailable()
  }

  private func updateContentUnavailable() {
    if playables.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = .musicalNotes
      config.text = emptyTitle
      config.secondaryText = emptySubtitle
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: - Table view data source

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    playables.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    guard let playable = playables.element(at: indexPath.row) else { return cell }
    cell.display(
      playable: playable,
      playContextCb: { [weak self] cell in
        guard let self,
              let indexPath = self.tableView.indexPath(for: cell)
        else { return nil }
        return self.playContextAtIndexPathCallback?(indexPath)
      },
      rootView: self
    )
    return cell
  }
}
