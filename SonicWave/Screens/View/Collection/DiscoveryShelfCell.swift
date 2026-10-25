//
//  DiscoveryShelfCell.swift
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

// MARK: - DiscoveryShelfCell

/// Phase-8 discovery card (G7 mixes, G20 similar artists): square artwork
/// on top, title + subtitle beneath — same silhouette as `AlbumCollectionCell`
/// but programmatic so it can render entities that have no CoreData mirror
/// (mix kinds, similar-artist stubs) via generated artwork placeholders.
final class DiscoveryShelfCell: UICollectionViewCell {
  static let reuseID = "DiscoveryShelfCell"

  private let entityImage = LibraryEntityImage(frame: .zero)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)

  override init(frame: CGRect) {
    super.init(frame: frame)
    entityImage.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    spinner.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 2
    titleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = 2
    subtitleLabel.adjustsFontForContentSizeCategory = true
    spinner.hidesWhenStopped = true

    contentView.addSubview(entityImage)
    contentView.addSubview(titleLabel)
    contentView.addSubview(subtitleLabel)
    contentView.addSubview(spinner)
    NSLayoutConstraint.activate([
      entityImage.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      entityImage.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      entityImage.topAnchor.constraint(equalTo: contentView.topAnchor),
      entityImage.heightAnchor.constraint(equalTo: entityImage.widthAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      titleLabel.topAnchor.constraint(equalTo: entityImage.bottomAnchor, constant: 6),
      subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: entityImage.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: entityImage.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    spinner.stopAnimating()
    titleLabel.text = nil
    subtitleLabel.text = nil
  }

  /// a local-mirror entity with a real artwork lookup. `isInteractive`
  /// must reflect whether a tap actually does something — a card whose
  /// selection handler silently returns is not a button.
  func display(
    entity: AbstractLibraryEntity,
    title: String,
    subtitle: String?,
    isInteractive: Bool
  ) {
    entityImage.display(entity: entity)
    titleLabel.text = title
    subtitleLabel.text = subtitle
    subtitleLabel.isHidden = subtitle?.isEmpty != false
    isAccessibilityElement = true
    accessibilityLabel = subtitle.map { "\(title), \($0)" } ?? title
    accessibilityTraits = isInteractive ? .button : []
  }

  /// no mirror entry — generated-artwork placeholder per `ArtworkType`
  /// (G7 mix kinds, unsynced similar artists); never a gray box.
  /// `isInteractive` semantics identical to `display(entity:…)`.
  func display(
    artworkType: ArtworkType,
    title: String,
    subtitle: String?,
    isInteractive: Bool
  ) {
    entityImage.display(artworkType: artworkType)
    titleLabel.text = title
    subtitleLabel.text = subtitle
    subtitleLabel.isHidden = subtitle?.isEmpty != false
    isAccessibilityElement = true
    accessibilityLabel = subtitle.map { "\(title), \($0)" } ?? title
    accessibilityTraits = isInteractive ? .button : []
  }

  var isLoading: Bool {
    get { spinner.isAnimating }
    set { newValue ? spinner.startAnimating() : spinner.stopAnimating() }
  }
}
