//
//  TVRootView.swift
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

import SwiftUI

// MARK: - TVRootView

/// State router — the same shape `SceneDelegate` picks on iOS:
/// no account → login; account but no sync → sync; synced → main tabs.
struct TVRootView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    Group {
      if !model.hasAccount {
        TVLoginView()
      } else if model.isSyncing {
        TVSyncView()
      } else if !model.isLibrarySynced {
        TVSyncRequiredView()
      } else {
        TVMainTabsView()
      }
    }
    .animation(.default, value: model.hasAccount)
    .animation(.default, value: model.isSyncing)
    .animation(.default, value: model.isLibrarySynced)
  }
}

// MARK: - TVLoginView

/// Simplified on-TV account setup — same credentials the iOS login
/// collects (server type is auto-detected by `BackendProxy`).
struct TVLoginView: View {
  @EnvironmentObject private var model: TVViewModel
  @State private var serverUrl = ""
  @State private var username = ""
  @State private var password = ""
  /// self-hosted servers with self-signed certs — mirrors the iOS
  /// `LoginVC` toggle; the kit pins the leaf key on first contact (TOFU)
  @State private var allowUntrustedCertificates = false

  var body: some View {
    VStack(spacing: 30) {
      Image(systemName: "music.note.list")
        .font(.system(size: 60))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("SonicWave")
        .font(.title)
        .bold()
      Text("Sign in to your music server")
        .font(.callout)
        .foregroundStyle(.secondary)

      VStack(spacing: 16) {
        TextField("Server URL (https://…)", text: $serverUrl)
          .autocorrectionDisabled()
          .frame(width: 700)
        TextField("Username", text: $username)
          .autocorrectionDisabled()
          .frame(width: 700)
        SecureField("Password", text: $password)
          .frame(width: 700)
        Toggle("Allow untrusted certificates", isOn: $allowUntrustedCertificates)
          .frame(width: 700)
          .accessibilityHint("Enable only for self-signed server certificates")
      }

      if let error = model.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .frame(width: 700)
      }

      Button {
        Task {
          await model.login(
            serverUrl: serverUrl,
            username: username,
            password: password,
            allowUntrustedCertificates: allowUntrustedCertificates
          )
        }
      } label: {
        if model.isConnecting {
          ProgressView()
            .frame(width: 160)
        } else {
          Text("Connect")
            .frame(width: 160)
        }
      }
      .disabled(model.isConnecting)
      .accessibilityLabel("Connect to server")
    }
    .padding(60)
  }
}

// MARK: - TVSyncView

/// Initial library sync progress — mirrors `SyncVC`'s status feed
/// (`ParsedObjectType` label + percent).
struct TVSyncView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    VStack(spacing: 30) {
      ProgressView()
        .scaleEffect(1.6)
        .padding(20)
      Text("Syncing library")
        .font(.title3)
      Text(model.syncProgress)
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Sync progress: \(model.syncProgress)")
    }
  }
}

// MARK: - TVSyncRequiredView

/// Account exists but the library was never synced (aborted sync or
/// a state carried over from a killed first run) — an honest retry
/// prompt rather than an empty library.
struct TVSyncRequiredView: View {
  @EnvironmentObject private var model: TVViewModel

  var body: some View {
    VStack(spacing: 30) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 50))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Library sync required")
        .font(.title3)
      if let error = model.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
      }
      Button("Sync Library") {
        Task { await model.syncActiveAccount() }
      }
      .accessibilityHint("Downloads your server library for browsing")
    }
  }
}
