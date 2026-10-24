//
//  AlbumPlaythroughView.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 15.11.25.
//  Copyright (c) 2025 Alzimer Ahmed. All rights reserved.
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

// MARK: - AlbumPlaythroughView

/// G21 — album playthrough indicator for Now Playing: a hairline progress
/// bar plus a `Track X of Y` caption that sits under the album line.
/// Visible only while an album-shuffle session runs or the context queue
/// is a contiguous album; collapses in the details stack otherwise.
class AlbumPlaythroughView: UIView {
  private static let barHeight: CGFloat = 3.0
  private static let spacing: CGFloat = 8.0

  private let captionLabel = UILabel()
  private let trackView = UIView()
  private let fillView = UIView()
  private var fillWidthConstraint: NSLayoutConstraint?

  override init(frame: CGRect) {
    super.init(frame: frame)
    commonInit()
  }

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    commonInit()
  }

  private func commonInit() {
    captionLabel.font = .sonicAudioInfo()
    captionLabel.adjustsFontForContentSizeCategory = true
    captionLabel.textColor = .secondaryLabel
    captionLabel.setContentHuggingPriority(.required, for: .horizontal)

    // hairline bar — intrinsic pill ends (height/2), not a styled radius
    trackView.backgroundColor = .secondarySystemFill
    trackView.layer.cornerRadius = Self.barHeight / 2
    trackView.clipsToBounds = true

    fillView.layer.cornerRadius = Self.barHeight / 2
    fillView.clipsToBounds = true

    for view in [captionLabel, trackView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    fillView.translatesAutoresizingMaskIntoConstraints = false
    trackView.addSubview(fillView)

    fillWidthConstraint = fillView.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      captionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      trackView.leadingAnchor.constraint(
        equalTo: captionLabel.trailingAnchor,
        constant: Self.spacing
      ),
      trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      trackView.centerYAnchor.constraint(equalTo: centerYAnchor),
      trackView.heightAnchor.constraint(equalToConstant: Self.barHeight),
      fillView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
      fillView.topAnchor.constraint(equalTo: trackView.topAnchor),
      fillView.bottomAnchor.constraint(equalTo: trackView.bottomAnchor),
      fillWidthConstraint!,
      heightAnchor.constraint(equalToConstant: 18),
    ])

    isAccessibilityElement = true
    accessibilityTraits = .updatesFrequently
    isHidden = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateFillWidth()
  }

  private var progressRatio: Double = 0

  /// Re-render for the current playthrough — `nil` collapses the row.
  /// `tint` is the §2.4 `sonicArtworkAccent` in vivid mode.
  func display(info: AlbumProgressInfo?, tint: UIColor? = nil) {
    guard let info else {
      isHidden = true
      accessibilityLabel = nil
      return
    }
    isHidden = false
    progressRatio = info.progressRatio
    let trackNumber = min(info.playedTrackCount + 1, info.totalTrackCount)
    captionLabel.text = String(
      format: NSLocalizedString(
        "Track %d of %d",
        comment: "Album playthrough caption: first %d = current track, second %d = total"
      ),
      trackNumber,
      info.totalTrackCount
    )
    fillView.backgroundColor = tint ?? .secondaryLabel
    accessibilityLabel = String(
      format: NSLocalizedString(
        "Album progress: track %d of %d",
        comment: "VoiceOver label for the album playthrough hairline"
      ),
      trackNumber,
      info.totalTrackCount
    )
    updateFillWidth()
  }

  private func updateFillWidth() {
    fillWidthConstraint?.constant = trackView.bounds.width * progressRatio
  }
}
