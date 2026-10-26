//
//  BookmarksVC.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 27.02.26.
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

// MARK: - BookmarksVC

/// G19: server-side bookmarks (saved playback positions) — list, resume
/// at position, create at the current position, delete. Data is fetched
/// from the backend on every appearance (`getBookmarks`) — no CoreData
/// mirror, so a deleted media id renders with its server-side title or a
/// "not in library" mark instead of silently disappearing.
class BookmarksVC: UITableViewController {
  enum LoadState {
    case loading
    case loaded
    case notSupported
    case failed
  }

  private let account: Account
  private var bookmarks = [ServerBookmark]()
  private var loadState: LoadState = .loading

  init(account: Account) {
    self.account = account
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var backendApi: BackendApi {
    appDelegate.getMeta(account.info).backendApi
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Bookmarks"
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "bookmarkCell")
    tableView.backgroundColor = .backgroundColor
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "plus"),
      style: .plain,
      target: self,
      action: #selector(addBookmarkAtCurrentPosition)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = "Bookmark current position"
    refreshControl = UIRefreshControl()
    refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
    reload()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  @objc
  private func reload() {
    if bookmarks.isEmpty { loadState = .loading }
    updateContentUnavailable()
    Task { @MainActor in
      do {
        switch try await backendApi.getBookmarks() {
        case .supported(let fetched):
          bookmarks = fetched.sorted { ($0.changed ?? $0.created ?? .distantPast) > ($1.changed ?? $1.created ?? .distantPast) }
          loadState = .loaded
        case .notSupported:
          loadState = .notSupported
        }
      } catch {
        appDelegate.eventLogger.report(topic: "Bookmarks", error: error)
        if bookmarks.isEmpty { loadState = .failed }
      }
      refreshControl?.endRefreshing()
      updateContentUnavailable()
      tableView.reloadData()
    }
  }

  private func updateContentUnavailable() {
    switch loadState {
    case .loading:
      contentUnavailableConfiguration = nil
    case .failed:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "exclamationmark.triangle")
      config.text = "Couldn't Load Bookmarks"
      config.secondaryText = "Check the connection and pull to retry."
      contentUnavailableConfiguration = config
    case .notSupported:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "bookmark.slash")
      config.text = "Bookmarks Not Supported"
      config.secondaryText = "This server has no bookmark API."
      contentUnavailableConfiguration = config
    case .loaded where bookmarks.isEmpty:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "bookmark")
      config.text = "No Bookmarks"
      config.secondaryText = "Tap + while a song or podcast episode is playing to save its position."
      contentUnavailableConfiguration = config
    case .loaded:
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: actions

  @objc
  private func addBookmarkAtCurrentPosition() {
    guard let playable = appDelegate.player.currentlyPlaying else {
      appDelegate.eventLogger.info(
        topic: "Bookmarks",
        message: "Nothing is playing — start a song or episode first.",
        displayPopup: true
      )
      return
    }
    let positionSeconds = Int(appDelegate.player.elapsedTime)
    Task { @MainActor in
      do {
        switch try await backendApi.createBookmark(
          playableInfo: playable.info,
          positionSeconds: positionSeconds
        ) {
        case .supported:
          reload()
        case .notSupported:
          appDelegate.eventLogger.info(
            topic: "Bookmarks",
            message: "Bookmarks are not supported by this server.",
            displayPopup: true
          )
        }
      } catch {
        appDelegate.eventLogger.report(topic: "Bookmarks", error: error)
      }
    }
  }

  private func resume(_ bookmark: ServerBookmark) {
    let library = appDelegate.storage.main.library
    if let song = library.getSong(for: account, id: bookmark.id) {
      appDelegate.player.play(
        context: PlayContext(name: "Bookmark", type: .music, playables: [song])
      )
      appDelegate.player.seek(toSecond: Double(bookmark.positionSeconds))
      return
    }
    if let episode = library.getPodcastEpisode(for: account, id: bookmark.id) {
      appDelegate.player.play(
        context: PlayContext(name: "Bookmark", type: .podcast, playables: [episode])
      )
      appDelegate.player.seek(toSecond: Double(bookmark.positionSeconds))
      return
    }
    appDelegate.eventLogger.info(
      topic: "Bookmarks",
      message: "This entry is not in the local library — resync or the item was removed on the server.",
      displayPopup: true
    )
  }

  // MARK: table

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    loadState == .loaded ? bookmarks.count : 0
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "bookmarkCell", for: indexPath)
    let bookmark = bookmarks[indexPath.row]
    var content = cell.defaultContentConfiguration()
    let library = appDelegate.storage.main.library
    let resolved = library.getSong(for: account, id: bookmark.id)?.title
      ?? library.getPodcastEpisode(for: account, id: bookmark.id)?.title
      ?? bookmark.entry?.title
    content.text = resolved ?? bookmark.comment ?? "Bookmark \(bookmark.id)"
    var parts = [String]()
    if let artist = bookmark.entry?.artistName { parts.append(artist) }
    if let album = bookmark.entry?.albumName { parts.append(album) }
    if resolved == nil { parts.append("not in library") }
    parts.append(ClockTime(timeInSeconds: bookmark.positionSeconds).asShortString())
    content.secondaryText = parts.joined(separator: " · ")
    content.image = UIImage(systemName: "bookmark.fill")
    cell.contentConfiguration = content
    cell.accessoryType = .detailButton
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    resume(bookmarks[indexPath.row])
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let bookmark = bookmarks[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
      Task { @MainActor in
        do {
          // Subsonic deletes by media id — the bookmarked entity itself
          // may be gone locally, so the request carries the raw id
          switch try await self.backendApi.deleteBookmark(bookmark) {
          case .supported:
            self.bookmarks.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            self.updateContentUnavailable()
          case .notSupported:
            self.appDelegate.eventLogger.info(
              topic: "Bookmarks",
              message: "Bookmarks are not supported by this server.",
              displayPopup: true
            )
          }
        } catch {
          self.appDelegate.eventLogger.report(topic: "Bookmarks", error: error)
        }
        done(true)
      }
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }
}
