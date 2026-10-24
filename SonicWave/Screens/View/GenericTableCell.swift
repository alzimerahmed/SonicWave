//
//  GenericTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 20.02.22.
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
import UIKit

class GenericTableCell: BasicTableCell {
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var subtitleLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var infoLabel: UILabel!
  @IBOutlet
  weak var favoriteIconImage: UIImageView!

  @IBOutlet
  weak var infoLabelWidthConstraint: NSLayoutConstraint!

  static let rowHeight: CGFloat = 48.0 + margin.bottom + margin.top
  static let rowHeightWithoutImage: CGFloat = 28.0 + margin.bottom + margin.top

  private var container: PlayableContainable?
  private var rootView: UITableViewController?

  // G21 — playthrough hairline under the album title; only laid out while
  // this album is the one currently playing
  private var playthroughTrack: UIView?
  private var playthroughFill: UIView?
  private var playthroughFillWidthConstraint: NSLayoutConstraint?
  private var isPlaythroughRegistered = false

  override func prepareForReuse() {
    super.prepareForReuse()
    unregisterPlaythrough()
    playthroughTrack?.isHidden = true
  }

  /// hairline bar lazily pinned under the title — same visual language
  /// as `AlbumPlaythroughView` (hairline, `secondarySystemFill` track,
  /// accent fill) minus the `Track X of Y` caption, which does not fit
  /// a table row
  private func ensurePlaythroughTrack() -> UIView {
    if let playthroughTrack { return playthroughTrack }
    let track = UIView()
    track.backgroundColor = .secondarySystemFill
    track.layer.cornerRadius = AlbumPlaythroughView.barHeight / 2
    track.clipsToBounds = true
    track.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(track)

    let fill = UIView()
    fill.layer.cornerRadius = AlbumPlaythroughView.barHeight / 2
    fill.clipsToBounds = true
    fill.translatesAutoresizingMaskIntoConstraints = false
    track.addSubview(fill)
    playthroughFill = fill

    let fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: 0)
    playthroughFillWidthConstraint = fillWidth
    NSLayoutConstraint.activate([
      track.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      track.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      track.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
      track.heightAnchor.constraint(equalToConstant: AlbumPlaythroughView.barHeight),
      fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
      fill.topAnchor.constraint(equalTo: track.topAnchor),
      fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
      fillWidth,
    ])
    playthroughTrack = track
    return track
  }

  /// Playthrough progress while `album` is the album in play — the
  /// kit's cached verdict (album-shuffle session or contiguous album
  /// run), shown only when the playing song belongs to this row.
  private func albumPlaythroughInfo(for album: Album) -> AlbumProgressInfo? {
    let player = appDelegate.player
    guard let info = player.albumPlaythrough,
          player.currentlyPlaying?.asSong?.album?.id == album.id
    else { return nil }
    return info
  }

  private func registerPlaythrough() {
    guard !isPlaythroughRegistered else { return }
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(playerStateChanged(notification:)),
      name: .playerPlay,
      object: nil
    )
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(playerStateChanged(notification:)),
      name: .playerPause,
      object: nil
    )
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(playerStateChanged(notification:)),
      name: .playerStop,
      object: nil
    )
    isPlaythroughRegistered = true
  }

  private func unregisterPlaythrough() {
    guard isPlaythroughRegistered else { return }
    appDelegate.notificationHandler.remove(self, name: .playerPlay, object: nil)
    appDelegate.notificationHandler.remove(self, name: .playerPause, object: nil)
    appDelegate.notificationHandler.remove(self, name: .playerStop, object: nil)
    isPlaythroughRegistered = false
  }

  @objc
  private func playerStateChanged(notification: Notification) {
    refreshPlaythrough()
  }

  private func refreshPlaythrough() {
    guard let album = container as? Album,
          let info = albumPlaythroughInfo(for: album) else {
      playthroughTrack?.isHidden = true
      accessibilityLabel = nil
      return
    }
    let track = ensurePlaythroughTrack()
    track.isHidden = false
    playthroughFill?.backgroundColor = appDelegate.storage.settings.accounts
      .getSetting(album.account?.info).read.themePreference.asColor
    playthroughFillWidthConstraint?.isActive = false
    if let fill = playthroughFill {
      let constraint = fill.widthAnchor
        .constraint(equalTo: track.widthAnchor, multiplier: CGFloat(info.progressRatio))
      constraint.isActive = true
      playthroughFillWidthConstraint = constraint
    }
    let trackNumber = min(info.playedTrackCount + 1, info.totalTrackCount)
    // fold the playthrough into the row's label — a separate nested
    // element would split the cell's VoiceOver focus
    accessibilityLabel = [
      titleLabel.text,
      subtitleLabel.text,
      infoLabel.isHidden ? nil : infoLabel.text,
      String(
        format: NSLocalizedString(
          "Album progress: track %d of %d",
          comment: "VoiceOver label for the album playthrough hairline"
        ),
        trackNumber,
        info.totalTrackCount
      ),
    ].compactMap { $0 }.joined(separator: ", ")
  }

  func display(container: PlayableContainable, rootView: UITableViewController) {
    self.container = container
    self.rootView = rootView
    selectionStyle = .none
    titleLabel.text = container.name
    subtitleLabel.isHidden = container.subtitle == nil
    subtitleLabel.text = container.subtitle
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
        .themePreference,
      container: container
    )
    let infoText = container.info(
      for: container.account?.apiType.asServerApiType,
      details: DetailInfoType(type: .short, settings: appDelegate.storage.settings)
    )
    infoLabel.isHidden = infoText.isEmpty
    infoLabel.text = infoText
    infoLabel.textAlignment = (traitCollection.horizontalSizeClass == .regular) ? .right : .left
    favoriteIconImage.isHidden = !container.isFavorite
    favoriteIconImage.tintColor = .red

    if container is Album {
      infoLabelWidthConstraint.constant = 75
    } else if container is Artist {
      infoLabelWidthConstraint.constant = 230
    } else if container is Genre {
      infoLabelWidthConstraint.constant = 260
    } else if container is Podcast {
      infoLabelWidthConstraint.constant = 140
    }
    accessoryType = .disclosureIndicator
    backgroundColor = .sonicSystemBackground

    // the hairline rides the play indicator's notification cadence —
    // registered only while the row shows an album so playback events
    // can flip it on without a table reload
    if container is Album {
      registerPlaythrough()
    }
    refreshPlaythrough()
  }
}
