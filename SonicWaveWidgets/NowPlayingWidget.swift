//
//  NowPlayingWidget.swift
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

import SwiftUI
import WidgetKit

// MARK: - NowPlayingEntry

struct NowPlayingEntry: TimelineEntry {
  let date: Date
  let nowPlaying: WidgetNowPlaying?
}

// MARK: - NowPlayingTimelineProvider

/// Snapshot timeline — a single entry rebuilt whenever the app's
/// `WidgetStatePublisher` calls `reloadTimelines`; a slow `.after` policy
/// is only the safety net for a killed app.
struct NowPlayingTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> NowPlayingEntry {
    NowPlayingEntry(date: Date(), nowPlaying: .preview)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (NowPlayingEntry) -> Void
  ) {
    completion(entry())
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<NowPlayingEntry>) -> Void
  ) {
    let timeline = Timeline(
      entries: [entry()],
      policy: .after(Date().addingTimeInterval(30 * 60))
    )
    completion(timeline)
  }

  private func entry() -> NowPlayingEntry {
    NowPlayingEntry(
      date: Date(),
      nowPlaying: WidgetStore.readState()?.nowPlaying
    )
  }
}

// MARK: - NowPlayingWidget

struct NowPlayingWidget: Widget {
  private let kind = WidgetSharedConfig.kindNowPlaying

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: kind,
      provider: NowPlayingTimelineProvider()
    ) { entry in
      NowPlayingWidgetView(entry: entry)
        .containerBackground(for: .widget) {
          Color("WidgetBackground")
        }
    }
    .configurationDisplayName("Now Playing")
    .description("Current track with playback controls.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

// MARK: - NowPlayingWidgetView

struct NowPlayingWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: NowPlayingEntry

  private var themeColor: Color {
    WidgetTheme.color(name: entry.nowPlaying?.themeName)
  }

  var body: some View {
    Group {
      if let nowPlaying = entry.nowPlaying {
        switch family {
        case .systemSmall:
          smallLayout(nowPlaying)
        default:
          mediumLayout(nowPlaying)
        }
      } else {
        emptyLayout
      }
    }
    .widgetURL(URL(string: "\(WidgetSharedConfig.appURLScheme)://"))
  }

  // MARK: medium

  private func mediumLayout(_ nowPlaying: WidgetNowPlaying) -> some View {
    HStack(spacing: WidgetMetrics.cellGutter) {
      WidgetArtworkView(
        fileName: nowPlaying.artworkFileName,
        themeColor: themeColor
      )
      .frame(width: 56, height: 56)
      .accessibilityLabel("Artwork for \(nowPlaying.title)")

      VStack(alignment: .leading, spacing: 2) {
        Text(nowPlaying.title)
          .font(.headline)
          .lineLimit(1)
        Text(nowPlaying.metadataSubtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        progressLine(nowPlaying)
      }
      .layoutPriority(1)

      Spacer(minLength: 8)

      transportRow(nowPlaying)
    }
  }

  @ViewBuilder
  private func progressLine(_ nowPlaying: WidgetNowPlaying) -> some View {
    if nowPlaying.isRadio {
      Label(
        "LIVE",
        systemImage: "antenna.radiowaves.left.and.right"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 6) {
        if nowPlaying.isPlaying {
          // rate-aware anchored range — ticks locally, no reloads needed
          ProgressView(
            timerInterval: nowPlaying.progressTimerInterval,
            countsDown: false
          )
          .tint(themeColor)
        } else {
          ProgressView(value: nowPlaying.progressFraction(at: entry.date))
            .tint(themeColor)
        }
        if nowPlaying.isCached {
          Image(systemName: "arrow.down.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Downloaded")
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Playback progress")
      .accessibilityValue(
        nowPlaying.isPlaying ? "Playing" : "Paused"
      )
    }
  }

  private func transportRow(_ nowPlaying: WidgetNowPlaying) -> some View {
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
          systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill"
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
      .accessibilityLabel(nowPlaying.isPlaying ? "Pause" : "Play")

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

  // MARK: small

  private func smallLayout(_ nowPlaying: WidgetNowPlaying) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        WidgetArtworkView(
          fileName: nowPlaying.artworkFileName,
          themeColor: themeColor
        )
        .frame(width: 44, height: 44)
        .accessibilityLabel("Artwork for \(nowPlaying.title)")
        Spacer()
        Button(intent: TogglePlayPauseWidgetIntent()) {
          Image(
            systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill"
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
        .accessibilityLabel(nowPlaying.isPlaying ? "Pause" : "Play")
      }
      Text(nowPlaying.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      Text(nowPlaying.metadataSubtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  // MARK: empty

  private var emptyLayout: some View {
    VStack(spacing: 8) {
      WidgetArtworkView(fileName: nil, themeColor: themeColor)
        .frame(width: 44, height: 44)
      Text("No music playing")
        .font(.subheadline)
      if family == .systemMedium {
        Text("Open SonicWave to start playback")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("No music playing. Tap to open SonicWave.")
  }
}

// MARK: - preview fixture

extension WidgetNowPlaying {
  static let preview = WidgetNowPlaying(
    id: "preview",
    libraryElementType: .song,
    title: "Midnight Sun",
    artist: "Elena Fischer",
    album: "Northern Lights",
    artworkFileName: nil,
    isPlaying: true,
    isCached: true,
    contextName: "Favorites",
    elapsedAnchor: Date(),
    elapsedSeconds: 84,
    duration: 231,
    playbackRate: 1,
    themeName: "blue",
    updatedAt: Date()
  )
}
