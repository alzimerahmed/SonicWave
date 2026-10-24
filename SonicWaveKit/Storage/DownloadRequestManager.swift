//
//  DownloadRequestManager.swift
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

// MARK: - DownloadTaskInfo

struct DownloadTaskInfo: Sendable {
  let request: DownloadRequest
  let url: URL
  var httpHeaders: [String: String] = [:]
  var hasStarted = false
}

typealias GetDownloadManagerDelegateCB = @MainActor () -> DownloadManagerDelegate

// MARK: - DownloadRequestManager

final class DownloadRequestManager: Sendable {
  let accountObjectId: NSManagedObjectID
  let accountInfo: AccountInfo
  private let storage: AsyncCoreDataAccessWrapper
  private let getDownloadDelegateCB: GetDownloadManagerDelegateCB

  init(
    accountObjectId: NSManagedObjectID,
    accountInfo: AccountInfo,
    storage: AsyncCoreDataAccessWrapper,
    getDownloadDelegateCB: @escaping GetDownloadManagerDelegateCB
  ) {
    self.accountObjectId = accountObjectId
    self.accountInfo = accountInfo
    self.storage = storage
    self.getDownloadDelegateCB = getDownloadDelegateCB
  }

  /// Marks the requested `downloadTier` on the playable at request time.
  /// Promotion-only semantics (G6): a `.pinned` request upgrades a `.cache`d
  /// item; a `.cache` request never demotes a user-pinned download.
  /// Returns true when the tier actually changed.
  nonisolated private func markRequestedDownloadTier(
    on object: Downloadable,
    tier: PlayableDownloadTier
  ) -> Bool {
    guard let playable = object as? AbstractPlayable,
          playable.downloadTier != tier
    else { return false }
    // never silently demote a pinned download to evictable cache
    guard tier == .pinned || playable.downloadTier != .pinned else { return false }
    playable.downloadTier = tier
    return true
  }

  func add(
    downloadInfo: DownloadElementInfo,
    tier: PlayableDownloadTier = .pinned
  ) async -> DownloadRequest? {
    let request = try? await storage.performAndGet { asyncCompanion -> DownloadRequest? in
      let asyncObject = Download.createDownloadableObject(
        inContext: asyncCompanion.context,
        info: downloadInfo
      )
      let download = self.addLowPrio(
        object: asyncObject,
        tier: tier,
        library: asyncCompanion.library
      )
      guard let download else { return nil }
      return DownloadRequest(
        objectID: download.managedObject.objectID,
        id: asyncObject.uniqueID,
        title: download.title,
        info: downloadInfo
      )
    }
    return request
  }

  func add(
    downloadInfos: [DownloadElementInfo],
    tier: PlayableDownloadTier = .pinned
  ) async -> [DownloadRequest] {
    guard !downloadInfos.isEmpty else { return [] }
    return try! await storage.performAndGet { asyncCompanion in
      var asyncRequests = [DownloadRequest]()
      var objects = [(DownloadElementInfo, Downloadable)]()
      downloadInfos.forEach {
        let downloadable = Download.createDownloadableObject(
          inContext: asyncCompanion.context,
          info: $0
        )
        objects.append(($0, downloadable))
      }
      let asyncDownloads = self.addLowPrio(
        objects: objects,
        tier: tier,
        library: asyncCompanion.library
      )
      asyncDownloads.forEach {
        asyncRequests.append(DownloadRequest(
          objectID: $0.2.managedObject.objectID,
          id: $0.1.uniqueID, title: $0.2.title, info: $0.0
        ))
      }
      return asyncRequests
    }
  }

  nonisolated private func addLowPrio(
    objects: [(DownloadElementInfo, Downloadable)],
    tier: PlayableDownloadTier,
    library: LibraryStorage
  )
    -> [(DownloadElementInfo, Downloadable, Download)] {
    var hasCoreDataChanges = false
    let account = library.getAccount(managedObjectId: accountObjectId)
    let ids = Set(objects.compactMap { $0.1.uniqueID })
    let existingDownloadsDict = library.getDownloadsDict(account: account, ids: ids)

    var downloadMapping = [(DownloadElementInfo, Downloadable, Download)]()
    for (info, object) in objects {
      if markRequestedDownloadTier(on: object, tier: tier) {
        hasCoreDataChanges = true
      }
      if let existingDownload = existingDownloadsDict[object.uniqueID] {
        if existingDownload.errorDate != nil || !object.isCached {
          existingDownload.reset()
          hasCoreDataChanges = true
          downloadMapping.append((info, object, existingDownload))
        } else {
          // do nothing: the download has already an unused request
        }
      } else {
        hasCoreDataChanges = true
        let newDownload = library.createDownload(account: account, id: object.uniqueID)
        newDownload.element = object
        downloadMapping.append((info, object, newDownload))
      }
    }

    if hasCoreDataChanges {
      library.saveContext()
    }
    return downloadMapping
  }

  nonisolated private func addLowPrio(
    object: Downloadable,
    tier: PlayableDownloadTier,
    library: LibraryStorage
  ) -> Download? {
    let account = library.getAccount(managedObjectId: accountObjectId)
    // tier intent is persisted even when no new request is created —
    // the surrounding performAndGet saves the context on return
    _ = markRequestedDownloadTier(on: object, tier: tier)
    if let existingDownload = library.getDownload(account: account, id: object.uniqueID) {
      // reset and return existing downloads only for playables
      // existing artworks are ignored -> nil
      if let threadSafeInfo = object.threadSafeInfo,
         threadSafeInfo.type == .playable,
         existingDownload.errorDate != nil || !object.isCached {
        existingDownload.reset()
        library.saveContext()
        return existingDownload
      }
      return nil
    }

    let newDownload = library.createDownload(account: account, id: object.uniqueID)
    newDownload.element = object
    library.saveContext()
    return newDownload
  }

  /// Promotion path (G6): marks the tier on already-cached playables
  /// WITHOUT creating a download request — used when an explicit user
  /// download targets an item whose file is already on disk
  /// (auto-cached `.cache` -> `.pinned`). Demotion is impossible:
  /// `markRequestedDownloadTier` refuses `.pinned` -> `.cache`.
  func markTier(downloadInfo: DownloadElementInfo, tier: PlayableDownloadTier) async {
    try? await storage.perform { asyncCompanion in
      let object = Download.createDownloadableObject(
        inContext: asyncCompanion.context,
        info: downloadInfo
      )
      _ = self.markRequestedDownloadTier(on: object, tier: tier)
    }
  }

  func markTier(downloadInfos: [DownloadElementInfo], tier: PlayableDownloadTier) async {
    guard !downloadInfos.isEmpty else { return }
    try? await storage.perform { asyncCompanion in
      for downloadInfo in downloadInfos {
        let object = Download.createDownloadableObject(
          inContext: asyncCompanion.context,
          info: downloadInfo
        )
        _ = self.markRequestedDownloadTier(on: object, tier: tier)
      }
    }
  }

  func removeFinishedDownload(for uniqueID: String) async {
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      guard let existingDownload = asyncCompanion.library.getDownload(
        account: account,
        id: uniqueID
      ),
        existingDownload.finishDate != nil
      else { return }
      asyncCompanion.library.deleteDownload(existingDownload)
      asyncCompanion.saveContext()
    }
  }

  func removeFinishedDownload(for uniqueIDs: [String]) async {
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      for uniqueID in uniqueIDs {
        guard let existingDownload = asyncCompanion.library.getDownload(
          account: account,
          id: uniqueID
        ),
          existingDownload.finishDate != nil
        else { continue }
        asyncCompanion.library.deleteDownload(existingDownload)
      }
      asyncCompanion.saveContext()
    }
  }

  func getRequestedDownloads() async -> [DownloadRequest] {
    let predicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    let requestedDownloads = try? await storage.performAndGet { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: predicateFormat),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.finishDate)),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.errorDate)),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
        // ignore start date -> reset it after fetched
      ])
      let downloadsMO = try? asyncCompanion.context.fetch(fetchRequest)
      let downloadRequests = downloadsMO?.compactMap { downloadMo -> DownloadRequest? in
        let download = Download(managedObject: downloadMo)
        download.startDate = nil
        let id = download.id
        guard let element = download.element else { return nil }
        return DownloadRequest(
          objectID: downloadMo.objectID,
          id: id,
          title: download.title,
          info: DownloadElementInfo(objectId: element.objectID, type: download.baseType)
        )
      }
      asyncCompanion.saveContext()
      return downloadRequests
    }
    return requestedDownloads ?? []
  }

  func clearFinishedDownloads() async {
    let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: downloadPredicateFormat),
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          NSPredicate(format: "%K != nil", #keyPath(DownloadMO.finishDate)),
          NSPredicate(format: "%K != nil", #keyPath(DownloadMO.errorDate)),
          asyncCompanion.library.getFetchPredicate(forAccount: account),
        ]),
      ])
      let results = try? asyncCompanion.context.fetch(fetchRequest)
      let downloads = results?.compactMap { Download(managedObject: $0) }
      downloads?.forEach { asyncCompanion.library.deleteDownload($0) }
      asyncCompanion.saveContext()
    }
  }

  func clearAllDownloadsAsyncIfAllHaveFinished() {
    Task {
      let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
      let notStartedDownloadCount = try? await storage.performAndGet { asyncCompanion in
        let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
        let request: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
          NSPredicate(format: downloadPredicateFormat),
          NSPredicate(format: "%K == nil", #keyPath(DownloadMO.startDate)),
          asyncCompanion.library.getFetchPredicate(forAccount: account),
        ])
        return (try? asyncCompanion.context.count(for: request)) ?? 0
      }

      if notStartedDownloadCount == 0 {
        await clearAllDownloads()
      }
    }
  }

  func clearAllDownloads() async {
    let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: downloadPredicateFormat),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
      ])
      let results = try? asyncCompanion.context.fetch(fetchRequest)
      let downloads = results?.compactMap { Download(managedObject: $0) }
      downloads?.forEach { asyncCompanion.library.deleteDownload($0) }
      asyncCompanion.saveContext()
    }
  }

  /// Cancels one unfinished download (queued or in-flight): sets
  /// `isCanceled` (which stamps `error = .canceled` via the wrapper
  /// setter) so the FRC-driven queue UI reflects the state immediately
  /// and the entry becomes removable. The in-flight URLSession task is
  /// cancelled separately by `DownloadManager`.
  func cancelDownload(for uniqueID: String) async {
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      guard let download = asyncCompanion.library.getDownload(account: account, id: uniqueID),
            download.finishDate == nil, download.errorDate == nil
      else { return }
      download.isCanceled = true
      asyncCompanion.saveContext()
    }
  }

  /// Deletes a single download entry unless it is still running —
  /// finished, failed, and canceled entries are removed; queued-but-
  /// not-started entries are left to `cancelDownload` instead.
  func removeDownload(for uniqueID: String) async {
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      guard let download = asyncCompanion.library.getDownload(account: account, id: uniqueID),
            !download.isDownloading, download.startDate != nil || download.errorDate != nil ||
            download.finishDate != nil
      else { return }
      asyncCompanion.library.deleteDownload(download)
      asyncCompanion.saveContext()
    }
  }

  func cancelDownloads() async {
    let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: downloadPredicateFormat),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.finishDate)),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.errorDate)),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
      ])
      let results = try? asyncCompanion.context.fetch(fetchRequest)
      let downloads = results?.compactMap { Download(managedObject: $0) }
      downloads?.forEach { $0.isCanceled = true }
      asyncCompanion.saveContext()
    }
  }

  func getAndResetFailedDownloads() async -> [DownloadRequest] {
    let predicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    let failedDownloads = try? await storage.performAndGet { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: predicateFormat),
        NSPredicate(format: "%K != nil", #keyPath(DownloadMO.errorDate)),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
      ])
      let downloadsMO = try? asyncCompanion.context.fetch(fetchRequest)
      let downloadRequests = downloadsMO?.compactMap { downloadMo -> DownloadRequest? in
        let download = Download(managedObject: downloadMo)
        let id = download.id
        download.reset()
        guard let element = download.element else { return nil }
        return DownloadRequest(
          objectID: downloadMo.objectID,
          id: id,
          title: download.title,
          info: DownloadElementInfo(objectId: element.objectID, type: download.baseType)
        )
      }
      return downloadRequests
    }
    return failedDownloads ?? []
  }
}
