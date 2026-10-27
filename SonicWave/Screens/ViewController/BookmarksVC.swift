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
  /// bookmark media id → local library title — prefetched once per
  /// reload so cell rendering does zero CoreData fetches
  private var resolvedTitles = [String: String]()
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
    title = String(localized: "Bookmarks", comment: "Bookmarks screen title")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "bookmarkCell")
    tableView.backgroundColor = .backgroundColor
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "plus"),
      style: .plain,
      target: self,
      action: #selector(addBookmarkAtCurrentPosition)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "Bookmark current position",
      comment: "VoiceOver label for the add-bookmark button"
    )
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
          // one fetch pass per reload — cells must not hit CoreData
          // per render
          let library = appDelegate.storage.main.library
          var titles = [String: String]()
          for bookmark in bookmarks {
            if let title = library.getSong(for: account, id: bookmark.id)?.title
              ?? library.getPodcastEpisode(for: account, id: bookmark.id)?.title {
              titles[bookmark.id] = title
            }
          }
          resolvedTitles = titles
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
      config.text = String(
        localized: "Couldn't Load Bookmarks",
        comment: "Bookmarks empty state: load failure"
      )
      config.secondaryText = String(
        localized: "Check the connection and pull to retry.",
        comment: "Bookmarks empty state: retry hint"
      )
      contentUnavailableConfiguration = config
    case .notSupported:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "bookmark.slash")
      config.text = String(
        localized: "Bookmarks Not Supported",
        comment: "Bookmarks empty state: server lacks the API"
      )
      config.secondaryText = String(
        localized: "This server has no bookmark API.",
        comment: "Bookmarks empty state: not-supported hint"
      )
      contentUnavailableConfiguration = config
    case .loaded where bookmarks.isEmpty:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "bookmark")
      config.text = String(localized: "No Bookmarks", comment: "Bookmarks empty state")
      config.secondaryText = String(
        localized: "Tap + while a song or podcast episode is playing to save its position.",
        comment: "Bookmarks empty state: how to add one"
      )
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
    let resolved = resolvedTitles[bookmark.id] ?? bookmark.entry?.title
    content.text = resolved ?? bookmark.comment ?? String(
      format: String(
        localized: "Bookmark %@",
        comment: "Fallback title for a bookmark with no resolvable name (media id)"
      ),
      bookmark.id
    )
    var parts = [String]()
    if let artist = bookmark.entry?.artistName { parts.append(artist) }
    if let album = bookmark.entry?.albumName { parts.append(album) }
    if resolved == nil {
      parts.append(String(
        localized: "not in library",
        comment: "Bookmark row detail: media is not in the local library"
      ))
    }
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
    let delete = UIContextualAction(
      style: .destructive,
      title: String(localized: "Delete", comment: "Swipe action: delete bookmark")
    ) { _, _, done in
      Task { @MainActor in
        do {
          // Subsonic deletes by media id — the bookmarked entity itself
          // may be gone locally, so the request carries the raw id
          switch try await self.backendApi.deleteBookmark(bookmark) {
          case .supported:
            // a concurrent reload may have shrunk/reordered the list or
            // changed the load state during the await — resolve by
            // identity, never by the captured indexPath
            if self.loadState == .loaded,
               let row = self.bookmarks.firstIndex(of: bookmark) {
              self.bookmarks.remove(at: row)
              self.resolvedTitles.removeValue(forKey: bookmark.id)
              tableView.deleteRows(at: [IndexPath(row: row, section: indexPath.section)], with: .automatic)
            } else {
              tableView.reloadData()
            }
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
