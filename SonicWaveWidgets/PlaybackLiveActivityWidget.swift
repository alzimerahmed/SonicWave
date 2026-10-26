//
//  PlaybackLiveActivityWidget.swift
//  SonicWaveWidgets
//
//  Created by Alzimer Ahmed on 25.10.26.
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

#if canImport(ActivityKit)

  import ActivityKit
  import SwiftUI
  import WidgetKit

  // MARK: - PlaybackLiveActivityWidget

  /// Live Activity (G13) — Lock Screen card + Dynamic Island. Progress
  /// runs on `Date`-anchored `ProgressView(timerInterval:)` /
  /// `Text(timerInterval:)` so the app only pushes updates on real state
  /// changes. Transport buttons reuse the same widget intents as the
  /// home-screen widgets — the command bridge handles app-alive vs.
  /// cold-open.
  struct PlaybackLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
      ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
        PlaybackLockScreenView(context: context)
          .activitySystemActionForegroundColor(
            WidgetTheme.color(name: context.attributes.themeName)
          )
      } dynamicIsland: { context in
        DynamicIsland {
          DynamicIslandExpandedRegion(.leading) {
            WidgetArtworkView(
              fileName: context.state.artworkFileName,
              themeColor: WidgetTheme.color(
                name: context.attributes.themeName
              )
            )
            .frame(
              width: WidgetMetrics.artworkIslandExpanded,
              height: WidgetMetrics.artworkIslandExpanded
            )
            .accessibilityLabel("Artwork for \(context.state.title)")
          }
          DynamicIslandExpandedRegion(.center) {
            VStack(alignment: .leading, spacing: 2) {
              Text(context.state.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
              Text(context.state.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          DynamicIslandExpandedRegion(.trailing) {
            LiveActivityTransportButton(
              intent: TogglePlayPauseWidgetIntent(),
              systemName: context.state.isPlaying
                ? "pause.fill" : "play.fill",
              label: context.state.isPlaying ? "Pause" : "Play",
              themeName: context.attributes.themeName,
              font: .title2
            )
          }
          DynamicIslandExpandedRegion(.bottom) {
            islandBottom(context)
          }
        } compactLeading: {
          WidgetArtworkView(
            fileName: context.state.artworkFileName,
            themeColor: WidgetTheme.color(name: context.attributes.themeName)
          )
          .frame(
            width: WidgetMetrics.artworkIslandCompact,
            height: WidgetMetrics.artworkIslandCompact
          )
          .accessibilityHidden(true)
        } compactTrailing: {
          Group {
            if context.state.isRadio {
              Text("LIVE")
                .font(.caption2.weight(.semibold).monospacedDigit())
            } else if context.state.isPlaying {
              Text(
                timerInterval: context.state.remainingTimerInterval,
                countsDown: true
              )
              .font(.caption2.monospacedDigit())
            } else {
              Text(context.state.remainingTimeDescription)
                .font(.caption2.monospacedDigit())
            }
          }
          // the compact regions carry no track context on their own —
          // a bare countdown reads as noise to VoiceOver
          .accessibilityLabel(compactTrailingLabel(context))
        } minimal: {
          Image(
            systemName: context.state.isPlaying ? "play.fill" : "pause.fill"
          )
          .accessibilityLabel(
            context.state.isPlaying
              ? "Playing \(context.state.title)"
              : "Paused \(context.state.title)"
          )
        }
      }
    }

    @ViewBuilder
    private func islandBottom(
      _ context: ActivityViewContext<PlaybackActivityAttributes>
    ) -> some View {
      HStack(spacing: WidgetMetrics.cellGutter) {
        if context.state.isRadio {
          Label(
            "LIVE",
            systemImage: "antenna.radiowaves.left.and.right"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else if context.state.isPlaying {
          ProgressView(
            timerInterval: context.state.progressTimerInterval,
            countsDown: false
          )
          .accessibilityLabel("Playback progress")
          .accessibilityValue(
            context.state.progressAccessibilityValue(at: Date())
          )
        } else {
          ProgressView(
            value: context.state.progressFraction(at: Date())
          )
          .accessibilityLabel("Playback progress")
          .accessibilityValue(
            context.state.progressAccessibilityValue(at: Date())
          )
        }
        transport(context)
      }
      .accessibilityElement(children: .contain)
    }

    private func compactTrailingLabel(
      _ context: ActivityViewContext<PlaybackActivityAttributes>
    ) -> String {
      if context.state.isRadio {
        return String(localized: "\(context.state.title), live")
      }
      return String(
        localized: "\(context.state.title), \(context.state.remainingTimeDescription) remaining"
      )
    }

    private func transport(
      _ context: ActivityViewContext<PlaybackActivityAttributes>
    ) -> some View {
      HStack(spacing: 8) {
        LiveActivityTransportButton(
          intent: PreviousTrackWidgetIntent(),
          systemName: "backward.fill",
          label: "Previous track",
          themeName: context.attributes.themeName,
          font: .body,
          enforceTapTarget: true
        )
        LiveActivityTransportButton(
          intent: NextTrackWidgetIntent(),
          systemName: "forward.fill",
          label: "Next track",
          themeName: context.attributes.themeName,
          font: .body,
          enforceTapTarget: true
        )
      }
    }
  }

  // MARK: - LiveActivityTransportButton

  /// Icon-only transport button. Owns its `colorScheme` lookup — the
  /// raw theme accents fail the 3:1 non-text contrast bar on light
  /// surfaces, so interactive glyphs fall back to `.primary` there
  /// (`WidgetTheme.interactiveColor`).
  private struct LiveActivityTransportButton<I: AppIntent>: View {
    @Environment(\.colorScheme) private var colorScheme
    let intent: I
    let systemName: String
    let label: String
    let themeName: String
    let font: Font
    var enforceTapTarget = false

    var body: some View {
      Button(intent: intent) {
        Image(systemName: systemName)
          .font(font)
          .frame(
            width: enforceTapTarget ? WidgetMetrics.transportTarget : nil,
            height: enforceTapTarget ? WidgetMetrics.transportTarget : nil
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .tint(
        WidgetTheme.interactiveColor(name: themeName, for: colorScheme)
      )
      .accessibilityLabel(label)
    }
  }

  // MARK: - PlaybackLockScreenView

  struct PlaybackLockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme
    let context: ActivityViewContext<PlaybackActivityAttributes>

    private var themeColor: Color {
      WidgetTheme.color(name: context.attributes.themeName)
    }

    /// contrast-safe tint for the icon-only transport glyphs — the raw
    /// theme color fails 3:1 on the light Lock Screen background
    private var transportColor: Color {
      WidgetTheme.interactiveColor(
        name: context.attributes.themeName,
        for: colorScheme
      )
    }

    var body: some View {
      HStack(spacing: WidgetMetrics.cellGutter) {
        WidgetArtworkView(
          fileName: context.state.artworkFileName,
          themeColor: themeColor
        )
        .frame(
          width: WidgetMetrics.artworkLockScreen,
          height: WidgetMetrics.artworkLockScreen
        )
        .accessibilityLabel("Artwork for \(context.state.title)")

        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          HStack(spacing: 6) {
            if context.state.isRadio {
              Label(
                "LIVE",
                systemImage: "antenna.radiowaves.left.and.right"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            } else if context.state.isPlaying {
              ProgressView(
                timerInterval: context.state.progressTimerInterval,
                countsDown: false
              )
              .tint(themeColor)
              .accessibilityLabel("Playback progress")
              .accessibilityValue(
                context.state.progressAccessibilityValue(at: Date())
              )
            } else {
              ProgressView(
                value: context.state.progressFraction(at: Date())
              )
              .tint(themeColor)
              .accessibilityLabel("Playback progress")
              .accessibilityValue(
                context.state.progressAccessibilityValue(at: Date())
              )
            }
            // matches the Now Playing widget's downloaded badge so the
            // `isCached` state isn't a write-only field
            if context.state.isCached {
              Image(systemName: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
            }
          }
        }
        .layoutPriority(1)

        Spacer(minLength: 8)

        HStack(spacing: 4) {
          Button(intent: PreviousTrackWidgetIntent()) {
            Image(systemName: "backward.fill")
              .font(.title3)
              .frame(
                width: WidgetMetrics.transportTarget,
                height: WidgetMetrics.transportTarget
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .tint(transportColor)
          .accessibilityLabel("Previous track")

          Button(intent: TogglePlayPauseWidgetIntent()) {
            Image(
              systemName: context.state.isPlaying
                ? "pause.fill" : "play.fill"
            )
            .font(.title2)
            .frame(
              width: WidgetMetrics.transportTarget,
              height: WidgetMetrics.transportTarget
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .tint(transportColor)
          .accessibilityLabel(context.state.isPlaying ? "Pause" : "Play")

          Button(intent: NextTrackWidgetIntent()) {
            Image(systemName: "forward.fill")
              .font(.title3)
              .frame(
                width: WidgetMetrics.transportTarget,
                height: WidgetMetrics.transportTarget
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .tint(transportColor)
          .accessibilityLabel("Next track")
        }
      }
      .padding(.horizontal, 4)
    }

    private var subtitle: String {
      let parts = [context.state.artist, context.state.album]
        .filter { !$0.isEmpty }
      if !parts.isEmpty {
        return parts.joined(separator: " — ")
      }
      return context.attributes.contextName
    }
  }
#endif
