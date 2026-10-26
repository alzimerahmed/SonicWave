//
//  RecentlyPlayedWidget.swift
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

// MARK: - RecentlyPlayedEntry

struct RecentlyPlayedEntry: TimelineEntry {
  let date: Date
  let items: [WidgetRecentItem]
  let themeName: String?
}

// MARK: - RecentlyPlayedTimelineProvider

struct RecentlyPlayedTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> RecentlyPlayedEntry {
    RecentlyPlayedEntry(
      date: Date(),
      items: [
        WidgetRecentItem(
          id: "1",
          libraryElementType: .song,
          title: "Midnight Sun",
          artist: "Elena Fischer",
          artworkFileName: nil
        ),
        WidgetRecentItem(
          id: "2",
          libraryElementType: .podcastEpisode,
          title: "Episode 42: Deep Dive",
          artist: "Sonic Podcast",
          artworkFileName: nil
        ),
      ],
      themeName: "blue"
    )
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (RecentlyPlayedEntry) -> Void
  ) {
    completion(entry())
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void
  ) {
    let timeline = Timeline(
      entries: [entry()],
      policy: .after(
        Date().addingTimeInterval(WidgetMetrics.timelineReloadInterval)
      )
    )
    completion(timeline)
  }

  private func entry() -> RecentlyPlayedEntry {
    let state = WidgetStore.readState()
    return RecentlyPlayedEntry(
      date: Date(),
      items: Array(state?.recentlyPlayed.prefix(4) ?? []),
      themeName: state?.nowPlaying?.themeName
    )
  }
}

// MARK: - RecentlyPlayedWidget

struct RecentlyPlayedWidget: Widget {
  private let kind = WidgetSharedConfig.kindRecentlyPlayed

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: kind,
      provider: RecentlyPlayedTimelineProvider()
    ) { entry in
      RecentlyPlayedWidgetView(entry: entry)
        .containerBackground(for: .widget) {
          Color("WidgetBackground")
        }
    }
    .configurationDisplayName("Recently Played")
    .description("Jump back into recently played tracks.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

// MARK: - RecentlyPlayedWidgetView

struct RecentlyPlayedWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: RecentlyPlayedEntry

  private var themeColor: Color {
    WidgetTheme.color(name: entry.themeName)
  }

  /// medium fits 3 rows at 66pt rhythm, large fits 4 — the shelf header
  /// eats one row on medium
  private var visibleItems: [WidgetRecentItem] {
    Array(entry.items.prefix(family == .systemLarge ? 4 : 3))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recently Played")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      if visibleItems.isEmpty {
        emptyLayout
      } else {
        ForEach(visibleItems) { item in
          row(item)
        }
      }
      Spacer(minLength: 0)
    }
    .widgetURL(URL(string: "\(WidgetSharedConfig.appURLScheme)://"))
  }

  @ViewBuilder
  private func row(_ item: WidgetRecentItem) -> some View {
    // radios have no `deepLinkURL` — an unconditional play glyph + "plays"
    // hint would be a false affordance on an inert row
    let canPlay = item.deepLinkURL != nil
    let content = HStack(spacing: 10) {
      WidgetArtworkView(
        fileName: item.artworkFileName,
        themeColor: themeColor
      )
      .frame(
        width: WidgetMetrics.artworkRow,
        height: WidgetMetrics.artworkRow
      )
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        Text(item.artist)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .layoutPriority(1)
      Spacer(minLength: 4)
      if canPlay {
        Image(systemName: "play.circle")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(item.title), \(item.artist)")
    .accessibilityHint(canPlay ? "Plays this item" : "Opens SonicWave")

    if let url = item.deepLinkURL {
      Link(destination: url) {
        content
      }
    } else {
      // radios can't be replayed via playID — show without action
      content
    }
  }

  private var emptyLayout: some View {
    VStack(spacing: 8) {
      WidgetArtworkView(fileName: nil, themeColor: themeColor)
        .frame(
          width: WidgetMetrics.artworkRow,
          height: WidgetMetrics.artworkRow
        )
      Text("Nothing played yet")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Nothing played yet. Tap to open SonicWave.")
  }
}
