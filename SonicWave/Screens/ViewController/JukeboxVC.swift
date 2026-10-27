//
//  JukeboxVC.swift
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

// MARK: - JukeboxVC

/// G11: controls the server-side jukebox (Subsonic `jukeboxControl`,
/// Ampache `localplay`) — playlist, play/stop/skip/select, gain,
/// enqueue. The jukebox plays on the SERVER's own output device, not on
/// this phone — the header copy says so explicitly.
class JukeboxVC: UITableViewController {
  enum LoadState {
    case loading
    case loaded
    case notSupported
    case failed
  }

  private let account: Account
  private var playlist = JukeboxPlaylist()
  private var loadState: LoadState = .loading
  private var controlsHeader: UIStackView!
  private var headerLabel: UILabel!
  private var headerStack: UIStackView!

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
    title = String(localized: "Jukebox", comment: "Server jukebox screen title")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "jukeboxCell")
    tableView.backgroundColor = .backgroundColor
    refreshControl = UIRefreshControl()
    refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "text.badge.plus"),
      style: .plain,
      target: self,
      action: #selector(enqueueCurrentTrack)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "Enqueue current track",
      comment: "VoiceOver label for the jukebox enqueue button"
    )

    controlsHeader = buildControls()
    headerLabel = UILabel()
    headerLabel.font = .preferredFont(forTextStyle: .footnote)
    // Dynamic Type — the header must re-wrap instead of clipping
    headerLabel.adjustsFontForContentSizeCategory = true
    headerLabel.textColor = .secondaryLabel
    headerLabel.numberOfLines = 0
    // a stack view ignores arranged-subview layoutMargins — a container
    // gives the label the same 16pt inset the buttons get
    let labelContainer = UIView()
    labelContainer.addSubview(headerLabel)
    headerLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      headerLabel.leadingAnchor.constraint(equalTo: labelContainer.leadingAnchor, constant: 16),
      headerLabel.trailingAnchor.constraint(equalTo: labelContainer.trailingAnchor, constant: -16),
      headerLabel.topAnchor.constraint(equalTo: labelContainer.topAnchor),
      headerLabel.bottomAnchor.constraint(equalTo: labelContainer.bottomAnchor),
    ])
    headerStack = UIStackView(arrangedSubviews: [controlsHeader, labelContainer])
    headerStack.axis = .vertical
    headerStack.spacing = 4
    headerStack.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    headerStack.isLayoutMarginsRelativeArrangement = true
    tableView.tableHeaderView = headerStack
    updateHeader()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    fitHeaderToWidth()
  }

  /// UITableView never resizes tableHeaderView itself — re-fit on every
  /// layout pass and reload so rotation and Dynamic Type don't clip the
  /// copy (the old code hardcoded a 96pt frame that clipped)
  private func fitHeaderToWidth() {
    guard let header = tableView.tableHeaderView,
          tableView.bounds.width > 0 else { return }
    let size = header.systemLayoutSizeFitting(
      CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    if header.frame.size != size {
      header.frame.size = size
      tableView.tableHeaderView = header
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
    reload()
  }

  private func buildControls() -> UIStackView {
    func button(_ title: String, systemImage: String, action: Selector) -> UIButton {
      var config = UIButton.Configuration.tinted()
      config.title = title
      config.image = UIImage(systemName: systemImage)
      config.imagePadding = 4
      let b = UIButton(configuration: config)
      b.addTarget(self, action: action, for: .touchUpInside)
      return b
    }
    let stack = UIStackView(arrangedSubviews: [
      button(
        String(localized: "Play", comment: "Jukebox control"),
        systemImage: "play.fill",
        action: #selector(controlPlay)
      ),
      button(
        String(localized: "Stop", comment: "Jukebox control"),
        systemImage: "stop.fill",
        action: #selector(controlStop)
      ),
      button(
        String(localized: "Skip", comment: "Jukebox control"),
        systemImage: "forward.fill",
        action: #selector(controlSkip)
      ),
      button(
        String(localized: "Clear", comment: "Jukebox control"),
        systemImage: "trash",
        action: #selector(controlClear)
      ),
    ])
    stack.axis = .horizontal
    stack.distribution = .fillEqually
    stack.spacing = 8
    stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    stack.isLayoutMarginsRelativeArrangement = true
    return stack
  }

  private func updateHeader() {
    var lines = String(
      localized: "Plays on the server's own output — not on this device.",
      comment: "Jukebox header explanation"
    )
    if let gain = playlist.gain {
      lines += String(
        format: String(
          localized: "  Gain %lld%%",
          comment: "Jukebox header: current playback gain"
        ),
        Int(gain * 100)
      )
    }
    // the label is persistent — only the text changes per reload
    headerLabel.text = lines
    fitHeaderToWidth()
  }

  @objc
  private func reload() {
    if playlist.entries.isEmpty { loadState = .loading }
    updateContentUnavailable()
    Task { @MainActor in
      do {
        switch try await backendApi.getJukeboxPlaylist() {
        case .supported(let fetched):
          playlist = fetched
          loadState = .loaded
        case .notSupported:
          loadState = .notSupported
        }
      } catch {
        appDelegate.eventLogger.report(topic: "Jukebox", error: error)
        if playlist.entries.isEmpty { loadState = .failed }
      }
      refreshControl?.endRefreshing()
      updateContentUnavailable()
      updateHeader()
      tableView.reloadData()
    }
  }

  private func control(_ action: JukeboxAction) {
    Task { @MainActor in
      do {
        switch try await backendApi.jukeboxControl(action) {
        case .supported:
          reload()
        case .notSupported:
          appDelegate.eventLogger.info(
            topic: "Jukebox",
            message: "This action is not supported by the server's jukebox.",
            displayPopup: true
          )
        }
      } catch {
        appDelegate.eventLogger.report(topic: "Jukebox", error: error)
      }
    }
  }

  @objc private func controlPlay() { control(.start) }
  @objc private func controlStop() { control(.stop) }
  @objc private func controlSkip() {
    control(.skip(index: playlist.currentIndex + 1, offsetSeconds: 0))
  }
  @objc private func controlClear() {
    let alert = UIAlertController(
      title: String(
        localized: "Clear Jukebox Playlist?",
        comment: "Jukebox clear confirmation title"
      ),
      message: String(
        localized: "Removes all tracks from the server-side playlist.",
        comment: "Jukebox clear confirmation message"
      ),
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(
      title: String(localized: "Clear", comment: "Jukebox clear confirmation action"),
      style: .destructive
    ) { _ in
      self.control(.clear)
    })
    alert.addAction(UIAlertAction(
      title: String(localized: "Cancel", comment: "Cancel action"),
      style: .cancel
    ))
    present(alert, animated: true)
  }

  @objc
  private func enqueueCurrentTrack() {
    guard let playable = appDelegate.player.currentlyPlaying else {
      appDelegate.eventLogger.info(
        topic: "Jukebox",
        message: "Nothing is playing on this device — start a track first.",
        displayPopup: true
      )
      return
    }
    control(.add(ids: [playable.info.id]))
  }

  private func updateContentUnavailable() {
    switch loadState {
    case .loading:
      contentUnavailableConfiguration = nil
    case .failed:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "exclamationmark.triangle")
      config.text = String(
        localized: "Couldn't Load Jukebox",
        comment: "Jukebox empty state: load failure"
      )
      config.secondaryText = String(
        localized: "Check the connection and pull to retry.",
        comment: "Jukebox empty state: retry hint"
      )
      contentUnavailableConfiguration = config
    case .notSupported:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "hifispeaker.slash")
      config.text = String(
        localized: "No Jukebox on This Server",
        comment: "Jukebox empty state: not supported"
      )
      config.secondaryText = String(
        localized: "Subsonic needs the jukebox role enabled for this user; Ampache needs a configured localplay instance.",
        comment: "Jukebox empty state: not-supported hint"
      )
      contentUnavailableConfiguration = config
    case .loaded where playlist.entries.isEmpty:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "hifispeaker")
      config.text = String(
        localized: "Jukebox Playlist Is Empty",
        comment: "Jukebox empty state"
      )
      config.secondaryText = String(
        localized: "Enqueue the currently playing track with +.",
        comment: "Jukebox empty state: how to add a track"
      )
      contentUnavailableConfiguration = config
    case .loaded:
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: table

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    loadState == .loaded ? playlist.entries.count : 0
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "jukeboxCell", for: indexPath)
    let entry = playlist.entries[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = entry.title ?? entry.id
    var parts = [String]()
    if let artist = entry.artistName { parts.append(artist) }
    if let album = entry.albumName { parts.append(album) }
    if entry.durationSeconds > 0 {
      parts.append(ClockTime(timeInSeconds: entry.durationSeconds).asShortString())
    }
    content.secondaryText = parts.joined(separator: " · ")
    let isCurrent = indexPath.row == playlist.currentIndex
    cell.accessoryType = isCurrent ? .checkmark : .none
    if isCurrent {
      content.textProperties.color = .tintColor
      if playlist.isPlaying {
        content.secondaryText =
          (content.secondaryText ?? "") + " · "
          + String(localized: "playing", comment: "Jukebox row: currently playing marker")
      }
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    control(.set(index: indexPath.row))
  }
}
