//
//  BasicButton.swift
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

import UIKit

class BasicButton: UIButton {
  static let cornerRadius = 10.0

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    configureStyle()
  }

  func configureStyle() {
    layer.cornerRadius = Self.cornerRadius
  }
}

/// UIButton whose touch area never shrinks below the 44×44pt minimum —
/// small icon buttons (28×28 option rows, 30×30 fav/options) stay visually
/// compact but hittable. Same pattern as `SeekableTimeSlider`.
class MinimumHitAreaButton: UIButton {
  static let minimumHitSize: CGFloat = 44

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard bounds.width < Self.minimumHitSize || bounds.height < Self.minimumHitSize
    else { return super.point(inside: point, with: event) }
    let expandedBounds = bounds.insetBy(
      dx: (bounds.width - Self.minimumHitSize) / 2,
      dy: (bounds.height - Self.minimumHitSize) / 2
    )
    return expandedBounds.contains(point)
  }
}
