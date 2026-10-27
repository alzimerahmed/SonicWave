//
//  TVLibraryViews.swift
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

// MARK: - TVMainTabsView

/// Living-room surface: Now Playing + library browse. Focus-driven
/// `TabView` per tvOS HIG — every control is a real action wired to
/// `PlayerFacade` through `TVViewModel`.
struct TVMainTabsView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    TabView {
      Tab("Now Playing", systemImage: "play.circle") {
        TVNowPlayingView()
      }
      Tab("Albums", systemImage: "square.stack") {
        TVAlbumsView()
      }
      Tab("Artists", systemImage: "music.mic") {
        TVArtistsView()
      }
      Tab("Playlists", systemImage: "music.note.list") {
        TVPlaylistsView()
      }
    }
  }
}

// MARK: - TVEntityCard

/// Artwork card for grid cells — 5pt radius per the design system,
/// focus lift on the remote.
struct TVEntityCard<Content: View>: View {
  let artwork: Content
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      artwork
        .aspectRatio(1, contentMode: .fit)
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 5))
      Text(title)
        .font(.callout)
        .lineLimit(1)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(width: 200)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(subtitle)")
  }
}

// MARK: - TVAlbumsView

struct TVAlbumsView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220), spacing: 40)],
          spacing: 40
        ) {
          ForEach(model.albums, id: \.id) { album in
            NavigationLink {
              TVAlbumDetailView(album: album)
            } label: {
              TVEntityCard(
                artwork: TVArtworkImage(
                  entity: album,
                  themePreference: model.themePreference(for: album),
                  artworkDisplayPreference: model
                    .artworkDisplayPreference(for: album)
                ),
                title: album.name,
                subtitle: album.artist?.name ?? ""
              )
            }
            .buttonStyle(.borderless)
          }
        }
        .padding(60)
      }
      .navigationTitle("Albums")
    }
  }
}

// MARK: - TVAlbumDetailView

struct TVAlbumDetailView: View {
  @EnvironmentObject private var model: TVViewModel
  let album: Album

  var body: some View {
    HStack(alignment: .top, spacing: 50) {
      VStack(spacing: 20) {
        TVArtworkImage(
          entity: album,
          themePreference: model.themePreference(for: album),
          artworkDisplayPreference: model.artworkDisplayPreference(for: album)
        )
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        Button("Play Album") {
          model.playAll(of: album)
        }
        .accessibilityHint("Plays the whole album")
      }
      List(Array(album.playables.enumerated()), id: \.element.id) {
        index,
        playable in
        Button {
          model.play(
            playables: album.playables,
            at: index,
            contextName: album.name
          )
        } label: {
          HStack {
            Text(playable.track > 0 ? "\(playable.track)" : "")
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 40, alignment: .trailing)
            Text(playable.title)
              .lineLimit(1)
            Spacer()
            if playable.isCached {
              Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
            }
            Text(TVFormat.duration(playable.duration))
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityLabel("\(playable.title), \(TVFormat.duration(playable.duration))")
      }
    }
    .padding(60)
    .navigationTitle(album.name)
  }
}

// MARK: - TVArtistsView

struct TVArtistsView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220), spacing: 40)],
          spacing: 40
        ) {
          ForEach(model.artists, id: \.id) { artist in
            NavigationLink {
              TVArtistDetailView(artist: artist)
            } label: {
              TVEntityCard(
                artwork: TVArtworkImage(
                  entity: artist,
                  themePreference: model.themePreference(for: artist),
                  artworkDisplayPreference: model
                    .artworkDisplayPreference(for: artist)
                ),
                title: artist.name,
                subtitle: "\(artist.albums.count) albums"
              )
            }
            .buttonStyle(.borderless)
          }
        }
        .padding(60)
      }
      .navigationTitle("Artists")
    }
  }
}

// MARK: - TVArtistDetailView

/// Artist → their albums — keeps the drill-in shallow for the remote.
struct TVArtistDetailView: View {
  @EnvironmentObject private var model: TVViewModel
  let artist: Artist

  var body: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 220), spacing: 40)],
        spacing: 40
      ) {
        ForEach(artist.albums, id: \.id) { album in
          NavigationLink {
            TVAlbumDetailView(album: album)
          } label: {
            TVEntityCard(
              artwork: TVArtworkImage(
                entity: album,
                themePreference: model.themePreference(for: album),
                artworkDisplayPreference: model
                  .artworkDisplayPreference(for: album)
              ),
              title: album.name,
              subtitle: album.artist?.name ?? ""
            )
          }
          .buttonStyle(.borderless)
        }
      }
      .padding(60)
    }
    .navigationTitle(artist.name)
  }
}

// MARK: - TVPlaylistsView

struct TVPlaylistsView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    NavigationStack {
      List(model.playlists, id: \.id) { playlist in
        NavigationLink {
          TVPlaylistDetailView(playlist: playlist)
        } label: {
          Label(playlist.name, systemImage: "music.note.list")
        }
      }
      .navigationTitle("Playlists")
    }
  }
}

// MARK: - TVPlaylistDetailView

struct TVPlaylistDetailView: View {
  @EnvironmentObject private var model: TVViewModel
  let playlist: Playlist

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button("Play Playlist") {
        model.playAll(of: playlist)
      }
      .padding(.horizontal, 60)
      .padding(.top, 40)
      List(Array(playlist.playables.enumerated()), id: \.element.id) {
        index,
        playable in
        Button {
          model.play(
            playables: playlist.playables,
            at: index,
            contextName: playlist.name
          )
        } label: {
          HStack {
            Text(playable.title)
              .lineLimit(1)
            Spacer()
            Text(playable.creatorName)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Text(TVFormat.duration(playable.duration))
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityLabel("\(playable.title), \(playable.creatorName)")
      }
    }
    .navigationTitle(playlist.name)
  }
}

// MARK: - TVFormat

/// Small shared formatters — tabular durations only.
enum TVFormat {
  static func duration(_ seconds: Int) -> String {
    let total = max(0, seconds)
    if total >= 3600 {
      return String(
        format: "%d:%02d:%02d",
        total / 3600,
        (total % 3600) / 60,
        total % 60
      )
    }
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
