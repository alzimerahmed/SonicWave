//
//  RatingView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 21.01.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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

// MARK: - RatingViewDelegate

@MainActor
protocol RatingViewDelegate: AnyObject {
  func ratingView(_ ratingView: RatingView, didChangeRating rating: Int)
}

// MARK: - RatingView

class RatingView: UIView {
  // MARK: - Properties

  weak var delegate: RatingViewDelegate?

  private var starButtons: [UIButton] = []
  private let starCount = 5
  private let starSize: CGFloat = 25 // 10% smaller than original 28
  private let starSpacing: CGFloat = 4

  /// Star color that adapts to light/dark mode - black for light, 90% white for dark
  private static var starColor: UIColor {
    UIColor { traitCollection in
      if traitCollection.userInterfaceStyle == .light {
        return .black
      } else {
        return UIColor(white: 0.9, alpha: 1.0)
      }
    }
  }

  private(set) var rating: Int = 0 {
    didSet {
      updateStarDisplay()
    }
  }

  /// Whether the rating view is enabled for interaction
  /// When disabled, opacity is reduced and touches are ignored
  var isRatingEnabled: Bool = true {
    didSet {
      updateEnabledState()
    }
  }

  // MARK: - Initialization

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  // MARK: - Setup

  private func setupView() {
    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.spacing = starSpacing
    stackView.alignment = .center
    stackView.distribution = .equalSpacing
    stackView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
      stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
      stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])

    // Create star buttons
    for i in 0 ..< starCount {
      let button = UIButton(type: .system)
      button.tag = i + 1 // Tags 1-5 represent star ratings
      button.tintColor = Self.starColor
      button.setImage(.starEmpty, for: .normal)
      button.accessibilityLabel = "Rate \(i + 1) of \(starCount) stars"

      let config = UIImage.SymbolConfiguration(pointSize: starSize, weight: .regular)
      button.setPreferredSymbolConfiguration(config, forImageIn: .normal)

      button.addTarget(self, action: #selector(starTapped(_:)), for: .touchUpInside)

      // Add long press to clear rating
      let longPress = UILongPressGestureRecognizer(
        target: self,
        action: #selector(starLongPressed(_:))
      )
      longPress.minimumPressDuration = 0.5
      button.addGestureRecognizer(longPress)

      starButtons.append(button)
      stackView.addArrangedSubview(button)
    }

    updateStarDisplay()
  }

  // MARK: - Actions

  @objc
  private func starTapped(_ sender: UIButton) {
    guard isRatingEnabled else { return }

    let newRating = sender.tag

    // If tapping the same star that represents current rating, clear it
    if newRating == rating {
      setRating(0, animated: true)
    } else {
      setRating(newRating, animated: true)
    }

    delegate?.ratingView(self, didChangeRating: rating)

    // Haptic feedback
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
  }

  @objc
  private func starLongPressed(_ sender: UILongPressGestureRecognizer) {
    guard isRatingEnabled, sender.state == .began else { return }

    setRating(0, animated: true)
    delegate?.ratingView(self, didChangeRating: rating)

    // Haptic feedback
    Haptics.medium.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
  }

  // MARK: - Public Methods

  func setRating(_ newRating: Int, animated: Bool = false) {
    let clampedRating = max(0, min(starCount, newRating))

    if animated, clampedRating != rating {
      // Animate the change
      UIView.animate(withDuration: 0.15) {
        self.rating = clampedRating
      }
    } else {
      rating = clampedRating
    }
  }

  // MARK: - Private Methods

  private func updateStarDisplay() {
    for (index, button) in starButtons.enumerated() {
      let starNumber = index + 1
      let isFilled = starNumber <= rating
      button.setImage(isFilled ? .starFill : .starEmpty, for: .normal)

      // Apply reduced opacity + disabled state (VoiceOver reads "dimmed")
      button.isEnabled = isRatingEnabled
      if isRatingEnabled {
        button.alpha = 1.0
      } else {
        // 30% opacity for filled stars, 5% for empty stars when disabled
        button.alpha = isFilled ? 0.3 : 0.05
      }
    }
  }

  private func updateEnabledState() {
    // Re-apply star display with appropriate opacity
    updateStarDisplay()
  }
}
