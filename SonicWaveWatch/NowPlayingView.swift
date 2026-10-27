//
//  NowPlayingView.swift
//  SonicWaveWatch
//
//  Created by Alzimer Ahmed on 28.10.26.
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

// MARK: - WatchRootView

/// Route by companion state: no iPhone app → install hint; otherwise the
/// Now Playing remote. Reachability itself is handled inside
/// `NowPlayingView` — the last snapshot stays visible (controls send via
/// `transferUserInfo` which wakes the phone app) but an honest hint is
/// shown instead of pretending the phone is live.
struct WatchRootView: View {
  @EnvironmentObject private var session: WatchSessionManager

  var body: some View {
    if session.isCompanionAppInstalled {
      NowPlayingView()
    } else {
      hintView(
        systemImage: "iphone",
        title: "SonicWave",
        message: "Install SonicWave on your iPhone to control playback."
      )
    }
  }

  func hintView(systemImage: String, title: String, message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
  }
}

// MARK: - NowPlayingView

struct NowPlayingView: View {
  @EnvironmentObject private var session: WatchSessionManager
  /// local progress ticker — the phone sends anchored elapsed values;
  /// the watch advances them between pushes
  @State private var now = Date()
  private let ticker = Timer.publish(every: 1, on: .main, in: .common)
    .autoconnect()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 8) {
          artwork
          metadata
          if !session.isReachable {
            Text("Open SonicWave on your iPhone for live control")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          progress
          transport
          volumeControl
          upNextLink
        }
        .padding(.horizontal, 4)
      }
      .navigationTitle("SonicWave")
    }
    .onReceive(ticker) { date in
      now = date
    }
  }

  // MARK: artwork

  @ViewBuilder
  private var artwork: some View {
    if let image = session.artwork,
       session.artworkTrackId == session.nowPlaying.trackId {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(1, contentMode: .fill)
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("Album artwork")
    } else {
      RoundedRectangle(cornerRadius: 5)
        .fill(.quaternary)
        .frame(width: 96, height: 96)
        .overlay {
          Image(systemName: "music.note")
            .font(.title)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .accessibilityLabel("No artwork")
    }
  }

  // MARK: metadata

  private var metadata: some View {
    VStack(spacing: 1) {
      if session.nowPlaying.hasNowPlaying {
        Text(session.nowPlaying.title)
          .font(.headline)
          .lineLimit(2)
          .multilineTextAlignment(.center)
        Text(session.nowPlaying.artist)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else {
        Text("Nothing playing")
          .font(.headline)
        Text("Start playback on your iPhone")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: progress

  @ViewBuilder
  private var progress: some View {
    let state = session.nowPlaying
    if state.hasNowPlaying, state.isRadio {
      Text("LIVE")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.red)
    } else if state.hasNowPlaying, state.duration > 0 {
      let elapsed = state.elapsedNow(at: now)
      ProgressView(value: elapsed, total: state.duration)
        .tint(.accentColor)
        .accessibilityLabel("Playback progress")
        .accessibilityValue(
          "\(Self.formatTime(elapsed)) of \(Self.formatTime(state.duration))"
        )
      HStack {
        Text(Self.formatTime(elapsed))
        Spacer()
        Text("-" + Self.formatTime(max(0, state.duration - elapsed)))
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
    }
  }

  // MARK: transport

  private var transport: some View {
    let isEnabled = session.nowPlaying.hasNowPlaying
    return HStack(spacing: 20) {
      Button {
        session.send(.playPreviousOrReplay)
      } label: {
        Image(systemName: "backward.fill")
          .font(.title3)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Previous track")
      .disabled(!isEnabled)

      Button {
        session.send(.togglePlayPause)
      } label: {
        Image(
          systemName: session.nowPlaying.isPlaying
            ? "pause.fill" : "play.fill"
        )
        .font(.title2)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(session.nowPlaying.isPlaying ? "Pause" : "Play")
      .disabled(!isEnabled)

      Button {
        session.send(.playNext)
      } label: {
        Image(systemName: "forward.fill")
          .font(.title3)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Next track")
      .disabled(!isEnabled)
    }
    .opacity(isEnabled ? 1 : 0.4)
  }

  // MARK: volume

  private var volumeControl: some View {
    HStack(spacing: 6) {
      Image(systemName: "speaker.fill")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Slider(value: $session.volume, in: 0 ... 1)
        .accessibilityLabel("Volume")
      Image(systemName: "speaker.wave.3.fill")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  // MARK: up next

  @ViewBuilder
  private var upNextLink: some View {
    let items = session.nowPlaying.upNext
    if !items.isEmpty {
      NavigationLink {
        UpNextView(items: items)
      } label: {
        Label("Up Next", systemImage: "list.bullet")
          .font(.footnote)
      }
      .accessibilityHint("Shows the next \(items.count) queued tracks")
    }
  }

  static func formatTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    if total >= 3600 {
      return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

// MARK: - UpNextView

/// Queue glimpse — the `WatchNowPlaying.maxUpNextItems` upcoming
/// context-queue entries the phone included in the snapshot.
struct UpNextView: View {
  let items: [WatchQueueItem]

  var body: some View {
    List(items, id: \.title) { item in
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title)
          .font(.footnote)
          .lineLimit(2)
        Text(item.artist)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
    }
    .navigationTitle("Up Next")
  }
}
