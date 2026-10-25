//
//  NavidromeNativeApi.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 24.02.26.
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

import Foundation
import os.log

// MARK: - NavidromeNativeApi

/// G8: minimal client for Navidrome's *native* REST API — the only channel
/// that exposes smart-playlist (`.nsp`) rules; the Subsonic `getPlaylist`
/// contract intentionally has no rules field (verified against
/// `navidrome/server/subsonic/playlists.go`, `buildOSPlaylist` only marks
/// smart playlists `readonly="true"`).
///
/// Auth flow (documented in `navidrome/navidrome` discussion #3765 — the
/// API is UNSTABLE, hence every failure degrades to `.notSupported` at the
/// call site, never a user-facing error):
/// 1. `POST {server}/auth/login` `{"username","password"}` → `{"token"}`
/// 2. `GET  {server}/api/playlist/{id}` with
///    `x-nd-authorization: Bearer <token>` → playlist JSON incl. `rules`
///
/// The same account credentials are reused — no additional secrets and no
/// credential logging (CleansedURL discipline: the response body is never
/// logged, only cleansed request URLs).
final class NavidromeNativeApi: Sendable {
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "NavidromeApi")
  private let sessionSecurity: AccountSessionSecurity
  private let jwtToken = Atomic<String?>(wrappedValue: nil)

  init(sessionSecurity: AccountSessionSecurity) {
    self.sessionSecurity = sessionSecurity
  }

  /// Fetches the playlist's `rules` JSON fragment. Returns `nil` for every
  /// unsupported/failed step — callers wrap that as `.notSupported`.
  func requestPlaylistRules(
    playlistId: String,
    credentials: LoginCredentials,
    urlCleanser: URLCleanser
  ) async throws
    -> Data? {
    guard let firstToken = try await authenticate(
      credentials: credentials,
      urlCleanser: urlCleanser
    ) else { return nil }
    guard let url = nativeApiUrl(
      serverUrl: credentials.activeBackendServerUrl,
      path: ["api", "playlist", playlistId]
    ) else { return nil }

    // a cached JWT can go stale (server restart, token expiry, credential
    // change) — any non-200 drops it, and a 401 retries once with a fresh
    // login before giving up
    var token = firstToken
    for attempt in 0 ... 1 {
      var request = URLRequest(url: url)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "x-nd-authorization")
      for (field, value) in credentials.httpHeaders {
        request.setValue(value, forHTTPHeaderField: field)
      }
      let session = URLSession(
        configuration: URLSessionConfiguration.default,
        delegate: AccountSessionChallengeHandler(security: sessionSecurity),
        delegateQueue: nil
      )
      defer { session.invalidateAndCancel() }

      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return nil }
      if http.statusCode != 200 {
        jwtToken.wrappedValue = nil
        if http.statusCode == 401, attempt == 0 {
          guard let refreshed = try await authenticate(
            credentials: credentials,
            urlCleanser: urlCleanser
          ) else { return nil }
          token = refreshed
          continue
        }
        os_log(
          "Navidrome playlist rules fetch failed (status %ld): %s",
          log: log,
          type: .info,
          http.statusCode,
          urlCleanser.cleanse(url: url).description
        )
        return nil
      }
      guard let json = try? JSONSerialization.jsonObject(with: data),
            let playlist = json as? [String: Any],
            let rules = playlist["rules"]
      else { return nil }

      // `rules` is either a nested object or a JSON-encoded string depending
      // on Navidrome version — normalize both to raw criteria JSON data
      if let rulesDict = rules as? [String: Any],
         let rulesData = try? JSONSerialization.data(withJSONObject: rulesDict) {
        return rulesData
      }
      if let rulesString = rules as? String {
        return rulesString.data(using: .utf8)
      }
      return nil
    }
    return nil
  }

  private func authenticate(
    credentials: LoginCredentials,
    urlCleanser: URLCleanser
  ) async throws
    -> String? {
    if let cached = jwtToken.wrappedValue { return cached }
    guard let url = nativeApiUrl(
      serverUrl: credentials.activeBackendServerUrl,
      path: ["auth", "login"]
    ) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (field, value) in credentials.httpHeaders {
      request.setValue(value, forHTTPHeaderField: field)
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "username": credentials.username,
      "password": credentials.password,
    ])

    let session = URLSession(
      configuration: URLSessionConfiguration.default,
      delegate: AccountSessionChallengeHandler(security: sessionSecurity),
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["token"] as? String
    else {
      // a rejected login must not poison the cache either — make sure
      // no stale token survives a failed re-auth
      jwtToken.wrappedValue = nil
      os_log(
        "Navidrome native API login failed: %s",
        log: log,
        type: .info,
        urlCleanser.cleanse(url: url).description
      )
      return nil
    }
    jwtToken.wrappedValue = token
    return token
  }

  /// clears the cached JWT — called from
  /// `SubsonicServerApi.provideCredentials` so a credential/account change
  /// never reuses the previous session's token
  func invalidateSession() {
    jwtToken.wrappedValue = nil
  }

  private func nativeApiUrl(serverUrl: String, path: [String]) -> URL? {
    guard var url = URL(string: serverUrl) else { return nil }
    for component in path {
      url.appendPathComponent(component)
    }
    return url
  }
}
