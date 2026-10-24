//
//  LyricTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 17.06.24.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import CoreData
import UIKit

// MARK: - LyricTableCellModel

@MainActor
class LyricTableCellModel {
  var lyric: LyricsLine? {
    didSet {
      rebuildStrings()
      cell?.refresh()
    }
  }

  var isActiveLine = false {
    didSet {
      cell?.refresh()
    }
  }

  /// word-level karaoke index into `syncedLine.words` — nil when the
  /// line carries no word timings or isn't the active line
  var activeWordIndex: Int? {
    didSet {
      rebuildStrings()
      cell?.refresh()
    }
  }

  /// accent for the currently sung word (§2.4 `sonicArtworkAccent` in
  /// vivid tint mode, `.label` otherwise)
  var accentColor: UIColor = .label {
    didSet {
      rebuildStrings()
      cell?.refresh()
    }
  }

  /// word-timed counterpart from `SyncedLyrics` (enhanced LRC) — nil for
  /// line-level sync and plain lyrics
  var syncedLine: LyricLine?

  private var attributedString: NSAttributedString?
  private var highlightedAttributedString: NSAttributedString?

  internal weak var cell: LyricTableCell?

  /// the tap-to-seek affordance only exists for synced (timed) lines
  var isSeekable: Bool {
    lyric?.start != nil
  }

  /// §3.1 — lyric lines scale with Dynamic Type (title3 ≈ 20pt)
  static var lineFont: UIFont {
    UIFontMetrics(forTextStyle: .title3)
      .scaledFont(for: .systemFont(ofSize: 20))
  }

  static var activeLineFont: UIFont {
    UIFontMetrics(forTextStyle: .title3)
      .scaledFont(for: .boldSystemFont(ofSize: 20))
  }

  var displayString: NSAttributedString? {
    if isActiveLine {
      return highlightedAttributedString
    } else {
      return attributedString
    }
  }

  init(lyric: LyricsLine, syncedLine: LyricLine? = nil, accentColor: UIColor = .label) {
    self.lyric = lyric
    self.syncedLine = syncedLine
    self.accentColor = accentColor
    self.isActiveLine = false
    rebuildStrings()
  }

  /// Rebuilds inactive/active renderings — active lines with word
  /// timings get per-word karaoke coloring (sung = label, current =
  /// accent, upcoming = gray); otherwise the active line renders as one
  /// bold run as before.
  private func rebuildStrings() {
    guard let lyric = lyric else {
      attributedString = nil
      highlightedAttributedString = nil
      return
    }
    attributedString = NSAttributedString(
      string: lyric.value,
      attributes:
      [
        .font: Self.lineFont,
        .foregroundColor: UIColor.gray,
      ]
    )
    if let words = syncedLine?.words,
       !words.isEmpty,
       words.map(\.value).joined() == lyric.value {
      let karaoke = NSMutableAttributedString()
      for (index, word) in words.enumerated() {
        var attributes: [NSAttributedString.Key: Any] = [
          .font: Self.activeLineFont,
          .foregroundColor: UIColor.label,
        ]
        if let activeWordIndex {
          if index > activeWordIndex {
            attributes[.foregroundColor] = UIColor.gray
          } else if index == activeWordIndex {
            attributes[.foregroundColor] = accentColor
          }
        }
        karaoke.append(NSAttributedString(string: word.value, attributes: attributes))
      }
      highlightedAttributedString = karaoke
    } else {
      highlightedAttributedString = NSAttributedString(
        string: lyric.value,
        attributes:
        [
          .font: Self.activeLineFont,
          .foregroundColor: UIColor.label,
        ]
      )
    }
  }

  public func calcHeight(containerWidth: CGFloat) -> CGFloat {
    let boundingSize = CGSize(
      width: LyricTableCell.adjustContainerWidthForMargins(containerWidth: containerWidth),
      height: 9_999
    )
    return displayString?.boundingRect(
      with: boundingSize,
      options: .usesLineFragmentOrigin,
      context: nil
    ).height ?? 0
  }
}

// MARK: - LyricTableCell

class LyricTableCell: UITableViewCell {
  private weak var viewModel: LyricTableCellModel? = nil

  private var lyricLabel: UILabel!
  override var layoutMargins: UIEdgeInsets { get { BasicTableCell.margin } set {} }

  static func adjustContainerWidthForMargins(containerWidth: CGFloat) -> CGFloat {
    containerWidth - (2 * BasicTableCell.margin.right)
  }

  public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    commonInit()
  }

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    commonInit()
  }

  private func commonInit() {
    lyricLabel = UILabel(frame: CGRect(
      x: layoutMargins.left,
      y: 0,
      width: bounds.width - (2 * layoutMargins.right),
      height: bounds.height
    ))
    lyricLabel.textAlignment = .center
    lyricLabel.lineBreakMode = .byWordWrapping
    lyricLabel.numberOfLines = 5
    selectionStyle = .none
    contentView.addSubview(lyricLabel)
    backgroundColor = .clear
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    lyricLabel.frame = CGRect(
      x: layoutMargins.left,
      y: 0,
      width: bounds.width - (2 * layoutMargins.right),
      height: bounds.height
    )
  }

  func display(model: LyricTableCellModel) {
    viewModel = model
    model.cell = self
    refresh()
  }

  func refresh() {
    guard let model = viewModel else { return }
    lyricLabel.attributedText = model.displayString
    lyricLabel.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
    // §8.2 — each line reads its text; timed lines get the seek hint
    isAccessibilityElement = true
    accessibilityLabel = model.lyric?.value
    accessibilityHint = model.isSeekable ? "Double-tap to play from this line" : nil
    accessibilityTraits = model.isSeekable ? [.staticText, .button] : .staticText
  }
}
