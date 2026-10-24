//
//  LrclibApi.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 24.10.26.
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

// MARK: - LrclibTrack

/// LRCLIB lyrics record — subset of the `GET /api/get` response.
/// `syncedLyrics`/`plainLyrics` are LRC resp. raw-text strings; both are
/// null for instrumental records.
struct LrclibTrack: Sendable, Codable, Equatable {
  var id: Int?
  var trackName: String?
  var artistName: String?
  var albumName: String?
  var duration: Double?
  var instrumental: Bool?
  var plainLyrics: String?
  var syncedLyrics: String?
}

// MARK: - LrclibApi

/// LRCLIB lyrics lookup (`https://lrclib.net/api/get`) — third-party host,
/// deliberately decoupled from the account session stack:
/// - own ephemeral `URLSession` (no account delegate, no TLS pinning, no
///   shared cookie/cache stores)
/// - no credentials, no session token, no custom headers — the query carries
///   only public track metadata
/// - no `ServerUnreachableMonitor` reporting: a dead lrclib.net must never
///   flip the account into offline mode
final class LrclibApi: Sendable {
  static let apiBaseURL = "https://lrclib.net/api/get"
  /// `SonicWave/<version>` — same Bundle read `AmperKit.version` does,
  /// kept nonisolated so the request path stays off-actor
  private static let userAgent =
    "SonicWave/\((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")"

  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "Lrclib")
  /// boxed — `URLSession` predates the Sendable audit (same pattern the
  /// per-account Alamofire sessions use)
  private let session = Atomic<URLSession>(wrappedValue: Self.createSession())

  private static func createSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 20
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
  }

  /// `GET /api/get?track_name&artist_name&album_name&duration`
  /// 200 -> record, 404 -> nil (TrackNotFound). Other statuses throw.
  /// `albumName`/`durationSeconds` are optional on LRCLIB's side — omitted
  /// when empty/zero (a `duration` of 0 would fail its 1...3600 validation).
  func fetchLyrics(
    trackName: String,
    artistName: String,
    albumName: String?,
    durationSeconds: Int
  ) async throws -> LrclibTrack? {
    var urlComp = URLComponents()
    urlComp.scheme = "https"
    urlComp.host = "lrclib.net"
    urlComp.path = "/api/get"
    var queryItems = [
      URLQueryItem(name: "track_name", value: trackName),
      URLQueryItem(name: "artist_name", value: artistName),
    ]
    if let albumName, !albumName.isEmpty {
      queryItems.append(URLQueryItem(name: "album_name", value: albumName))
    }
    if durationSeconds > 0 {
      queryItems.append(URLQueryItem(name: "duration", value: durationSeconds.description))
    }
    urlComp.queryItems = queryItems
    guard let url = urlComp.url else { throw BackendError.invalidUrl }

    var request = URLRequest(url: url)
    // LRCLIB asks clients to identify themselves instead of sending
    // the platform default UA
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.wrappedValue.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ResponseError(type: .api, message: "no HTTP response")
    }
    switch httpResponse.statusCode {
    case 200:
      return try JSONDecoder().decode(LrclibTrack.self, from: data)
    case 404:
      return nil
    default:
      os_log(
        "LRCLIB lookup failed with status %i",
        log: self.log,
        type: .info,
        httpResponse.statusCode
      )
      throw ResponseError(
        type: .api,
        statusCode: httpResponse.statusCode,
        cleansedURL: CleansedURL(urlString: Self.apiBaseURL)
      )
    }
  }
}
