//
//  SonicWaveWatchApp.swift
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

// MARK: - SonicWaveWatchApp

/// watchOS companion for SonicWave (G15) — remote control of the iPhone
/// app's playback over WatchConnectivity. The watch app is deliberately
/// self-contained: it links no SonicWaveKit code and talks only the
/// typed `WatchMessage`/`WatchNowPlaying` dictionary protocol shared
/// with the iOS target (`SonicWave/Watch/WatchShared.swift`).
@main
struct SonicWaveWatchApp: App {
  @StateObject private var sessionManager = WatchSessionManager()

  var body: some Scene {
    WindowGroup {
      WatchRootView()
        .environmentObject(sessionManager)
    }
  }
}
