//
//  LidarrApiClient.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 27.02.26.
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

// MARK: - LidarrKeychain

/// G25: the Lidarr API key is a secret — it lives in Keychain (same
/// pattern as `LoginCredentials` Phase-5 migration), keyed by the
/// account ident so different accounts can point at different Lidarr
/// instances. Never read it into UserDefaults/settings.
public enum LidarrKeychain {
  private static let helper = KeychainHelper(service: "com.alzimerahmed.sonicwave.lidarr")

  /// `nil` on `notFound` AND on `failure` (locked Keychain pre-first-
  /// unlock) — callers treat "no key" as integration-off; a failed read
  /// must never trigger a destructive overwrite.
  public static func apiKey(accountIdent: String) -> String? {
    switch helper.read(account: accountIdent) {
    case .success(let data): return String(decoding: data, as: UTF8.self)
    case .notFound, .failure: return nil
    }
  }

  @discardableResult
  public static func save(apiKey: String, accountIdent: String) -> OSStatus {
    if apiKey.isEmpty { return delete(accountIdent: accountIdent) }
    return helper.save(data: Data(apiKey.utf8), account: accountIdent)
  }

  @discardableResult
  public static func delete(accountIdent: String) -> OSStatus {
    helper.delete(account: accountIdent)
  }
}

// MARK: - LidarrArtistStub

/// Artist entry from `GET /api/v1/artist/lookup` — `foreignArtistId` is
/// the MusicBrainz id Lidarr needs on `POST /api/v1/artist`.
public struct LidarrArtistStub: Sendable, Equatable {
  public var foreignArtistId: String
  public var artistName: String
  public var overview: String?

  public init(foreignArtistId: String, artistName: String, overview: String? = nil) {
    self.foreignArtistId = foreignArtistId
    self.artistName = artistName
    self.overview = overview
  }
}

// MARK: - LidarrApiClient

/// Minimal real slice of the Lidarr v1 API (G25): artist lookup +
/// add-request. `qualityProfileId`/`metadataProfileId`/`rootFolderPath`
/// are required by the add endpoint and fetched on demand — the first
/// entry of each is used, matching what Lidarr's own UI defaults to.
public final class LidarrApiClient: Sendable {
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "Lidarr")
  private let baseUrl: URL
  private let apiKey: String
  private let session: URLSession

  public init(baseUrl: URL, apiKey: String, session: URLSession = .shared) {
    self.baseUrl = baseUrl
    self.apiKey = apiKey
    self.session = session
  }

  /// Builds the configured client for an account, or `nil` when the
  /// integration isn't set up (no URL in account settings / no key in
  /// Keychain).
  @MainActor
  public static func configured(for accountInfo: AccountInfo) -> LidarrApiClient? {
    guard let rawUrl = AmperKit.shared.storage.settings.accounts
      .getSetting(accountInfo).read.lidarrUrl,
      let baseUrl = URL(string: rawUrl),
      baseUrl.host != nil,
      let apiKey = LidarrKeychain.apiKey(accountIdent: accountInfo.ident),
      !apiKey.isEmpty
    else { return nil }
    return LidarrApiClient(baseUrl: baseUrl, apiKey: apiKey)
  }

  private var decoder: JSONDecoder { JSONDecoder() }

  private func request(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
    guard var urlComp = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false) else {
      throw BackendError.invalidUrl
    }
    urlComp.path = (baseUrl.path == "/" ? "" : baseUrl.path) + "/api/v1/\(path)"
    urlComp.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = urlComp.url else { throw BackendError.invalidUrl }
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    request.timeoutInterval = 15
    return request
  }

  private func data(for request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      os_log(
        "Lidarr answered HTTP %d for %s",
        log: self.log,
        type: .error,
        http.statusCode,
        request.url?.path ?? ""
      )
      throw ResponseError(
        type: .api,
        statusCode: http.statusCode,
        message: "Lidarr HTTP \(http.statusCode)"
      )
    }
    return data
  }

  /// `GET artist/lookup?term=` — external (MusicBrainz-backed) artist
  /// search inside Lidarr
  public func searchArtists(term: String) async throws -> [LidarrArtistStub] {
    let data = try await data(for: try request(
      path: "artist/lookup",
      queryItems: [URLQueryItem(name: "term", value: term)]
    ))
    return Self.decodeArtists(data)
  }

  /// `POST artist` — requests adding the artist (monitored + search for
  /// missing albums). First root folder / quality & metadata profiles.
  public func addArtist(_ artist: LidarrArtistStub) async throws {
    async let rootFolderPath = firstRootFolderPath()
    async let qualityProfileId = firstProfileId(path: "qualityprofile")
    async let metadataProfileId = firstProfileId(path: "metadataprofile")
    let body = AddArtistBody(
      artistName: artist.artistName,
      foreignArtistId: artist.foreignArtistId,
      qualityProfileId: try await qualityProfileId,
      metadataProfileId: try await metadataProfileId,
      rootFolderPath: try await rootFolderPath,
      monitored: true,
      addOptions: AddOptions(searchForMissingAlbums: true)
    )
    var request = try self.request(path: "artist")
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    _ = try await data(for: request)
  }

  private func firstRootFolderPath() async throws -> String {
    let data = try await data(for: try request(path: "rootfolder"))
    let folders = Self.decodeIdPathPairs(data)
    guard let first = folders.first else {
      throw BackendError.incorrectServerBehavior(message: "Lidarr reports no root folders")
    }
    return first
  }

  private func firstProfileId(path: String) async throws -> Int {
    let data = try await data(for: try request(path: path))
    guard let id = Self.decodeFirstId(data) else {
      throw BackendError.incorrectServerBehavior(message: "Lidarr reports no \(path) entries")
    }
    return id
  }

  // MARK: pure decoders — static for unit tests

  public static func decodeArtists(_ data: Data) -> [LidarrArtistStub] {
    struct Raw: Decodable {
      let foreignArtistId: String?
      let artistName: String?
      let overview: String?
    }
    guard let rows = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
    return rows.compactMap {
      guard let id = $0.foreignArtistId, let name = $0.artistName else { return nil }
      return LidarrArtistStub(foreignArtistId: id, artistName: name, overview: $0.overview)
    }
  }

  static func decodeFirstId(_ data: Data) -> Int? {
    struct Raw: Decodable { let id: Int? }
    return (try? JSONDecoder().decode([Raw].self, from: data))?.first?.id
  }

  /// `rootfolder` rows carry `path` (string) — only the first is used
  static func decodeIdPathPairs(_ data: Data) -> [String] {
    struct Raw: Decodable { let path: String? }
    return ((try? JSONDecoder().decode([Raw].self, from: data)) ?? []).compactMap { $0.path }
  }

  private struct AddOptions: Encodable {
    let searchForMissingAlbums: Bool
  }

  private struct AddArtistBody: Encodable {
    let artistName: String
    let foreignArtistId: String
    let qualityProfileId: Int
    let metadataProfileId: Int
    let rootFolderPath: String
    let monitored: Bool
    let addOptions: AddOptions
  }
}
