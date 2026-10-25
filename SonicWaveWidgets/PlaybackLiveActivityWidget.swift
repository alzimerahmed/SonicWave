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
            .frame(width: 48, height: 48)
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
            Button(intent: TogglePlayPauseWidgetIntent()) {
              Image(
                systemName: context.state.isPlaying
                  ? "pause.fill" : "play.fill"
              )
              .font(.title2)
            }
            .buttonStyle(.plain)
            .tint(WidgetTheme.color(name: context.attributes.themeName))
            .accessibilityLabel(
              context.state.isPlaying ? "Pause" : "Play"
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
          .frame(width: 20, height: 20)
          .accessibilityHidden(true)
        } compactTrailing: {
          if context.state.isRadio {
            Text("LIVE")
              .font(.caption2.weight(.semibold).monospacedDigit())
          } else if context.state.isPlaying {
            Text(
              timerInterval: context.state.elapsedAnchor
                ... context.state.progressTimerInterval.upperBound,
              countsDown: true
            )
            .font(.caption2.monospacedDigit())
          } else {
            Text(context.state.remainingTimeDescription)
              .font(.caption2.monospacedDigit())
          }
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
        } else {
          ProgressView(
            value: context.state.duration > 0
              ? min(
                max(context.state.elapsedSeconds / context.state.duration, 0),
                1
              )
              : 0
          )
        }
        transport(context)
      }
      .accessibilityElement(children: .contain)
    }

    private func transport(
      _ context: ActivityViewContext<PlaybackActivityAttributes>
    ) -> some View {
      HStack(spacing: 8) {
        Button(intent: PreviousTrackWidgetIntent()) {
          Image(systemName: "backward.fill")
            .font(.body)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Previous track")
        Button(intent: NextTrackWidgetIntent()) {
          Image(systemName: "forward.fill")
            .font(.body)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next track")
      }
      .tint(WidgetTheme.color(name: context.attributes.themeName))
    }
  }

  // MARK: - PlaybackLockScreenView

  struct PlaybackLockScreenView: View {
    let context: ActivityViewContext<PlaybackActivityAttributes>

    private var themeColor: Color {
      WidgetTheme.color(name: context.attributes.themeName)
    }

    var body: some View {
      HStack(spacing: WidgetMetrics.cellGutter) {
        WidgetArtworkView(
          fileName: context.state.artworkFileName,
          themeColor: themeColor
        )
        .frame(width: 52, height: 52)
        .accessibilityLabel("Artwork for \(context.state.title)")

        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
          } else {
            ProgressView(
              value: context.state.duration > 0
                ? min(
                  max(
                    context.state.elapsedSeconds / context.state.duration,
                    0
                  ),
                  1
                )
                : 0
            )
            .tint(themeColor)
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
          .tint(themeColor)
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
          .tint(themeColor)
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
          .tint(themeColor)
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

  // MARK: - static remaining helper

  extension PlaybackActivityAttributes.ContentState {
    /// paused-state "m:ss" — `timerInterval:` views cover the playing case
    var remainingTimeDescription: String {
      let remaining = max(duration - elapsedSeconds, 0)
      let minutes = Int(remaining) / 60
      let seconds = Int(remaining) % 60
      return String(format: "%d:%02d", minutes, seconds)
    }
  }
#endif
