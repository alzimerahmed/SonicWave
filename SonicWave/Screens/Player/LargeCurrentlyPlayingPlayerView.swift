//
//  LargeCurrentlyPlayingPlayerView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 07.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import MarqueeLabel
import MediaPlayer
import UIKit

import SwiftUI

// MARK: - LargeDisplayElement

enum LargeDisplayElement {
  case artwork
  case lyrics
  case visualizer
}

// MARK: - AudioAnalyzerView

struct AudioAnalyzerView: View {
  @EnvironmentObject
  var audioAnalyzer: AudioAnalyzer
  let visualizerType: VisualizerType

  var body: some View {
    Group {
      switch visualizerType {
      case .waveform:
        WaveformView(
          magnitudes: audioAnalyzer.magnitudes,
          rms: audioAnalyzer.rms
        )
      case .spectrumBars:
        SpectrumBarsView(
          magnitudes: audioAnalyzer.magnitudes,
          barCount: 32
        )
      case .generativeArt:
        GenerativeArtView(
          magnitudes: audioAnalyzer.magnitudes,
          rms: audioAnalyzer.rms
        )
      case .ring:
        AmplitudeSpectrumView(
          shapeType: .ring,
          magnitudes: audioAnalyzer.magnitudes,
          range: 0 ..< 75,
          rms: audioAnalyzer.rms
        )
      }
    }
    .padding()
  }
}

// MARK: - AudioAnalyzerWrapperView

struct AudioAnalyzerWrapperView: View {
  let visualizerType: VisualizerType

  var body: some View {
    VStack {
      AudioAnalyzerView(visualizerType: visualizerType)
        .environmentObject(appDelegate.player.audioAnalyzer)
    }
  }
}

// MARK: - SwiftUIContentView

class SwiftUIContentView: UIView {
  var hostingController: UIHostingController<AudioAnalyzerWrapperView>?

  public func setupSwiftUIView(
    parentVC: UIViewController,
    parentView: UIView,
    visualizerType: VisualizerType
  ) {
    let swiftUIView = AudioAnalyzerWrapperView(visualizerType: visualizerType)
    let hostingController = UIHostingController(rootView: swiftUIView)
    self.hostingController = hostingController

    parentVC.addChild(hostingController)
    parentView.addSubview(hostingController.view)

    hostingController.view.frame = parentView.frame
    hostingController.view.backgroundColor = .clear

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.didMove(toParent: parentVC)
  }

  public func updateVisualizerType(_ visualizerType: VisualizerType) {
    hostingController?.rootView = AudioAnalyzerWrapperView(visualizerType: visualizerType)
  }
}

// MARK: - LargeCurrentlyPlayingPlayerView

class LargeCurrentlyPlayingPlayerView: UIView, UIGestureRecognizerDelegate {
  static let rowHeight: CGFloat = 94.0
  static private let margin = UIEdgeInsets(
    top: 0,
    left: UIView.defaultMarginX,
    bottom: 20,
    right: UIView.defaultMarginX
  )

  private var rootView: PopupPlayerVC?
  private var lyricsView: LyricsView?
  private var visualizerHostingView: SwiftUIContentView?
  private var displayElement: LargeDisplayElement = .artwork
  private var ratingView: RatingView?
  private var albumPlaythroughView: AlbumPlaythroughView?
  private var isSubscribedToLyricsTracker = false
  private var lyricsResolveTask: Task<Void, Never>?
  /// last lyrics payload handed to the pane — the tracker republishes on
  /// every tick, so rebuilds are gated on `Equatable` change
  private var shownLyrics: SyncedLyrics?

  @IBOutlet
  weak var upperContainerView: UIView!
  @IBOutlet
  weak var artworkImage: LibraryEntityImage!
  @IBOutlet
  weak var detailsContainer: UIView!
  @IBOutlet
  weak var titleLabel: MarqueeLabel!
  @IBOutlet
  weak var albumLabel: MarqueeLabel!
  @IBOutlet
  weak var albumButton: UIButton!
  @IBOutlet
  weak var albumContainerView: UIView!
  @IBOutlet
  weak var artistLabel: MarqueeLabel!
  @IBOutlet
  weak var favoriteButton: UIButton!
  @IBOutlet
  weak var optionsButton: UIButton!

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Force a layout to prevent wrong size on first appearance on macOS
    upperContainerView.layoutIfNeeded()

    lyricsView?.frame = upperContainerView.bounds
    visualizerHostingView?.hostingController?.view.frame = upperContainerView.bounds
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView
    titleLabel.applyAmperfyStyle()
    albumLabel.applyAmperfyStyle()
    artistLabel.applyAmperfyStyle()
    applyHeroFonts()

    lyricsView = LyricsView()
    lyricsView!.frame = upperContainerView.bounds
    lyricsView!.onLyricSelected = { [weak self] lyric in
      self?.appDelegate.player.seek(toSecond: lyric.startTime.seconds)
      // the 0.1s tracker tick only runs during playback — nudge the
      // active line so a seek while paused lands on the right line
      AmperKit.shared.syncedLyricsTracker.updatePlaybackPosition(
        seconds: lyric.startTime.seconds
      )
    }
    let lyricsTap = UITapGestureRecognizer(target: self, action: #selector(handleLyricsTap(_:)))
    lyricsTap.cancelsTouchesInView = false
    lyricsTap.delegate = self
    lyricsView!.addGestureRecognizer(lyricsTap)
    // §5.4 pane model — a horizontal swipe on the lyrics pane returns to
    // the Now Playing artwork (the table only consumes vertical pans)
    let lyricsSwipeBack = UISwipeGestureRecognizer(
      target: self,
      action: #selector(handleLyricsSwipeBack(_:))
    )
    lyricsSwipeBack.direction = .right
    lyricsView!.addGestureRecognizer(lyricsSwipeBack)
    upperContainerView.addSubview(lyricsView!)

    visualizerHostingView = SwiftUIContentView()
    visualizerHostingView!.hostingController?.view.frame = upperContainerView.bounds
    if let toWorkOnRootView {
      visualizerHostingView!.setupSwiftUIView(
        parentVC: toWorkOnRootView,
        parentView: self,
        visualizerType: appDelegate.storage.settings.user.selectedVisualizerType
      )
    }

    setupRatingView()
    setupAlbumPlaythroughView()
    addSwipeGesturesToArtwork()
    addPaneSwipeGestures()

    appDelegate.notificationHandler.register(
      self,
      selector: #selector(refreshOfflineMode),
      name: .offlineModeChanged,
      object: nil
    )

    displayElement = getDisplayElementBasedOnConfig()
    refresh()
  }

  @objc
  private func refreshOfflineMode() {
    refreshRating()
  }

  private func setupRatingView() {
    ratingView = RatingView()
    ratingView!.translatesAutoresizingMaskIntoConstraints = false
    ratingView!.delegate = self
    ratingView!.isUserInteractionEnabled = true
    // Add directly to self and position between artwork and details
    addSubview(ratingView!)

    // Center vertically between artwork bottom and details top using a UILayoutGuide
    let spacerGuide = UILayoutGuide()
    addLayoutGuide(spacerGuide)

    NSLayoutConstraint.activate([
      // Spacer fills the gap between artwork and details
      spacerGuide.topAnchor.constraint(equalTo: artworkImage.bottomAnchor),
      spacerGuide.bottomAnchor.constraint(equalTo: detailsContainer.topAnchor),
      // Center rating view in the spacer
      ratingView!.centerXAnchor.constraint(equalTo: centerXAnchor),
      ratingView!.centerYAnchor.constraint(equalTo: spacerGuide.centerYAnchor),
      ratingView!.heightAnchor.constraint(equalToConstant: 36),
      ratingView!.widthAnchor.constraint(equalToConstant: 180),
    ])
  }

  @objc
  private func handleLyricsTap(_ gesture: UITapGestureRecognizer) {
    // Toggle back to artwork when lyrics are tapped
    rootView?.show(pane: .nowPlaying)
  }

  @objc
  private func handleLyricsSwipeBack(_ gesture: UISwipeGestureRecognizer) {
    rootView?.show(pane: .nowPlaying)
  }

  /// G21 — thin `Track X of Y` indicator slotted under the details block
  /// of the vertical stack (collapses when no album context plays)
  private func setupAlbumPlaythroughView() {
    guard let stackView = detailsContainer.superview as? UIStackView,
          let detailsIndex = stackView.arrangedSubviews.firstIndex(of: detailsContainer)
    else { return }
    let progressView = AlbumPlaythroughView()
    stackView.insertArrangedSubview(progressView, at: detailsIndex + 1)
    albumPlaythroughView = progressView
    refreshAlbumPlaythrough()
  }

  func refreshAlbumPlaythrough() {
    let info = rootView?.currentAlbumPlaythrough()
    let tint: UIColor? = rootView?.artworkTint.intensity == .vivid
      ? rootView?.artworkTint.accent
      : nil
    albumPlaythroughView?.display(info: info, tint: tint)
  }

  /// §5.4 — horizontal swipe on the metadata block moves between the
  /// Now Playing and Lyrics panes (artwork keeps its track-skip swipes).
  private func addPaneSwipeGestures() {
    let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handlePaneSwipe(_:)))
    swipeLeft.direction = .left
    let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handlePaneSwipe(_:)))
    swipeRight.direction = .right
    detailsContainer.addGestureRecognizer(swipeLeft)
    detailsContainer.addGestureRecognizer(swipeRight)
  }

  @objc
  private func handlePaneSwipe(_ gesture: UISwipeGestureRecognizer) {
    switch gesture.direction {
    case .left:
      rootView?.show(pane: .lyrics)
    case .right:
      rootView?.show(pane: .nowPlaying)
    default:
      break
    }
  }

  /// §3.1 — hero typography tokens replace the xib's hand-encoded
  /// widthClass font bumps; re-applied on every refresh so trait changes
  /// (regular width on iPad/Catalyst, Dynamic Type) re-scale them
  private func applyHeroFonts() {
    titleLabel.font = .sonicHeroTitle(compatibleWith: traitCollection)
    albumLabel.font = .sonicHeroSecondary(compatibleWith: traitCollection)
    artistLabel.font = .sonicHeroArtist(compatibleWith: traitCollection)
    titleLabel.adjustsFontForContentSizeCategory = true
    albumLabel.adjustsFontForContentSizeCategory = true
    artistLabel.adjustsFontForContentSizeCategory = true
  }

  /// §2.4 — pushes the resolved `sonicArtwork*` palette onto the hero
  /// surface: metadata text takes the ≥4.5:1 contrast color, the active
  /// lyric word and album progress take the accent in vivid mode.
  func applyArtworkTint(_ palette: ArtworkTintPalette) {
    let labelColor: UIColor = palette.isArtworkTinted ? palette.contrast : .label
    titleLabel.textColor = labelColor
    albumLabel.textColor = labelColor
    artistLabel.textColor = labelColor
    lyricsView?.accentColor = palette.intensity == .vivid ? palette.accent : .label
    refreshAlbumPlaythrough()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool {
    guard let lyricsView = lyricsView,
          gestureRecognizer is UITapGestureRecognizer
    else { return true }
    let location = touch.location(in: lyricsView)
    return lyricsView.indexPathForRow(at: location) == nil
  }

  private func addSwipeGesturesToArtwork() {
    func createLeftSwipe() -> UISwipeGestureRecognizer {
      let swipeLeft = UISwipeGestureRecognizer(
        target: self,
        action: #selector(handleSwipe(_:))
      )
      swipeLeft.direction = .left
      return swipeLeft
    }

    func createRightSwipe() -> UISwipeGestureRecognizer {
      let swipeRight = UISwipeGestureRecognizer(
        target: self,
        action: #selector(handleSwipe(_:))
      )
      swipeRight.direction = .right
      return swipeRight
    }

    artworkImage.isUserInteractionEnabled = true
    artworkImage.addGestureRecognizer(createLeftSwipe())
    artworkImage.addGestureRecognizer(createRightSwipe())
    visualizerHostingView?.hostingController?.view.isUserInteractionEnabled = true
    visualizerHostingView?.hostingController?.view.addGestureRecognizer(createRightSwipe())
    visualizerHostingView?.hostingController?.view.addGestureRecognizer(createLeftSwipe())
  }

  @objc
  private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
    switch gesture.direction {
    case .left:
      rootView?.controlView?.nextButtonPushed(self)
    case .right:
      rootView?.controlView?.previousButtonPushed(self)
    default:
      break
    }
  }

  func refreshLyricsTime(time: CMTime) {
    // legacy path only — tracker-driven panes ignore this tick
    lyricsView?.scroll(toTime: time)
  }

  /// G4 — the pane renders `SyncedLyricsTracker` output (multi-source:
  /// Subsonic structured lyrics, Ampache plain, embedded USLT, `.lrc`
  /// sidecars, LRCLIB). Subscribing to `.syncedLyricsUpdate` matches the
  /// house notification pattern; the tracker lazily registers itself as
  /// a `MusicPlayable` notifier on first access.
  func initializeLyrics() {
    guard isLyricsViewAllowedToDisplay else {
      hideLyrics()
      return
    }
    subscribeToLyricsTrackerIfNeeded()
    applyLyricsUpdate(AmperKit.shared.syncedLyricsTracker.update)
  }

  private func subscribeToLyricsTrackerIfNeeded() {
    guard !isSubscribedToLyricsTracker else { return }
    isSubscribedToLyricsTracker = true
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(syncedLyricsUpdated(notification:)),
      name: .syncedLyricsUpdate,
      object: AmperKit.shared.syncedLyricsTracker
    )
  }

  @objc
  private func syncedLyricsUpdated(notification: Notification) {
    guard let tracker = notification.object as? SyncedLyricsTracker else { return }
    applyLyricsUpdate(tracker.update)
  }

  private func applyLyricsUpdate(_ update: LyricsTrackingUpdate) {
    guard isLyricsViewAllowedToDisplay else {
      hideLyrics()
      return
    }
    lyricsResolveTask?.cancel()
    switch update.result {
    case .synced(let syncedLyrics):
      // the tracker republishes on every 0.1s tick — only rebuild the
      // table when the lyrics payload actually changed
      if shownLyrics != syncedLyrics {
        shownLyrics = syncedLyrics
        lyricsView?.display(
          syncedLyrics: syncedLyrics,
          scrollAnimation: SonicMotion.isLyricsSmoothScrollingAllowed
        )
        lyricsView?.isHidden = false
      }
      lyricsView?.updateActiveLine(update.activeLine, wordIndex: update.activeWordIndex)
    case .plain(let syncedLyrics):
      if shownLyrics != syncedLyrics {
        shownLyrics = syncedLyrics
        lyricsView?.display(
          lyrics: syncedLyrics.asStructuredLyrics,
          scrollAnimation: SonicMotion.isLyricsSmoothScrollingAllowed
        )
        lyricsView?.isHidden = false
      }
    case .none:
      // `.none` covers both "still resolving" and "no source produced
      // lyrics" — show the loading state, then fall through to the
      // elegant empty state once the grace period elapses
      if appDelegate.player.currentlyPlaying == nil {
        lyricsView?.clear()
        lyricsView?.setPaneState(.hidden)
        return
      }
      lyricsView?.clear()
      lyricsView?.setPaneState(.loading)
      lyricsView?.isHidden = false
      lyricsResolveTask = Task { @MainActor [weak self] in
        try? await Task.sleep(
          nanoseconds: UInt64(SonicMotion.lyricsResolveGracePeriod * 1_000_000_000)
        )
        guard !Task.isCancelled, let self else { return }
        guard AmperKit.shared.syncedLyricsTracker.update.result == .none else { return }
        self.lyricsView?.setPaneState(
          self.appDelegate.storage.settings.user.isOfflineMode ? .offlineEmpty : .empty
        )
      }
    }
  }

  /// G4 widened the lyrics gate — the multi-source manager resolves
  /// lyrics for every backend (not just Subsonic); a missing result
  /// surfaces as the pane's empty state instead of a hidden feature.
  var isLyricsViewAllowedToDisplay: Bool {
    displayElement == .lyrics &&
      appDelegate.player.playerMode == .music
  }

  var isLyricsButtonAllowedToDisplay: Bool {
    appDelegate.player.playerMode == .music
  }

  public func getDisplayElementBasedOnConfig() -> LargeDisplayElement {
    if appDelegate.storage.settings.user.isPlayerLyricsDisplayed {
      return .lyrics
    } else if appDelegate.storage.settings.user.isPlayerVisualizerDisplayed {
      return .visualizer
    } else {
      return .artwork
    }
  }

  public func display(element: LargeDisplayElement) {
    displayElement = element

    switch element {
    case .artwork:
      hideVisualizer()
      hideLyrics()
      showArtwork()
    case .lyrics:
      hideVisualizer()
      almostHideArtwork()
      initializeLyrics()
    case .visualizer:
      hideLyrics()
      almostHideArtwork()
      showVisualizer()
    }
  }

  public func almostHideArtwork() {
    artworkImage.alpha = 0.1
  }

  public func showArtwork() {
    artworkImage.alpha = 1
  }

  public func hideVisualizer() {
    visualizerHostingView?.hostingController?.view.isHidden = true
    // the analyzer tap is shared with `MusicHapticsService` — while the
    // service is engaged it owns the tap, so hiding the visualizer pane
    // must not cut the haptics feed (kit-side service self-gates)
    guard !(AmperKit.shared.musicHapticsService?.isEngaged ?? false) else { return }
    appDelegate.player.audioAnalyzer.isActive = false
  }

  public func showVisualizer() {
    visualizerHostingView?.updateVisualizerType(
      appDelegate.storage.settings.user.selectedVisualizerType
    )
    visualizerHostingView?.hostingController?.view.isHidden = false
    appDelegate.player.audioAnalyzer
      .isActive = (appDelegate.storage.settings.user.playerDisplayStyle == .large)
  }

  private func hideLyrics() {
    lyricsResolveTask?.cancel()
    shownLyrics = nil
    lyricsView?.clear()
    lyricsView?.isHidden = true
  }

  func refresh() {
    applyHeroFonts()
    refreshAlbumPlaythrough()
    rootView?.playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: artistLabel,
      albumLabel: albumLabel,
      albumButton: albumButton,
      albumContainerView: albumContainerView
    )
    rootView?.refreshFavoriteButton(button: favoriteButton)
    rootView?.refreshOptionButton(button: optionsButton, rootView: rootView)
    refreshRating()
    display(element: displayElement)
  }

  func refreshRating() {
    guard appDelegate.storage.settings.user.isShowRating,
          let song = rootView?.player.currentlyPlaying?.asSong else {
      ratingView?.setRating(0, animated: false)
      ratingView?.isHidden = true
      return
    }
    // Keep rating hidden when lyrics are displayed
    ratingView?.isHidden = (displayElement == .lyrics)
    ratingView?.setRating(song.rating, animated: false)

    // Disable rating interaction when offline (display only with reduced opacity)
    ratingView?.isRatingEnabled = !appDelegate.storage.settings.user.isOfflineMode
  }

  func refreshArtwork() {
    rootView?.playerHandler?.refreshArtwork(artworkImage: artworkImage)
  }

  @IBAction
  func artworkPressed(_ sender: Any) {
    rootView?.controlView?.displayPlaylistPressed()
  }

  @IBAction
  func titlePressed(_ sender: Any) {
    rootView?.displayAlbumDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func albumPressed(_ sender: Any) {
    rootView?.displayAlbumDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func artistNamePressed(_ sender: Any) {
    rootView?.displayArtistDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func favoritePressed(_ sender: Any) {
    rootView?.favoritePressed()
    rootView?.refreshFavoriteButton(button: favoriteButton)
  }
}

// MARK: RatingViewDelegate

extension LargeCurrentlyPlayingPlayerView: RatingViewDelegate {
  func ratingView(_ ratingView: RatingView, didChangeRating rating: Int) {
    guard let song = rootView?.player.currentlyPlaying?.asSong,
          let account = song.account
    else { return }

    // Update local rating immediately for responsive UI
    song.rating = rating

    // Sync rating to server
    Task {
      do {
        try await appDelegate.getMeta(account.info).librarySyncer.setRating(
          song: song,
          rating: rating
        )
      } catch {
        appDelegate.eventLogger.report(topic: "Song Rating", error: error)
      }
    }
  }
}
