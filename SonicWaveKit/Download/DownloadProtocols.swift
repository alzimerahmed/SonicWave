//
//  DownloadProtocols.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 21.07.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

import CoreData
import Foundation

public typealias CompleteHandlerBlock = @Sendable () -> ()

// MARK: - DownloadRequest

public struct DownloadRequest: Hashable, Sendable {
  let objectID: NSManagedObjectID
  let id: String
  let title: String
  let info: DownloadElementInfo
}

// MARK: - DownloadManageable

public protocol DownloadManageable {
  @MainActor
  var urlSessionIdentifier: String? { get }
  func getBackgroundFetchCompletionHandler() async -> CompleteHandlerBlock?
  func setBackgroundFetchCompletionHandler(_ newValue: CompleteHandlerBlock?)
  /// Downloads a single item and marks it with the given `downloadTier`
  /// (see `PlayableDownloadTier`). The tier expresses download intent:
  /// `.cache` = evictable playback cache, `.pinned` = permanent download.
  /// Use `download(object:)` for explicit user-initiated downloads (.pinned).
  @MainActor
  func download(object: Downloadable, asTier tier: PlayableDownloadTier)
  @MainActor
  func download(objects: [Downloadable], asTier tier: PlayableDownloadTier)
  @MainActor
  func removeFinishedDownload(for object: Downloadable)
  @MainActor
  func removeFinishedDownload(for objects: [Downloadable])
  func clearFinishedDownloads()
  func resetFailedDownloads()
  func cancelDownloads()
  /// LRU-trims the evictable `.cache` tier to the account's configured
  /// cache size limit (`AccountSetting.cacheSizeLimitBytes`). No-op for
  /// download managers without cache limiting (e.g. artwork).
  /// Returns the number of evicted items.
  @discardableResult
  func trimCacheToLimit() async -> Int
  func start()
  func stop()
}

public extension DownloadManageable {
  /// Explicit user-initiated download — marks the item `.pinned`
  /// (never evicted automatically).
  @MainActor
  func download(object: Downloadable) {
    download(object: object, asTier: .pinned)
  }

  /// Explicit user-initiated downloads — marks the items `.pinned`
  /// (never evicted automatically).
  @MainActor
  func download(objects: [Downloadable]) {
    download(objects: objects, asTier: .pinned)
  }
}

// MARK: - DownloadManagerDelegate

public protocol DownloadManagerDelegate: Sendable {
  var requestPredicate: NSPredicate { get }
  var parallelDownloadsCount: Int { get }
  var httpHeaders: [String: String] { get }
  func prepareDownload(
    downloadInfo: DownloadElementInfo,
    storage: AsyncCoreDataAccessWrapper
  ) async throws -> URL
  func validateDownloadedData(fileURL: URL?, downloadURL: URL?) -> ResponseError?
  func completedDownload(
    downloadInfo: DownloadElementInfo,
    fileURL: URL,
    fileMimeType: String?,
    storage: AsyncCoreDataAccessWrapper
  ) async
  func failedDownload(downloadInfo: DownloadElementInfo, storage: AsyncCoreDataAccessWrapper) async
}

// MARK: - Downloadable

public protocol Downloadable: CustomEquatable {
  var objectID: NSManagedObjectID { get }
  var isCached: Bool { get }
  var displayString: String { get }
  var threadSafeInfo: DownloadElementInfo? { get }
}

extension Downloadable {
  public var uniqueID: String { objectID.uriRepresentation().absoluteString }
}
