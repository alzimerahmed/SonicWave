//
//  TVNowPlayingView.swift
//  SonicWaveTV
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

import SonicWaveKit
import SwiftUI

// MARK: - TVNowPlayingView

/// Now Playing — hero artwork (entity-driven, so the themed generated
/// placeholder chain applies), live progress refreshed by the player's
/// ~1s notifier tick, full transport through `PlayerFacade`.
struct TVNowPlayingView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    let snapshot = model.snapshot
    if snapshot.hasTrack {
      HStack(spacing: 60) {
        artwork
          .frame(width: 340, height: 340)
          .clipShape(RoundedRectangle(cornerRadius: 5))
          .accessibilityLabel("Album artwork")

        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.title)
              .font(.title2)
              .lineLimit(2)
            Text(snapshot.artist)
              .font(.title3)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            if !snapshot.album.isEmpty {
              Text(snapshot.album)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if !snapshot.contextName.isEmpty {
              Text(snapshot.contextName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
          }

          progress(snapshot: snapshot)
          transport(snapshot: snapshot)
        }
        .frame(maxWidth: 900)
      }
      .padding(80)
    } else {
      VStack(spacing: 20) {
        Image(systemName: "music.note")
          .font(.system(size: 60))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("Nothing playing")
          .font(.title3)
        Text("Pick an album or playlist to start")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var artwork: some View {
    if let playable = model.currentPlayable {
      TVArtworkImage(
        entity: playable,
        themePreference: model.themePreference(for: playable),
        artworkDisplayPreference: model.artworkDisplayPreference(for: playable)
      )
    } else {
      RoundedRectangle(cornerRadius: 5)
        .fill(.quaternary)
        .overlay {
          Image(systemName: "music.note")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
  }

  @ViewBuilder
  private func progress(snapshot: TVPlayerSnapshot) -> some View {
    if snapshot.isRadio {
      Text("LIVE")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.red)
    } else if snapshot.duration > 0 {
      VStack(spacing: 6) {
        ProgressView(value: snapshot.elapsed, total: snapshot.duration)
          .accessibilityLabel("Playback progress")
          .accessibilityValue(
            "\(TVFormat.duration(Int(snapshot.elapsed))) of \(TVFormat.duration(Int(snapshot.duration)))"
          )
        HStack {
          Text(TVFormat.duration(Int(snapshot.elapsed)))
          Spacer()
          Text("-" + TVFormat.duration(
            Int(max(0, snapshot.duration - snapshot.elapsed))
          ))
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      }
    }
  }

  private func transport(snapshot: TVPlayerSnapshot) -> some View {
    HStack(spacing: 60) {
      Button {
        model.playPreviousOrReplay()
      } label: {
        Image(systemName: "backward.fill")
          .font(.title)
      }
      .accessibilityLabel("Previous track")

      Button {
        model.togglePlayPause()
      } label: {
        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
          .font(.largeTitle)
      }
      .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")

      Button {
        model.playNext()
      } label: {
        Image(systemName: "forward.fill")
          .font(.title)
      }
      .accessibilityLabel("Next track")
    }
  }
}
