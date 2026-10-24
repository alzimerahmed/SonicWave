//
//  DownloadManager.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import os.log

public typealias VoidAsyncClosure = @MainActor () async -> ()
public typealias PreDownloadIsValidCB = @Sendable (_ downloadInfos: [DownloadElementInfo]) async
  -> [DownloadElementInfo]

// MARK: - DownloadOperation

class DownloadOperation: AsyncOperation, @unchecked Sendable {
  private let lock = NSLock()

  public init(completeBlock: @escaping VoidAsyncClosure) {
    self.completeBlock = completeBlock
  }

  override public func main() {
    Task {
      await withCheckedContinuation { conti in
        Task {
          var continueExecution = true
          lock.withLock {
            if isCancelled {
              continueExecution = false
              conti.resume()
            } else {
              continuation = conti
            }
          }
          guard continueExecution else { return }
          await self.completeBlock()
        }
      }
      finish()
    }
  }

  override open func cancel() {
    super.cancel()

    complete()
  }

  public func complete() {
    lock.withLock {
      continuation?.resume()
      continuation = nil
    }
  }

  private let completeBlock: VoidAsyncClosure
  private var continuation: CheckedContinuation<(), Never>?
}

// MARK: - DownloadManager

actor DownloadManager: NSObject, DownloadManageable {
  internal var urlSession: URLSession?
  internal var tasks = [URLSessionTask: DownloadTaskInfo]()
  internal let log: OSLog
  internal let taskQueue: OperationQueue
  internal let fileManager = CacheFileManager.shared

  private let name: String
  private let networkMonitor: NetworkMonitorFacade
  private let storage: AsyncCoreDataAccessWrapper
  private let requestManager: DownloadRequestManager
  private let getDownloadDelegateCB: GetDownloadManagerDelegateCB
  private let notificationHandler: EventNotificationHandler
  private let eventLogger: EventLogger
  private let settings: AmperfySettings
  private let urlCleanser: URLCleanser
  /// per-account TLS policy — answers server-trust (self-signed TOFU pin) and
  /// client-certificate (mTLS) challenges for this account's sessions
  /// (internal — the URLSession-delegate extension lives in a separate file)
  internal let sessionSecurity: AccountSessionSecurity

  private var isRunning = false
  private var taskOperations = [DownloadRequest: DownloadOperation]()
  private var backgroundFetchCompletionHandler: CompleteHandlerBlock?
  private var isFailWithPopupError: Bool = true
  private var preDownloadIsValidCheck: PreDownloadIsValidCB?
  @MainActor
  private var isCheckForCachedNeeded: Bool = true
  private var isCacheSizeLimited: Bool
  @MainActor
  private var _urlSessionIdentifier: String?
  /// two-tier storage (G6): LRU-trims the evictable `.cache` tier to the
  /// account's configured cap — only used by cache-limited managers
  /// (playables); `AmperfySettings` reads through to UserDefaults so the
  /// provider always sees the current setting value
  private lazy var cacheEvictionHandler = CacheEvictionHandler(
    storage: storage,
    accountObjectId: requestManager.accountObjectId,
    accountInfo: requestManager.accountInfo,
    cacheSizeLimitBytesProvider: { [settings] accountInfo in
      settings.accounts.getSetting(accountInfo).read.cacheSizeLimitBytes
    }
  )

  init(
    name: String,
    storage: AsyncCoreDataAccessWrapper,
    requestManager: DownloadRequestManager,
    getDownloadDelegateCB: @escaping GetDownloadManagerDelegateCB,
    eventLogger: EventLogger,
    settings: AmperfySettings,
    networkMonitor: NetworkMonitorFacade,
    notificationHandler: EventNotificationHandler,
    urlCleanser: URLCleanser,
    sessionSecurity: AccountSessionSecurity,
    limitCacheSize: Bool,
    isFailWithPopupError: Bool
  ) {
    self.name = name
    self.log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: name)
    self.storage = storage
    self.requestManager = requestManager
    self.getDownloadDelegateCB = getDownloadDelegateCB
    self.eventLogger = eventLogger
    self.settings = settings
    self.networkMonitor = networkMonitor
    self.notificationHandler = notificationHandler
    self.urlCleanser = urlCleanser
    self.sessionSecurity = sessionSecurity
    self.isCacheSizeLimited = limitCacheSize
    self.isFailWithPopupError = isFailWithPopupError
    self.taskQueue = OperationQueue()

    super.init()
  }

  @MainActor
  public func initialize(
    urlSession: URLSession,
    isCheckForCachedNeeded: Bool,
    validationCB: PreDownloadIsValidCB?
  ) {
    taskQueue.maxConcurrentOperationCount = getDownloadDelegateCB().parallelDownloadsCount

    notificationHandler.register(
      self,
      selector: #selector(networkStatusChanged(notification:)),
      name: .offlineModeChanged,
      object: nil
    )
    notificationHandler.register(
      self,
      selector: #selector(networkStatusChanged(notification:)),
      name: .networkStatusChanged,
      object: nil
    )
    Task {
      await _initialize(
        urlSession: urlSession,
        isCheckForCachedNeeded: isCheckForCachedNeeded,
        validationCB: validationCB
      )
    }
  }

  @MainActor
  public var urlSessionIdentifier: String? {
    _urlSessionIdentifier
  }

  private func _initialize(
    urlSession: URLSession,
    isCheckForCachedNeeded: Bool,
    validationCB: PreDownloadIsValidCB?
  ) {
    self.urlSession = urlSession
    let ident = self.urlSession?.configuration.identifier
    preDownloadIsValidCheck = validationCB
    Task { @MainActor in
      self.isCheckForCachedNeeded = isCheckForCachedNeeded
      _urlSessionIdentifier = ident
    }
  }

  nonisolated func getBackgroundFetchCompletionHandler() async -> CompleteHandlerBlock? {
    await Task {
      await backgroundFetchCompletionHandler
    }.value
  }

  nonisolated func setBackgroundFetchCompletionHandler(_ newValue: CompleteHandlerBlock?) {
    Task {
      await _setBackgroundFetchCompletionHandler(newValue)
    }
  }

  private func _setBackgroundFetchCompletionHandler(_ newValue: CompleteHandlerBlock?) {
    backgroundFetchCompletionHandler = newValue
  }

  @MainActor
  func download(object: Downloadable, asTier tier: PlayableDownloadTier) {
    guard let downloadInfo = object.threadSafeInfo else { return }
    if isCheckForCachedNeeded, object.isCached {
      // promotion (G6): an explicit user download of an auto-cached item
      // upgrades it .cache -> .pinned; the file is already on disk so no
      // fetch is needed — only the tier intent is persisted
      if tier == .pinned {
        Task.detached {
          await self.requestManager.markTier(downloadInfo: downloadInfo, tier: .pinned)
        }
      }
      return
    }

    Task.detached {
      let isStorageExceeded = await self.storageExceedsCacheLimit()
      guard await !self.isCacheSizeLimited || !isStorageExceeded
      else { return }

      var validDls = [downloadInfo]
      if let isValidCheck = await self.preDownloadIsValidCheck {
        validDls = await isValidCheck(validDls)
        guard !validDls.isEmpty else { return }
      }

      guard let request = await self.requestManager
        .add(downloadInfo: downloadInfo, tier: tier)
      else { return }
      guard await self.isAllowedToTriggerDownload else { return }
      await self.addDownloadTaskOperation(downloadRequest: request)
    }
  }

  @MainActor
  func download(objects: [Downloadable], asTier tier: PlayableDownloadTier) {
    let downloadObjects = objects.filter { !isCheckForCachedNeeded || !$0.isCached }
      .compactMap { $0.threadSafeInfo }
    if isCheckForCachedNeeded, tier == .pinned {
      // promotion (G6): explicitly re-downloaded cached items become .pinned
      let cachedInfos = objects.filter { $0.isCached }.compactMap { $0.threadSafeInfo }
      if !cachedInfos.isEmpty {
        Task.detached {
          await self.requestManager.markTier(downloadInfos: cachedInfos, tier: .pinned)
        }
      }
    }
    guard !downloadObjects.isEmpty else { return }

    Task.detached {
      let isStorageExceeded = await self.storageExceedsCacheLimit()
      guard await !self.isCacheSizeLimited || !isStorageExceeded
      else { return }

      var validDls = downloadObjects
      if let isValidCheck = await self.preDownloadIsValidCheck {
        validDls = await isValidCheck(validDls)
      }

      guard !validDls.isEmpty else { return }
      let requests = await self.requestManager.add(downloadInfos: validDls, tier: tier)
      guard await self.isAllowedToTriggerDownload else { return }
      for request in requests {
        await self.addDownloadTaskOperation(downloadRequest: request)
      }
    }
  }

  @MainActor
  func removeFinishedDownload(for object: Downloadable) {
    Task {
      await requestManager.removeFinishedDownload(for: object.uniqueID)
    }
  }

  @MainActor
  func removeFinishedDownload(for objects: [Downloadable]) {
    Task {
      await requestManager.removeFinishedDownload(for: objects.compactMap { $0.uniqueID })
    }
  }

  @MainActor
  func removeDownload(for object: Downloadable) {
    Task {
      await requestManager.removeDownload(for: object.uniqueID)
    }
  }

  @MainActor
  func cancelDownload(for object: Downloadable) {
    let uniqueID = object.uniqueID
    Task {
      await _cancelDownload(uniqueID: uniqueID)
    }
  }

  /// per-item cancel for the downloads queue UI (G6): the CoreData flag
  /// goes first — an in-flight task completion re-reads the entry, sees
  /// `isCanceled`, and skips error reporting + the failed-download
  /// delegate, leaving the row in the canceled state.
  private func _cancelDownload(uniqueID: String) async {
    await requestManager.cancelDownload(for: uniqueID)
    if let (task, _) = tasks.first(where: { $0.value.request.id == uniqueID }) {
      // keep the task in `tasks` — didCompleteWithError routes through
      // finishDownload which cleans up tasks/taskOperations itself
      task.cancel()
    } else if let taskOperation = taskOperations
      .first(where: { $0.key.id == uniqueID }) {
      // still queued — cancel before a URLSessionTask is ever created
      taskOperation.value.cancel()
      taskOperations.removeValue(forKey: taskOperation.key)
    }
  }

  nonisolated func start() {
    Task {
      await _start()
    }
  }

  func _start() async {
    isRunning = true
    if isCacheSizeLimited {
      // two-tier (G6): launch sweep — the .cache tier may have grown past
      // the cap while the app was closed (or the cap was lowered)
      await trimCacheToLimit()
    }
    await setupDownloadQueue()
  }

  nonisolated func stop() {
    Task {
      await self._stop()
    }
  }

  private func _stop() {
    isRunning = false
    cancelDownloads()
  }

  nonisolated func cancelDownloads() {
    Task {
      await self._cancelDownloads()
    }
  }

  private func _cancelDownloads() async {
    tasks.removeAll()
    taskQueue.cancelAllOperations()
    taskOperations.removeAll()
    await requestManager.cancelDownloads()
    guard let urlSessionTasks = await urlSession?.allTasks else { return }
    for task in urlSessionTasks {
      task.cancel()
    }
  }

  nonisolated func suspendDownloads() {
    Task {
      await self._suspendDownloads()
    }
  }

  private func _suspendDownloads() async {
    os_log("Suspend active downloads", log: self.log, type: .info)
    tasks.removeAll()
    let objectIDs = taskOperations.compactMap { $0.key.objectID }
    try? await storage.perform { asyncCompanion in
      for objectID in objectIDs {
        let download = Download(
          managedObject: asyncCompanion.context
            .object(with: objectID) as! DownloadMO
        )
        download.suspend()
      }
      asyncCompanion.saveContext()
    }

    taskOperations.removeAll()
    taskQueue.cancelAllOperations()
    guard let urlSessionTasks = await urlSession?.allTasks else { return }
    for task in urlSessionTasks {
      task.cancel()
    }
  }

  nonisolated func clearFinishedDownloads() {
    Task {
      await _clearFinishedDownloads()
    }
  }

  private func _clearFinishedDownloads() async {
    await requestManager.clearFinishedDownloads()
  }

  /// two-tier storage (G6): LRU-trims the evictable `.cache` tier to the
  /// account's configured cap (`AccountSetting.cacheSizeLimitBytes`).
  /// Called after each completed download, once on `start()` (launch sweep)
  /// and by the storage settings UI when the cap changes.
  /// `.pinned` downloads are never touched. No-op for managers without
  /// cache limiting (e.g. artwork).
  @discardableResult
  nonisolated func trimCacheToLimit() async -> Int {
    guard await isCacheSizeLimited else { return 0 }
    return await cacheEvictionHandler.trimToLimit()
  }

  nonisolated func resetFailedDownloads() {
    Task {
      await _resetFailedDownloads()
    }
  }

  func _resetFailedDownloads() async {
    let failedRequests = await requestManager.getAndResetFailedDownloads()
    guard isAllowedToTriggerDownload else { return }
    for failedRequest in failedRequests {
      addDownloadTaskOperation(downloadRequest: failedRequest)
    }
  }

  func storageExceedsCacheLimit() -> Bool {
    guard settings.user.cacheLimit != 0 else { return false }
    return fileManager.completePlayableCacheSize > settings.user.cacheLimit
  }

  private func setupDownloadQueue() async {
    guard isAllowedToTriggerDownload else { return }
    let downloadRequests = await requestManager.getRequestedDownloads()
    for downloadRequest in downloadRequests {
      addDownloadTaskOperation(downloadRequest: downloadRequest)
    }
  }

  private func addDownloadTaskOperation(downloadRequest: DownloadRequest) {
    let existingOperation = taskOperations[downloadRequest]
    // the operation must be unique
    guard existingOperation == nil else { return }
    let asyncOperation = DownloadOperation {
      await self.manageDownload(downloadRequest: downloadRequest)
    }
    taskOperations[downloadRequest] = asyncOperation
    taskQueue.addOperation(asyncOperation)
  }

  private func manageDownload(downloadRequest: DownloadRequest) async {
    guard isAllowedToTriggerDownload else {
      taskOperations[downloadRequest]?.complete()
      taskOperations.removeValue(forKey: downloadRequest)
      return
    }
    try? await storage.perform { asyncCompanion in
      let download = Download(
        managedObject: asyncCompanion.context
          .object(with: downloadRequest.objectID) as! DownloadMO
      )
      download.reset()
      download.isDownloading = true
      asyncCompanion.saveContext()
    }
    os_log("Fetching %s ...", log: self.log, type: .info, downloadRequest.title)

    do {
      let url = try await getDownloadDelegateCB().prepareDownload(
        downloadInfo: downloadRequest.info,
        storage: storage
      )
      let httpHeaders = await getDownloadDelegateCB().httpHeaders
      let downloadTaskInfo = DownloadTaskInfo(
        request: downloadRequest,
        url: url,
        httpHeaders: httpHeaders
      )
      fetch(downloadTaskInfo: downloadTaskInfo)
    } catch {
      if let fetchError = error as? DownloadError {
        await finishDownload(downloadRequest: downloadRequest, task: nil, error: fetchError)
      } else {
        await finishDownload(downloadRequest: downloadRequest, task: nil, error: .fetchFailed)
      }
    }
  }

  func finishDownload(
    downloadRequest: DownloadRequest,
    task: URLSessionTask?,
    error: DownloadError
  ) async {
    // connectivity loss is not a failure — the request is deferred (no
    // error/finish date) so the networkStatusChanged / offlineModeChanged
    // sweep re-queues it on recovery instead of leaving a permanent
    // download error behind (G16 auto-offline)
    let isDeferred = error == .noConnectivity
    let isCanceled = try? await storage.performAndGet { asyncCompanion in
      let download = Download(
        managedObject: asyncCompanion.context
          .object(with: downloadRequest.objectID) as! DownloadMO
      )
      if isDeferred {
        download.suspend()
      } else {
        if !download.isCanceled {
          download.error = error
        }
        download.isDownloading = false
      }
      asyncCompanion.library.saveContext()
      return download.isCanceled
    }
    if let isCanceled, !isCanceled, !isDeferred {
      await getDownloadDelegateCB().failedDownload(
        downloadInfo: downloadRequest.info,
        storage: storage
      )
    }
    if let isCanceled, !isCanceled, !isDeferred, error != .apiErrorResponse,
       error != .alreadyDownloaded {
      os_log(
        "Fetching %s FAILED: %s",
        log: self.log,
        type: .info,
        downloadRequest.title,
        error.description
      )
      let shortMessage =
        "Error \"\(error.description)\" occurred while downloading object \"\(downloadRequest.title)\"."
      let responseError = ResponseError(
        type: .api,
        message: shortMessage,
        cleansedURL: task?.originalRequest?.url?.asCleansedURL(cleanser: urlCleanser)
      )
      await eventLogger.report(
        topic: "Download Error",
        error: responseError,
        displayPopup: isFailWithPopupError
      )
    }

    if let task { tasks.removeValue(forKey: task) }
    taskOperations[downloadRequest]?.complete()
    taskOperations.removeValue(forKey: downloadRequest)
  }

  func finishDownload(
    downloadRequest: DownloadRequest,
    task: URLSessionTask,
    fileURL: URL,
    fileMimeType: String?
  ) async {
    // mid-flight cancel race: the entry was flagged canceled while the
    // operation was between queueing and task completion — honor the
    // cancel, drop the fetched temp file, and route through the normal
    // finish path instead of completing the download
    let isCanceled = try? await storage.performAndGet { asyncCompanion in
      let download = Download(
        managedObject: asyncCompanion.context
          .object(with: downloadRequest.objectID) as! DownloadMO
      )
      return download.isCanceled
    }
    if isCanceled == true {
      try? FileManager.default.removeItem(at: fileURL)
      await finishDownload(downloadRequest: downloadRequest, task: task, error: .canceled)
      return
    }

    let responseError = await getDownloadDelegateCB().validateDownloadedData(
      fileURL: fileURL,
      downloadURL: task.originalRequest?.url
    )

    if let responseError {
      os_log(
        "Fetching %s API-ERROR StatusCode: %d, Message: %s",
        log: log,
        type: .error,
        downloadRequest.title,
        responseError.statusCode,
        responseError.message
      )
      await eventLogger.report(
        topic: "Download",
        error: responseError,
        displayPopup: isFailWithPopupError
      )
      await finishDownload(downloadRequest: downloadRequest, task: task, error: .apiErrorResponse)
      return
    }

    os_log(
      "Fetching %s SUCCESS (%{iec-bytes}d) (%s)",
      log: self.log,
      type: .info,
      downloadRequest.title,
      fileManager.getFileSize(url: fileURL) ?? 0,
      fileMimeType ?? "no MIME type"
    )
    await getDownloadDelegateCB().completedDownload(
      downloadInfo: downloadRequest.info,
      fileURL: fileURL,
      fileMimeType: fileMimeType,
      storage: storage
    )

    let downloadElementUniqueId = try? await storage.performAndGet { asyncCompanion in
      let download = Download(
        managedObject: asyncCompanion.context
          .object(with: downloadRequest.objectID) as! DownloadMO
      )
      download.isDownloading = false
      asyncCompanion.saveContext()
      return download.element?.uniqueID
    }
    if let downloadElementUniqueId {
      await notificationHandler.post(
        name: .downloadFinishedSuccess,
        object: self,
        userInfo: DownloadNotification(id: downloadElementUniqueId).asNotificationUserInfo
      )
    }
    if isCacheSizeLimited {
      // two-tier (G6): LRU-trim the evictable .cache tier after each
      // completed download — cheap no-op while under the account cap;
      // trimming first keeps the legacy global cache limit from
      // cancelling pending downloads when only evictable items overflow
      await trimCacheToLimit()
      if storageExceedsCacheLimit() {
        await requestManager.cancelDownloads()
      }
    }
    tasks.removeValue(forKey: task)
    taskOperations[downloadRequest]?.complete()
    taskOperations.removeValue(forKey: downloadRequest)
  }

  private var isAllowedToTriggerDownload: Bool {
    isRunning &&
      settings.user.isOnlineMode &&
      networkMonitor.isConnectedToNetwork &&
      (!isCacheSizeLimited || !storageExceedsCacheLimit())
  }

  @objc
  nonisolated private func networkStatusChanged(notification: Notification) {
    Task {
      guard await isRunning else { return }
      if await isAllowedToTriggerDownload {
        os_log(
          "Download Manager (%s): Online Mode | Internet; setup download queue",
          log: self.log,
          type: .info,
          self.name
        )
        await setupDownloadQueue()
      } else {
        os_log(
          "Download Manager (%s): Offline Mode | No Internet; suspend downloads",
          log: self.log,
          type: .info,
          self.name
        )
        suspendDownloads()
      }
    }
  }
}
