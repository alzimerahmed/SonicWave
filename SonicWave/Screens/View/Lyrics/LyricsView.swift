//
//  LyricsView.swift
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
import CoreMedia
import Foundation
import UIKit

// MARK: - LyricsPaneState

/// content state of the lyrics pane (design-system §5.6) — the table
/// shows lyric rows; the overlay covers loading/empty/offline.
enum LyricsPaneState {
  case hidden
  case loading
  case empty
  case offlineEmpty
}

// MARK: - LyricsView

class LyricsView: UITableView, UITableViewDataSource, UITableViewDelegate {
  private var lyrics: StructuredLyrics? = nil
  private var lyricModels: [LyricTableCellModel] = []
  private var lastIndex: Int?
  private var lineSpacing: CGFloat = 16
  private var hasLastLyricsLineAlreadyDisplayedOnce = false
  private var scrollAnimation = true
  private var suppressAutoScrollUntil: Date?
  private let autoScrollSuppressionInterval: TimeInterval = 5.0

  /// word-timed lines parallel to `lyrics.line` — only populated by the
  /// `display(syncedLyrics:)` path; drives `activeWordIndex` karaoke
  private var wordTimedLines: [LyricLine]?
  /// true while the pane renders `SyncedLyricsTracker` output — legacy
  /// `scroll(toTime:)` ticks are ignored so the tracker owns the position
  private var isTrackerDriven = false

  /// §2.4 accent for the currently sung word (vivid tint mode)
  public var accentColor: UIColor = .label {
    didSet {
      lyricModels.forEach { $0.accentColor = accentColor }
    }
  }

  public var onLyricSelected: ((LyricsLine) -> ())?

  // MARK: - Pane state overlay (loading / empty / offline)

  private let stateOverlay = UIView()
  private let stateIcon = UIImageView()
  private let stateLabel = UILabel()
  private let stateSpinner = UIActivityIndicatorView(style: .medium)

  override init(frame: CGRect, style: UITableView.Style) {
    super.init(frame: frame, style: style)
    commonInit()
  }

  public required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    commonInit()
  }

  private func commonInit() {
    register(LyricTableCell.self, forCellReuseIdentifier: LyricTableCell.typeName)

    separatorStyle = .none
    clipsToBounds = true

    dataSource = self
    delegate = self
    allowsSelection = true

    backgroundColor = .clear
    setupStateOverlay()
  }

  /// §5.6 empty/loading language for the lyrics pane — glyph +
  /// one-line copy, never a bare "No Lyrics" string in the table.
  private func setupStateOverlay() {
    stateOverlay.translatesAutoresizingMaskIntoConstraints = false
    stateOverlay.isHidden = true
    addSubview(stateOverlay)

    stateIcon.translatesAutoresizingMaskIntoConstraints = false
    stateIcon.tintColor = .secondaryLabel
    stateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      textStyle: .title2
    )
    stateIcon.contentMode = .scaleAspectFit
    stateIcon.accessibilityElementsHidden = true
    stateOverlay.addSubview(stateIcon)

    stateSpinner.translatesAutoresizingMaskIntoConstraints = false
    stateSpinner.color = .secondaryLabel
    stateSpinner.hidesWhenStopped = true
    stateSpinner.accessibilityElementsHidden = true
    stateOverlay.addSubview(stateSpinner)

    stateLabel.translatesAutoresizingMaskIntoConstraints = false
    stateLabel.font = .sonicRowSubtitle()
    stateLabel.adjustsFontForContentSizeCategory = true
    stateLabel.textColor = .secondaryLabel
    stateLabel.textAlignment = .center
    stateLabel.numberOfLines = 2
    stateOverlay.addSubview(stateLabel)

    NSLayoutConstraint.activate([
      // pin to the frame layout guide — the overlay tracks the visible
      // area and never scrolls away with the (empty) content
      stateOverlay.centerXAnchor.constraint(equalTo: frameLayoutGuide.centerXAnchor),
      stateOverlay.centerYAnchor.constraint(equalTo: frameLayoutGuide.centerYAnchor),
      stateOverlay.widthAnchor.constraint(
        lessThanOrEqualTo: frameLayoutGuide.widthAnchor,
        constant: -32
      ),
      stateIcon.topAnchor.constraint(equalTo: stateOverlay.topAnchor),
      stateIcon.centerXAnchor.constraint(equalTo: stateOverlay.centerXAnchor),
      stateSpinner.topAnchor.constraint(equalTo: stateOverlay.topAnchor),
      stateSpinner.centerXAnchor.constraint(equalTo: stateOverlay.centerXAnchor),
      stateLabel.topAnchor.constraint(equalTo: stateIcon.bottomAnchor, constant: 8),
      stateLabel.leadingAnchor.constraint(equalTo: stateOverlay.leadingAnchor),
      stateLabel.trailingAnchor.constraint(equalTo: stateOverlay.trailingAnchor),
      stateLabel.bottomAnchor.constraint(equalTo: stateOverlay.bottomAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    reloadInsets()

    layer.mask = visibilityMask()
    layer.masksToBounds = true
  }

  private func visibilityMask() -> CAGradientLayer {
    let mask = CAGradientLayer()
    mask.frame = bounds
    mask.colors = [
      UIColor.white.withAlphaComponent(0).cgColor,
      UIColor.white.cgColor,
      UIColor.white.cgColor,
      UIColor.white.withAlphaComponent(0).cgColor,
    ]
    mask.locations = [0, 0.2, 0.8, 1]
    return mask
  }

  public func display(lyrics: StructuredLyrics, scrollAnimation: Bool) {
    isTrackerDriven = false
    wordTimedLines = nil
    self.lyrics = lyrics
    self.scrollAnimation = scrollAnimation
    setPaneState(.hidden)
    reloadViewModels()
  }

  /// G4 synced-lyrics path — the `SyncedLyricsTracker` owns position
  /// updates; call `updateActiveLine(_:wordIndex:)` for each published
  /// `LyricsTrackingUpdate` instead of `scroll(toTime:)`.
  public func display(syncedLyrics: SyncedLyrics, scrollAnimation: Bool) {
    isTrackerDriven = true
    wordTimedLines = syncedLyrics.lines
    self.lyrics = syncedLyrics.asStructuredLyrics
    self.scrollAnimation = scrollAnimation
    setPaneState(.hidden)
    reloadViewModels()
  }

  /// Tracker-driven position update — highlights `activeLine` (and the
  /// active word when the line has word timings) and auto-scrolls to it
  /// unless the user is currently browsing. `scrollAnimation` already
  /// folds in `isLyricsSmoothScrolling` + Reduce Motion at the call site.
  public func updateActiveLine(_ activeLine: ActiveLyricLine?, wordIndex: Int?) {
    guard isTrackerDriven, !lyricModels.isEmpty else { return }

    let isAutoScrollAllowed: Bool = {
      guard let suppressUntil = suppressAutoScrollUntil else { return true }
      return Date() >= suppressUntil
    }()

    let newIndex = activeLine?.index
    let isIndexChange = newIndex != lastIndex
    if isIndexChange {
      var toReconfigure = [IndexPath]()
      if let lastIndex, let oldModel = lyricModels.object(at: lastIndex) {
        oldModel.isActiveLine = false
        oldModel.activeWordIndex = nil
        toReconfigure.append(IndexPath(row: lastIndex, section: 0))
      }
      lastIndex = newIndex
      if let newIndex, let newModel = lyricModels.object(at: newIndex) {
        newModel.isActiveLine = true
        toReconfigure.append(IndexPath(row: newIndex, section: 0))
      }
      if !toReconfigure.isEmpty {
        reconfigureRows(at: toReconfigure)
      }
      hasLastLyricsLineAlreadyDisplayedOnce = (newIndex == lyricModels.count - 1)
    }
    if let newIndex, let newModel = lyricModels.object(at: newIndex),
       newModel.activeWordIndex != wordIndex {
      newModel.activeWordIndex = wordIndex
    }
    // scroll only on a real line change — the tracker ticks at ~10 Hz
    // and re-scrolling to the same row every tick is wasted work
    if isAutoScrollAllowed, isIndexChange, let newIndex {
      scrollToRow(
        at: IndexPath(row: newIndex, section: 0),
        at: .middle,
        animated: scrollAnimation
      )
    }
  }

  /// pane content state — `.loading` while a track's lyrics resolve,
  /// `.empty`/`.offlineEmpty` when no source produced lyrics
  public func setPaneState(_ state: LyricsPaneState) {
    switch state {
    case .hidden:
      stateOverlay.isHidden = true
      stateSpinner.stopAnimating()
    case .loading:
      stateOverlay.isHidden = false
      stateIcon.isHidden = true
      stateLabel.isHidden = false
      stateSpinner.isHidden = false
      stateSpinner.startAnimating()
      stateLabel.text = NSLocalizedString(
        "Loading lyrics…",
        comment: "Lyrics pane loading state"
      )
    case .empty:
      stateOverlay.isHidden = false
      stateIcon.isHidden = false
      stateLabel.isHidden = false
      stateSpinner.isHidden = true
      stateSpinner.stopAnimating()
      stateIcon.image = .lyrics
      stateLabel.text = NSLocalizedString(
        "No lyrics available for this song",
        comment: "Lyrics pane empty state"
      )
    case .offlineEmpty:
      stateOverlay.isHidden = false
      stateIcon.isHidden = false
      stateLabel.isHidden = false
      stateSpinner.isHidden = true
      stateSpinner.stopAnimating()
      stateIcon.image = .lyrics
      stateLabel.text = NSLocalizedString(
        "Offline — no cached lyrics for this song",
        comment: "Lyrics pane empty state while offline"
      )
    }
    // the overlay's label is the only accessible element in the cluster
    stateOverlay.accessibilityElementsHidden = stateOverlay.isHidden
  }

  public func highlightAllLyrics() {
    lyricModels.forEach { $0.isActiveLine = true }
  }

  public func clear() {
    lyrics = nil
    wordTimedLines = nil
    isTrackerDriven = false
    setPaneState(.hidden)
    reloadViewModels()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    // Dynamic Type — lyric fonts are UIFontMetrics-scaled, so a category
    // change rebuilds the attributed strings and the row heights
    if traitCollection.preferredContentSizeCategory != previousTraitCollection?
      .preferredContentSizeCategory {
      reloadViewModels()
    }
  }

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    lyricModels.count
  }

  public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    guard let model = lyricModels.object(at: indexPath.row) else { return 0.0 }
    return lineSpacing + model.calcHeight(containerWidth: bounds.width)
  }

  public func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    guard let model = lyricModels.object(at: indexPath.row) else { return 0.0 }
    return lineSpacing + model.calcHeight(containerWidth: bounds.width)
  }

  public func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = dequeueReusableCell(
      withIdentifier: LyricTableCell.typeName,
      for: indexPath
    ) as! LyricTableCell
    if let model = lyricModels.object(at: indexPath.row) {
      cell.display(model: model)
    }
    return cell
  }

  public func tableView(
    _ tableView: UITableView,
    shouldHighlightRowAt indexPath: IndexPath
  )
    -> Bool {
    guard lyrics?.synced == true,
          let model = lyricModels.object(at: indexPath.row),
          model.lyric?.start != nil
    else { return false }
    return true
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard lyrics?.synced == true,
          let model = lyricModels.object(at: indexPath.row),
          let lyric = model.lyric,
          lyric.start != nil
    else { return }
    suppressAutoScrollUntil = Date().addingTimeInterval(autoScrollSuppressionInterval)
    onLyricSelected?(lyric)
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    suppressAutoScrollUntil = Date().addingTimeInterval(autoScrollSuppressionInterval)
  }

  public func scrollViewDidEndDragging(
    _ scrollView: UIScrollView,
    willDecelerate decelerate: Bool
  ) {
    if !decelerate {
      suppressAutoScrollUntil = Date().addingTimeInterval(autoScrollSuppressionInterval)
    }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    suppressAutoScrollUntil = Date().addingTimeInterval(autoScrollSuppressionInterval)
  }

  private func reloadViewModels() {
    lyricModels.removeAll()
    lastIndex = nil
    hasLastLyricsLineAlreadyDisplayedOnce = false
    reloadInsets()

    guard let lyrics = lyrics else {
      reloadData()
      return
    }

    for (index, lyric) in lyrics.line.enumerated() {
      let model = LyricTableCellModel(
        lyric: lyric,
        syncedLine: wordTimedLines?.object(at: index),
        accentColor: accentColor
      )
      lyricModels.append(model)
    }
    reloadData()
  }

  func reloadInsets() {
    contentInset = UIEdgeInsets(
      top: frame.height / 2,
      left: 0,
      bottom: frame.height / 2,
      right: 0
    )
  }

  func scroll(toTime time: CMTime) {
    // tracker-driven panes position via `updateActiveLine` instead
    guard !isTrackerDriven else { return }
    guard let lyrics = lyrics,
          !lyricModels.isEmpty,
          lyrics.synced // if the lyrics are not synced -> only display
    else { return }

    let isAutoScrollAllowed: Bool = {
      guard let suppressUntil = suppressAutoScrollUntil else { return true }
      return Date() >= suppressUntil
    }()

    guard let indexOfNextLine = lyrics.line.firstIndex(where: { $0.startTime >= time }) else {
      if !hasLastLyricsLineAlreadyDisplayedOnce {
        if isAutoScrollAllowed {
          scrollToRow(
            at: IndexPath(row: lyricModels.count - 1, section: 0),
            at: .middle,
            animated: scrollAnimation
          )
          hasLastLyricsLineAlreadyDisplayedOnce = true
        }
      }
      if let lastIndex = lastIndex,
         let lastIndexModel = lyricModels.object(at: lastIndex) {
        lastIndexModel.isActiveLine = false
        reconfigureRows(at: [IndexPath(row: lastIndex, section: 0)])
      }
      lastIndex = nil
      return
    }

    var prevIndex: Int?
    hasLastLyricsLineAlreadyDisplayedOnce = false
    let indexOfCurrentLine = max(indexOfNextLine - 1, 0)
    if let lastIndex = lastIndex,
       let lastIndexModel = lyricModels.object(at: lastIndex) {
      lastIndexModel.isActiveLine = false
      prevIndex = lastIndex
    }
    lastIndex = indexOfCurrentLine
    let curIndexModel = lyricModels.object(at: indexOfCurrentLine)
    curIndexModel?.isActiveLine = true

    if prevIndex != indexOfCurrentLine {
      if curIndexModel != nil {
        reconfigureRows(at: [IndexPath(row: indexOfCurrentLine, section: 0)])
      }
      if let prevIndex = prevIndex, lyricModels.object(at: prevIndex) != nil {
        reconfigureRows(at: [IndexPath(row: prevIndex, section: 0)])
      }
    }
    if isAutoScrollAllowed {
      scrollToRow(
        at: IndexPath(row: indexOfCurrentLine, section: 0),
        at: .middle,
        animated: scrollAnimation
      )
    }
  }
}
