//
//  PlaylistTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

class PlaylistTableCell: BasicTableCell {
  @IBOutlet
  weak var nameLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var infoLabel: UILabel!

  static let rowHeight: CGFloat = 70.0 + margin.bottom + margin.top

  private var playlist: Playlist?
  private var rootView: UITableViewController?
  private var smartBadge: UIImageView?

  func display(playlist: Playlist, rootView: UITableViewController?) {
    self.playlist = playlist
    self.rootView = rootView
    nameLabel.text = playlist.name
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(playlist.account?.info).read
        .themePreference,
      container: playlist
    )
    // G8: smart playlists get a sparkles badge on the artwork corner —
    // the affordance reads without color alone (glyph + VoiceOver label)
    if playlist.isSmartPlaylist {
      if smartBadge == nil {
        let badge = UIImageView(image: .sparkles.withRenderingMode(.alwaysTemplate))
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.tintColor = .secondaryLabel
        entityImage.addSubview(badge)
        NSLayoutConstraint.activate([
          badge.widthAnchor.constraint(equalToConstant: 14),
          badge.heightAnchor.constraint(equalToConstant: 14),
          badge.trailingAnchor.constraint(equalTo: entityImage.trailingAnchor, constant: -2),
          badge.bottomAnchor.constraint(equalTo: entityImage.bottomAnchor, constant: -2),
        ])
        smartBadge = badge
      }
      smartBadge?.isHidden = false
      accessibilityLabel = nameLabel.text.map {
        $0 + ", " + NSLocalizedString(
          "Smart playlist",
          comment: "VoiceOver modifier for smart playlist rows"
        )
      }
    } else {
      smartBadge?.isHidden = true
      accessibilityLabel = nameLabel.text
    }
    infoLabel.text = playlist.info(
      for: playlist.account?.apiType.asServerApiType,
      details: DetailInfoType(type: .short, settings: appDelegate.storage.settings)
    )
    infoLabel.textAlignment = (traitCollection.horizontalSizeClass == .regular) ? .right : .left
    accessoryType = .disclosureIndicator
    backgroundColor = .sonicSystemBackground
  }
}
