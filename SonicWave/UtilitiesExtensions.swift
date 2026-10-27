//
//  UtilitiesExtensions.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 06.06.22.
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
import Foundation
import MarqueeLabel
import os.log
import SwiftUI
import UIKit

extension MarqueeLabel {
  func applyAmperfyStyle() {
    if trailingBuffer != 30.0 {
      trailingBuffer = 30.0
    }
    if leadingBuffer != 0.0 {
      leadingBuffer = 0.0
    }
    if animationDelay != 2.0 {
      animationDelay = 2.0
    }
    if type != .continuous {
      type = .continuous
    }
    // Reduce Motion: freeze the scroll instead of animating forever
    holdScrolling = UIAccessibility.isReduceMotionEnabled
    speed = .rate(30.0)
    if fadeLength != 10.0 {
      fadeLength = 10.0
    }
  }
}

extension UIColor {
  static let hardLabelColor = UIColor(named: "hardLabelColor")
}

// MARK: - SonicWave design tokens (docs/design/design-system.md §2.2)

extension UIColor {
  /// §2.2 — scrim under controls overlaid on artwork
  static var sonicScrim: UIColor {
    UIColor(named: "ImageOverlayBackground") ?? .systemBackground.withAlphaComponent(0.6)
  }

  /// §2.2 — text/icons stamped over artwork where `.label` must stay maximal
  static var sonicHardLabel: UIColor {
    .hardLabelColor ?? .label
  }

  /// §2.2 — star rating gold
  static var sonicGold: UIColor {
    .gold
  }

  /// §2.1/§2.2 — per-account theme accent; read via the entity's account
  static func sonicAccent(for theme: ThemePreference) -> UIColor {
    theme.asColor
  }

  /// §2.3 — true-black palette: `.black` in dark mode while
  /// `BlackModePreference == .trueBlack`, `systemBackground` otherwise.
  /// Player-surface scope for now — the swap is applied where the token is
  /// consumed, not globally (no swizzling).
  @MainActor
  static func sonicSystemBackground(in traits: UITraitCollection) -> UIColor {
    let appDelegate = UIApplication.shared.delegate as! AppDelegate
    return appDelegate.isTrueBlackActive(in: traits) ? .black : .systemBackground
  }

  /// §2.3 — grouped-background counterpart of `sonicSystemBackground(in:)`
  @MainActor
  static func sonicSystemGroupedBackground(in traits: UITraitCollection) -> UIColor {
    let appDelegate = UIApplication.shared.delegate as! AppDelegate
    return appDelegate.isTrueBlackActive(in: traits) ? .black : .systemGroupedBackground
  }

  /// §2.3 — dynamic `systemBackground` counterpart for assignment points
  /// (cell and view backgrounds): resolves per trait change like the
  /// semantic colors, so light↔dark swaps keep working. The
  /// `.dark`→`.trueBlack` hop does not change `userInterfaceStyle`, so
  /// it only recolors once the surface re-renders — same opt-in caveat
  /// as the `in traits:` tokens.
  static var sonicSystemBackground: UIColor {
    UIColor(dynamicProvider: { traits in
      guard Thread.isMainThread else { return .systemBackground }
      return MainActor.assumeIsolated {
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        return appDelegate.isTrueBlackActive(in: traits) ? .black : .systemBackground
      }
    })
  }

  /// §2.3 — grouped-background counterpart of `sonicSystemBackground`
  static var sonicSystemGroupedBackground: UIColor {
    UIColor(dynamicProvider: { traits in
      guard Thread.isMainThread else { return .systemGroupedBackground }
      return MainActor.assumeIsolated {
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        return appDelegate.isTrueBlackActive(in: traits) ? .black : .systemGroupedBackground
      }
    })
  }
}

extension Color {
  static var sonicScrim: Color {
    Color("ImageOverlayBackground")
  }

  static var sonicHardLabel: Color {
    Color("hardLabelColor")
  }

  static var sonicGold: Color {
    Color(UIColor.gold)
  }

  static func sonicAccent(for theme: ThemePreference) -> Color {
    theme.asSwiftUIColor
  }

  static func sonicAccentContrast(for theme: ThemePreference) -> Color {
    Color(theme.contrastColor)
  }

  /// §2.3 — SwiftUI faces of the dynamic true-black tokens
  static var sonicSystemBackground: Color {
    Color(UIColor.sonicSystemBackground)
  }

  static var sonicSystemGroupedBackground: Color {
    Color(UIColor.sonicSystemGroupedBackground)
  }
}

// MARK: - WCAG contrast helpers (design-system §2.4, §8.3)

extension UIColor {
  /// WCAG 2.x relative luminance of this color (sRGB channel linearization)
  var sonicLuminance: CGFloat {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
    func linear(_ channel: CGFloat) -> CGFloat {
      channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG contrast ratio `self : other` — 1...21
  func sonicContrastRatio(to other: UIColor) -> CGFloat {
    let l1 = sonicLuminance
    let l2 = other.sonicLuminance
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  }

  /// §2.4 `sonicArtworkContrast` rule — pure black/white, whichever reaches
  /// the 4.5:1 metadata floor against `self`; `sonicHardLabel` fallback when
  /// neither does (it resolves to pure black/white per appearance anyway)
  var sonicContrastColor: UIColor {
    let blackRatio = UIColor.black.sonicContrastRatio(to: self)
    let whiteRatio = UIColor.white.sonicContrastRatio(to: self)
    let best = blackRatio >= whiteRatio ? UIColor.black : UIColor.white
    return max(blackRatio, whiteRatio) >= 4.5 ? best : .sonicHardLabel
  }

  /// HSL saturation/lightness accessor pair (via the kit's HSL `getHue`)
  var sonicSaturationLightness: (saturation: CGFloat, lightness: CGFloat) {
    var hue: CGFloat = 0, saturation: CGFloat = 0, lightness: CGFloat = 0, alpha: CGFloat = 0
    _ = getHue(&hue, saturation: &saturation, lightness: &lightness, alpha: &alpha)
    return (saturation, lightness)
  }

  /// §2.4 accent clamp — same hue/saturation, lightness forced into `range`
  func sonicWithLightnessClamped(to range: ClosedRange<CGFloat>) -> UIColor {
    let sl = sonicSaturationLightness
    return getWithLightness(of: min(max(sl.lightness, range.lowerBound), range.upperBound))
  }
}

// MARK: - Typography tokens (design-system §3.1)

extension UIFont {
  /// All tokens are `UIFontMetrics`-scaled; `regularWidthScale` preserves
  /// the widthClass-dependent size bump the player xibs encoded by hand
  /// (compact size × multiplier when the trait collection is regular width).
  private static func sonicScaled(
    _ style: UIFont.TextStyle,
    size: CGFloat,
    weight: UIFont.Weight = .regular,
    regularWidthScale: CGFloat = 1.0,
    traits: UITraitCollection? = nil
  )
    -> UIFont {
    var resolvedSize = size
    if let traits, traits.horizontalSizeClass == .regular {
      resolvedSize *= regularWidthScale
    }
    let base = UIFont.systemFont(ofSize: resolvedSize, weight: weight)
    if let traits {
      return UIFontMetrics(forTextStyle: style).scaledFont(
        for: base,
        compatibleWith: traits
      )
    }
    return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
  }

  /// Now Playing song title — title2 bold, xib bump 17 → 19 regular width
  static func sonicHeroTitle(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.title2, size: 17, weight: .bold, regularWidthScale: 19.0 / 17.0, traits: traits)
  }

  /// Now Playing album line — callout, xib bump 16 → 17 regular width
  static func sonicHeroSecondary(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.callout, size: 16, regularWidthScale: 17.0 / 16.0, traits: traits)
  }

  /// Now Playing artist line — body, 17pt
  static func sonicHeroArtist(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.body, size: 17, traits: traits)
  }

  /// Cell primary label — body
  static func sonicRowTitle(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.body, size: 17, traits: traits)
  }

  /// Cell secondary label — subheadline
  static func sonicRowSubtitle(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.subheadline, size: 15, traits: traits)
  }

  /// Mini-player title — caption1 semibold
  static func sonicMiniTitle(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.caption1, size: 11, weight: .semibold, traits: traits)
  }

  /// Mini-player subtitle — caption1
  static func sonicMiniSubtitle(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.caption1, size: 13, traits: traits)
  }

  /// Elapsed/remaining times — caption1, always tabular digits;
  /// xib bump 12 → 15 regular width
  static func sonicTime(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    var resolvedSize: CGFloat = 12
    if let traits, traits.horizontalSizeClass == .regular {
      resolvedSize = 15
    }
    let base = UIFont.monospacedDigitSystemFont(ofSize: resolvedSize, weight: .regular)
    if let traits {
      return UIFontMetrics(forTextStyle: .caption1).scaledFont(
        for: base,
        compatibleWith: traits
      )
    }
    return UIFontMetrics(forTextStyle: .caption1).scaledFont(for: base)
  }

  /// Codec/bitrate chip text — caption1, xib bump 12 → 15 regular width
  static func sonicAudioInfo(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.caption1, size: 12, regularWidthScale: 15.0 / 12.0, traits: traits)
  }

  /// Section headers ("Previous", "Next from Queue") — subheadline semibold
  static func sonicSectionHeader(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.subheadline, size: 15, weight: .semibold, traits: traits)
  }

  /// InfoBannerView / NotificationBanner — subheadline semibold
  static func sonicBanner(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    sonicScaled(.subheadline, size: 15, weight: .semibold, traits: traits)
  }
}

extension Color {
  static let error = Color.red
  static let success = Color.green

  // MARK: - Text Colors

  static let lightText = Color(UIColor.lightText)
  static let darkText = Color(UIColor.darkText)
  static let placeholderText = Color(UIColor.placeholderText)

  // MARK: - Label Colors

  static let label = Color(UIColor.label)
  static let secondaryLabel = Color(UIColor.secondaryLabel)
  static let tertiaryLabel = Color(UIColor.tertiaryLabel)
  static let quaternaryLabel = Color(UIColor.quaternaryLabel)

  // MARK: - Background Colors

  static let systemBackground = Color(UIColor.systemBackground)
  static let secondarySystemBackground = Color(UIColor.secondarySystemBackground)
  static let tertiarySystemBackground = Color(UIColor.tertiarySystemBackground)

  // MARK: - Fill Colors

  static let systemFill = Color(UIColor.systemFill)
  static let secondarySystemFill = Color(UIColor.secondarySystemFill)
  static let tertiarySystemFill = Color(UIColor.tertiarySystemFill)
  static let quaternarySystemFill = Color(UIColor.quaternarySystemFill)

  // MARK: - Grouped Background Colors

  static let systemGroupedBackground = Color(UIColor.systemGroupedBackground)
  static let secondarySystemGroupedBackground = Color(UIColor.secondarySystemGroupedBackground)
  static let tertiarySystemGroupedBackground = Color(UIColor.tertiarySystemGroupedBackground)

  // MARK: - Gray Colors

  static let systemGray = Color(UIColor.systemGray)
  static let systemGray2 = Color(UIColor.systemGray2)
  static let systemGray3 = Color(UIColor.systemGray3)
  static let systemGray4 = Color(UIColor.systemGray4)
  static let systemGray5 = Color(UIColor.systemGray5)
  static let systemGray6 = Color(UIColor.systemGray6)

  // MARK: - Other Colors

  static let separator = Color(UIColor.separator)
  static let opaqueSeparator = Color(UIColor.opaqueSeparator)
  static let link = Color(UIColor.link)

  // MARK: System Colors

  static let systemBlue = Color(UIColor.systemBlue)
  static let systemPurple = Color(UIColor.systemPurple)
  static let systemGreen = Color(UIColor.systemGreen)
  static let systemYellow = Color(UIColor.systemYellow)
  static let systemOrange = Color(UIColor.systemOrange)
  static let systemPink = Color(UIColor.systemPink)
  static let systemRed = Color(UIColor.systemRed)
  static let systemTeal = Color(UIColor.systemTeal)
  static let systemIndigo = Color(UIColor.systemIndigo)
}

public func withPopupAnimation<Result>(_ body: () throws -> Result) rethrows -> Result {
  try withAnimation(.easeInOut(duration: 0.2)) {
    try body()
  }
}

extension View {
  var appDelegate: AppDelegate {
    (UIApplication.shared.delegate as! AppDelegate)
  }
}

extension UIColor {
  static let slideOverBackgroundColor: UIColor = .systemBackground.withAlphaComponent(0.5)
  static let hoveredBackgroundColor: UIColor = .systemGray2.withAlphaComponent(0.2)
}

extension UIButton.Configuration {
  static func player(isSelected: Bool) -> UIButton.Configuration {
    var config = UIButton.Configuration.tinted()
    if isSelected {
      config.background.strokeColor = .label
      config.background.strokeWidth = 1.0
      config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
    }
    config.buttonSize = .small
    #if targetEnvironment(macCatalyst)
      config.baseForegroundColor = .label
      config.baseBackgroundColor = .clear
    #else
      config.baseForegroundColor = !isSelected ? .label : .systemBackground
      config.baseBackgroundColor = !isSelected ? .clear : .label
    #endif
    config.cornerStyle = .medium
    return config
  }

  static func playerRound() -> UIButton.Configuration {
    var config = UIButton.Configuration.gray()
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
    config.buttonSize = .small
    return config
  }
}

extension UIView {
  static let forceTouchClickLimit: Float = 1.0

  func normalizedForce(touches: Set<UITouch>) -> Float? {
    guard is3DTouchAvailable, let touch = touches.first else { return nil }
    let maximumForce = touch.maximumPossibleForce
    let force = touch.force
    let normalizedForce = (force / maximumForce)
    return Float(normalizedForce)
  }

  func isForceClicked(_ touches: Set<UITouch>) -> Bool {
    guard let force = normalizedForce(touches: touches) else { return false }
    if force < UIView.forceTouchClickLimit {
      return false
    } else {
      return true
    }
  }

  var is3DTouchAvailable: Bool {
    forceTouchCapability() == .available
  }

  func forceTouchCapability() -> UIForceTouchCapability {
    UIApplication.shared.mainWindow?.rootViewController?.traitCollection
      .forceTouchCapability ?? .unknown
  }

  public func setBackgroundBlur(style: UIBlurEffect.Style, alpha: CGFloat = 1.0) {
    backgroundColor = UIColor.clear
    let blurEffect = UIBlurEffect(style: style)
    let blurEffectView = UIVisualEffectView(effect: blurEffect)
    blurEffectView.alpha = alpha
    blurEffectView.frame = bounds
    blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    insertSubview(blurEffectView, at: 0)
  }

  func addLeftSideBorder() {
    let separator = UIView()
    separator.backgroundColor = .separator
    addSubview(separator)
    separator.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      separator.widthAnchor.constraint(equalToConstant: 1),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.topAnchor.constraint(equalTo: topAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func addTopSideBorder() {
    let separator = UIView()
    separator.backgroundColor = .separator
    addSubview(separator)
    separator.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      separator.heightAnchor.constraint(equalToConstant: 1),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.topAnchor.constraint(equalTo: topAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }
}

extension UINavigationController {
  func replaceCurrentlyActiveVC(with vc: UIViewController, animated: Bool) {
    var vcs = viewControllers
    vcs = vcs.dropLast()
    vcs.append(vc)
    setViewControllers(vcs, animated: animated)
  }
}

extension UITableView {
  func register(nibName: String) {
    register(UINib(nibName: nibName, bundle: nil), forCellReuseIdentifier: nibName)
  }

  func dequeueCell<CellType: UITableViewCell>(
    for tableView: UITableView,
    at indexPath: IndexPath
  )
    -> CellType {
    guard let cell = dequeueReusableCell(
      withIdentifier: CellType.typeName,
      for: indexPath
    ) as? CellType else {
      os_log(.error, "The dequeued cell is not an instance of %s", CellType.typeName)
      return CellType()
    }
    return cell
  }

  func hasRowAt(indexPath: IndexPath) -> Bool {
    indexPath.section < numberOfSections && indexPath
      .row < numberOfRows(inSection: indexPath.section)
  }
}

extension UICollectionView {
  func hasItemAt(indexPath: IndexPath) -> Bool {
    indexPath.section < numberOfSections && indexPath
      .row < numberOfItems(inSection: indexPath.section)
  }
}

@MainActor
extension UITableViewController {
  func dequeueCell<CellType: UITableViewCell>(
    for tableView: UITableView,
    at indexPath: IndexPath
  )
    -> CellType {
    self.tableView.dequeueCell(for: tableView, at: indexPath)
  }

  func refreshAllVisibleCells() {
    let visibleIndexPaths = tableView.visibleCells.compactMap { tableView.indexPath(for: $0) }
    tableView.reconfigureRows(at: visibleIndexPaths)
  }

  func exectueAfterAnimation(body: @escaping () -> ()) {
    Task { @MainActor in
      body()
    }
  }
}

extension UIViewController {
  var typeName: String {
    Self.typeName
  }
}

extension NSObject {
  @MainActor
  var appDelegate: AppDelegate {
    (UIApplication.shared.delegate as! AppDelegate)
  }
}

extension UIApplication {
  var mainWindow: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes
    for uiScene in scenes {
      if let windowScene = uiScene as? UIWindowScene {
        for window in windowScene.windows {
          if window.isKeyWindow {
            return window
          }
        }
      }
    }
    return nil
  }
}

extension UITraitCollection {
  static let maxDisplayScale = UITraitCollection(displayScale: 3.0)
}

extension UITableViewCell {
  func animateActivation() {
    UIView.animate(withDuration: 0.2, animations: {
      self.markAsFocused()
    }, completion: { _ in
      self.markAsFocused()
      UIView.animate(withDuration: 0.2, animations: {
        self.markAsUnfocused()
      }, completion: { _ in
        self.markAsUnfocused()
      })
    })
  }

  func markAsFocused() {
    backgroundColor = .systemGray4
  }

  func markAsUnfocused() {
    backgroundColor = .clear
  }
}

extension UICollectionViewCell {
  func animateActivation() {
    UIView.animate(withDuration: 0.2, animations: {
      self.markAsFocused()
    }, completion: { _ in
      self.markAsFocused()
      UIView.animate(withDuration: 0.2, animations: {
        self.markAsUnfocused()
      }, completion: { _ in
        self.markAsUnfocused()
      })
    })
  }

  func markAsFocused() {
    let focuseBackground = UIView(frame: bounds)
    focuseBackground.backgroundColor = .systemGray4
    backgroundView = focuseBackground
  }

  func markAsUnfocused() {
    backgroundView = nil
  }
}

extension UIMenu {
  /// rebuilds menu on every access
  static func lazyMenu(
    title: String = "",
    builder: @escaping () -> [UIMenuElement]
  )
    -> UIMenu {
    UIMenu(title: title, children: [
      UIDeferredMenuElement.uncached { completion in
        let actions = builder()
        completion(actions)
      },
    ])
  }
}

extension UIImage {
  func carPlayImage(carTraitCollection traits: UITraitCollection) -> UIImage {
    let imageAsset = UIImageAsset()
    imageAsset.register(self, with: traits)
    return imageAsset.image(with: traits)
  }
}

extension UIImage {
  /// dislike / thumbs-down (#587) — app-side symbols; the kit image
  /// table stays untouched. SF Symbols: `hand.thumbsdown[.fill]`
  static let thumbsDown = UIImage(systemName: "hand.thumbsdown") ?? UIImage()
  static let thumbsDownFill = UIImage(systemName: "hand.thumbsdown.fill") ?? UIImage()
}

extension UICollectionViewLayout {
  static var verticalLayout: UICollectionViewFlowLayout {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .vertical
    return layout
  }
}

extension UIDevice.BatteryState {
  public var description: String {
    switch self {
    case .unknown:
      return "unknown"
    case .unplugged:
      return "unplugged"
    case .charging:
      return "charging"
    case .full:
      return "full"
    @unknown default:
      return "@unknown default"
    }
  }
}

/// This fixes in swiftui mutliple picker views side by side to overlapp their touch areas
/// This is effective in addition to use .clipped() which only fixes the overlapping area visually
extension UIPickerView {
  open override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 150)
  }
}

extension Notification.Name {
  static let LibraryItemsChanged = Notification.Name("com.alzimerahmed.SonicWave.LibraryItemsChanged")
}

extension UIViewController {
  @objc
  var sceneTitle: String? { nil }

  func extendSafeAreaToAccountForMiniPlayer() {
    guard let hostVC = AppDelegate.mainWindowHostVC else { return }
    additionalSafeAreaInsets = UIEdgeInsets(
      top: 0,
      left: 0,
      bottom: hostVC.getSafeAreaExtension(),
      right: 0
    )
  }
}
