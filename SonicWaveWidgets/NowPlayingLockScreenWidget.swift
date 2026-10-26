//
//  NowPlayingLockScreenWidget.swift
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

// MARK: - NowPlayingLockScreenWidget

/// Lock-screen glanceables (G12) — same now-playing snapshot as the
/// home-screen widget: rectangular shows title/artist + progress,
/// circular shows a play/pause glyph inside a progress ring.
struct NowPlayingLockScreenWidget: Widget {
  private let kind = WidgetSharedConfig.kindLockScreenNowPlaying

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: kind,
      provider: NowPlayingTimelineProvider()
    ) { entry in
      NowPlayingLockScreenView(entry: entry)
        .containerBackground(for: .widget) {
          Color.clear
        }
    }
    .configurationDisplayName("Now Playing")
    .description("Current track on the Lock Screen.")
    .supportedFamilies([
      .accessoryRectangular,
      .accessoryCircular,
      .accessoryInline,
    ])
  }
}

// MARK: - NowPlayingLockScreenView

struct NowPlayingLockScreenView: View {
  @Environment(\.widgetFamily) private var family
  let entry: NowPlayingEntry

  var body: some View {
    Group {
      if let nowPlaying = entry.nowPlaying {
        switch family {
        case .accessoryCircular:
          circularLayout(nowPlaying)
        case .accessoryInline:
          inlineLayout(nowPlaying)
        default:
          rectangularLayout(nowPlaying)
        }
      } else {
        Image(systemName: "music.note")
          .accessibilityLabel("No music playing")
      }
    }
    .widgetURL(URL(string: "\(WidgetSharedConfig.appURLScheme)://"))
  }

  private func rectangularLayout(_ nowPlaying: WidgetNowPlaying) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Image(
          systemName: nowPlaying.isPlaying ? "play.fill" : "pause.fill"
        )
        Text(nowPlaying.title)
          .font(.headline)
          .lineLimit(1)
      }
      Text(nowPlaying.metadataSubtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if nowPlaying.isRadio {
        Label(
          "LIVE",
          systemImage: "antenna.radiowaves.left.and.right"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      } else if nowPlaying.isPlaying, nowPlaying.duration > 0 {
        ProgressView(
          timerInterval: nowPlaying.progressTimerInterval,
          countsDown: false
        )
      } else if nowPlaying.duration > 0 {
        ProgressView(value: nowPlaying.progressFraction(at: entry.date))
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(nowPlaying.title), \(nowPlaying.metadataSubtitle), "
        + (nowPlaying.isPlaying ? "playing" : "paused")
    )
  }

  private func inlineLayout(_ nowPlaying: WidgetNowPlaying) -> some View {
    Label(
      nowPlaying.title,
      systemImage: nowPlaying.isPlaying ? "play.fill" : "pause.fill"
    )
    .accessibilityLabel(
      nowPlaying.isPlaying
        ? "Playing \(nowPlaying.title)"
        : "Paused \(nowPlaying.title)"
    )
  }

  private func circularLayout(_ nowPlaying: WidgetNowPlaying) -> some View {
    Gauge(value: nowPlaying.progressFraction(at: entry.date)) {
      Image(
        systemName: nowPlaying.isPlaying ? "play.fill" : "pause.fill"
      )
    }
    .gaugeStyle(.accessoryCircular)
    .accessibilityLabel(
      nowPlaying.isPlaying
        ? "Playing \(nowPlaying.title)"
        : "Paused \(nowPlaying.title)"
    )
  }
}
