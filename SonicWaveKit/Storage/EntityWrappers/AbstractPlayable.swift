//
//  AbstractPlayable.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 29.06.21.
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

import AVFoundation
import CoreData
import Foundation
import UIKit

// MARK: - DerivedPlayableType

public enum DerivedPlayableType: Sendable {
  case song
  case podcastEpisode
  case radio
}

// MARK: - PlayableDownloadTier

/// Two-tier storage for cached playable files (CoreDataMigrationVersion v50):
/// - `cache`: evictable cache — the file may be removed automatically
///   (e.g. by a storage cap / LRU trim or when auto-caching is turned off).
/// - `pinned`: user-pinned download — the file is kept permanently and is
///   never evicted automatically.
/// The tier only has a meaning if a file is present (`isCached == true`);
/// it also expresses the intent for pending/requested downloads.
public enum PlayableDownloadTier: Int16, Sendable {
  case cache = 0
  case pinned = 1
}

// MARK: - PlayableStorageUsage

/// Two-tier storage (G6): per-tier on-disk usage of one account's playable
/// files — produced by `LibraryStorage.getPlayableStorageUsage(for:)` and
/// consumed by the storage settings UI.
public struct PlayableStorageUsage: Sendable, Equatable {
  /// bytes occupied by evictable `.cache`-tier files
  public let cacheTierByteCount: Int64
  /// bytes occupied by user-pinned `.pinned`-tier files (permanent)
  public let pinnedTierByteCount: Int64
  public let cacheTierItemCount: Int
  public let pinnedTierItemCount: Int

  public init(
    cacheTierByteCount: Int64,
    pinnedTierByteCount: Int64,
    cacheTierItemCount: Int,
    pinnedTierItemCount: Int
  ) {
    self.cacheTierByteCount = cacheTierByteCount
    self.pinnedTierByteCount = pinnedTierByteCount
    self.cacheTierItemCount = cacheTierItemCount
    self.pinnedTierItemCount = pinnedTierItemCount
  }

  public var totalByteCount: Int64 {
    cacheTierByteCount + pinnedTierByteCount
  }

  /// the share an LRU trim (`DownloadManageable.trimCacheToLimit`) may reclaim
  public var evictionEligibleByteCount: Int64 {
    cacheTierByteCount
  }
}

// MARK: - AbstractPlayableInfo

public struct AbstractPlayableInfo: Sendable {
  let id: String
  let objectID: NSManagedObjectID
  let type: DerivedPlayableType
  let streamId: String? // Can vary for Subsonic: Podcast Episode -> streamId
}

// MARK: - AbstractPlayable

public class AbstractPlayable: AbstractLibraryEntity, Downloadable {
  /*
   Avoid direct access to the PlayableFile.
   Direct access will result in loading the file into memory and
   it sticks there till the song is removed from memory.
   This will result in memory overflow for an array of songs.
   */
  public let playableManagedObject: AbstractPlayableMO

  public init(managedObject: AbstractPlayableMO) {
    self.playableManagedObject = managedObject
    super.init(managedObject: managedObject)
  }

  override public func imagePath(setting: ArtworkDisplayPreference) -> String? {
    switch setting {
    case .id3TagOnly:
      return embeddedArtwork?.imagePath
    case .serverArtworkOnly:
      return super.imagePath(setting: setting)
    case .preferServerArtwork:
      return artwork?.imagePath ?? embeddedArtwork?.imagePath
    case .preferId3Tag:
      return embeddedArtwork?.imagePath ?? artwork?.imagePath
    }
  }

  public var embeddedArtwork: EmbeddedArtwork? {
    get {
      guard let embeddedArtworkMO = playableManagedObject.embeddedArtwork else { return nil }
      return EmbeddedArtwork(managedObject: embeddedArtworkMO)
    }
    set {
      if playableManagedObject.embeddedArtwork != newValue?
        .managedObject { playableManagedObject.embeddedArtwork = newValue?.managedObject }
    }
  }

  public var threadSafeInfo: DownloadElementInfo? {
    DownloadElementInfo(objectId: objectID, type: .playable)
  }

  public var displayString: String {
    switch derivedType {
    case .podcastEpisode, .song:
      return "\(creatorName) - \(title)"
    case .radio:
      return "\(title)"
    }
  }

  public var creatorName: String {
    switch derivedType {
    case .song:
      return asSong?.creatorName ?? "Unknown"
    case .podcastEpisode:
      return asPodcastEpisode?.creatorName ?? "Unknown"
    case .radio:
      return ""
    }
  }

  public var title: String {
    get { playableManagedObject.title ?? "Unknown Title" }
    set {
      if playableManagedObject.title != newValue {
        playableManagedObject.title = newValue
        updateAlphabeticSectionInitial(section: newValue)
      }
    }
  }

  public var track: Int {
    get { Int(playableManagedObject.track) }
    set {
      guard Int16.isValid(value: newValue),
            playableManagedObject.track != Int16(newValue) else { return }
      playableManagedObject.track = Int16(newValue)
    }
  }

  public var year: Int {
    get { Int(playableManagedObject.year) }
    set {
      guard Int16.isValid(value: newValue),
            playableManagedObject.year != Int16(newValue) else { return }
      playableManagedObject.year = Int16(newValue)
    }
  }

  public var replayGainTrackGain: Float {
    get { playableManagedObject.replayGainTrackGain }
    set {
      guard playableManagedObject.replayGainTrackGain != newValue else { return }
      playableManagedObject.replayGainTrackGain = newValue
    }
  }

  public var replayGainTrackPeak: Float {
    get { playableManagedObject.replayGainTrackPeak }
    set {
      guard playableManagedObject.replayGainTrackPeak != newValue else { return }
      playableManagedObject.replayGainTrackPeak = newValue
    }
  }

  public var replayGainAlbumGain: Float {
    get { playableManagedObject.replayGainAlbumGain }
    set {
      guard playableManagedObject.replayGainAlbumGain != newValue else { return }
      playableManagedObject.replayGainAlbumGain = newValue
    }
  }

  public var replayGainAlbumPeak: Float {
    get { playableManagedObject.replayGainAlbumPeak }
    set {
      guard playableManagedObject.replayGainAlbumPeak != newValue else { return }
      playableManagedObject.replayGainAlbumPeak = newValue
    }
  }

  public var duration: Int { Int(playableManagedObject.combinedDuration) }

  public func updateDuration() -> Bool {
    var isUpdated = false
    let combinedDuration = playableManagedObject.playDuration > 0 ? playableManagedObject
      .playDuration : playableManagedObject.remoteDuration
    if playableManagedObject.combinedDuration != combinedDuration {
      playableManagedObject.combinedDuration = combinedDuration
      isUpdated = true
    }
    return isUpdated
  }

  /// duration based on the data from the xml parser
  public var remoteDuration: Int {
    get { Int(playableManagedObject.remoteDuration) }
    set {
      guard Int16.isValid(value: newValue),
            playableManagedObject.remoteDuration != Int16(newValue) else { return }
      playableManagedObject.remoteDuration = Int16(newValue)
      if playableManagedObject.playDuration == 0 {
        playableManagedObject.combinedDuration = Int16(newValue)
      }
    }
  }

  /// duration based on the downloaded/streamed file reported by the player
  public var playDuration: Int {
    get { Int(playableManagedObject.playDuration) }
    set {
      guard Int16.isValid(value: newValue),
            playableManagedObject.playDuration != Int16(newValue) else { return }
      playableManagedObject.playDuration = Int16(newValue)
      playableManagedObject.combinedDuration = Int16(newValue)
    }
  }

  public var playProgress: Int {
    get { Int(playableManagedObject.playProgress) }
    set {
      guard Int16.isValid(value: newValue),
            playableManagedObject.playProgress != Int16(newValue) else { return }
      playableManagedObject.playProgress = Int16(newValue)
    }
  }

  public var size: Int {
    get { Int(playableManagedObject.size) }
    set {
      guard Int32.isValid(value: newValue),
            playableManagedObject.size != Int32(newValue) else { return }
      playableManagedObject.size = Int32(newValue)
    }
  }

  public var bitrate: Int { // byte per second
    get { Int(playableManagedObject.bitrate) }
    set {
      guard Int32.isValid(value: newValue),
            playableManagedObject.bitrate != Int32(newValue) else { return }
      playableManagedObject.bitrate = Int32(newValue)
    }
  }

  public var contentType: String? {
    get { playableManagedObject.contentType }
    set {
      if playableManagedObject
        .contentType != newValue { playableManagedObject.contentType = newValue }
    }
  }

  public var contentTypeTranscoded: String? {
    get { playableManagedObject.contentTypeTranscoded }
    set {
      if playableManagedObject
        .contentTypeTranscoded !=
        newValue { playableManagedObject.contentTypeTranscoded = newValue }
    }
  }

  public var fileContentType: String? {
    let type = isCached ? (contentTypeTranscoded != nil ? contentTypeTranscoded : contentType)
      : contentType
    return type
  }

  public var iOsCompatibleContentType: String? {
    guard isPlayableOniOS, let type = fileContentType else { return nil }
    return MimeFileConverter.convertToValidMimeTypeWhenNeccessary(mimeType: type)
  }

  public var isPlayableOniOS: Bool {
    guard let originalContenType = fileContentType else { return true }
    return MimeFileConverter.isMimeTypePlayableOniOS(mimeType: originalContenType)
  }

  public var disk: String? {
    get { playableManagedObject.disk }
    set {
      if playableManagedObject.disk != newValue { playableManagedObject.disk = newValue }
    }
  }

  public var url: String? {
    get { playableManagedObject.url }
    set {
      if playableManagedObject.url != newValue { playableManagedObject.url = newValue }
    }
  }

  public var isCached: Bool {
    relFilePath != nil
  }

  /// evictable cache vs. user-pinned download, see `PlayableDownloadTier`
  public var downloadTier: PlayableDownloadTier {
    get { PlayableDownloadTier(rawValue: playableManagedObject.downloadTier) ?? .cache }
    set {
      if playableManagedObject.downloadTier != newValue
        .rawValue { playableManagedObject.downloadTier = newValue.rawValue }
    }
  }

  public var isDownloadPinned: Bool {
    downloadTier == .pinned
  }

  /// local-only dislike flag (#587, CoreDataMigrationVersion v51): both
  /// shipped backends resolve `setDislike`/`clearDislike` to `.localOnly`
  /// (Subsonic rating=0 would destroy the user's stars; the Ampache flag
  /// is favorites-only), so the flag lives purely in the local mirror —
  /// consumed by `SmartPlaylistField.disliked` predicates and UI badges.
  public var isDisliked: Bool {
    get { playableManagedObject.isDisliked }
    set {
      if playableManagedObject.isDisliked != newValue {
        playableManagedObject.isDisliked = newValue
      }
    }
  }

  public var relFilePath: URL? {
    get {
      if let relFilePathString = playableManagedObject.relFilePath {
        return URL(string: relFilePathString)
      }
      return nil
    }
    set {
      playableManagedObject.relFilePath = newValue?.path
    }
  }

  public func deleteCache() {
    switch derivedType {
    case .song:
      asSong?.deleteCache()
    case .podcastEpisode:
      asPodcastEpisode?.deleteCache()
    case .radio:
      break // do nothing
    }
  }

  public var derivedType: DerivedPlayableType {
    isSong ? .song :
      isPodcastEpisode ? .podcastEpisode :
      isRadio ? .radio :
      .song
  }

  public var info: AbstractPlayableInfo {
    AbstractPlayableInfo(
      id: id,
      objectID: objectID,
      type: derivedType,
      streamId: asPodcastEpisode?.streamId
    )
  }

  public var isSong: Bool {
    playableManagedObject is SongMO
  }

  public var asSong: Song? {
    guard isSong, let playableSong = playableManagedObject as? SongMO else { return nil }
    return Song(managedObject: playableSong)
  }

  public var isPodcastEpisode: Bool {
    playableManagedObject is PodcastEpisodeMO
  }

  public var asPodcastEpisode: PodcastEpisode? {
    guard isPodcastEpisode,
          let playablePodcastEpisode = playableManagedObject as? PodcastEpisodeMO
    else { return nil }
    return PodcastEpisode(managedObject: playablePodcastEpisode)
  }

  public var isRadio: Bool {
    playableManagedObject is RadioMO
  }

  public var asRadio: Radio? {
    guard isRadio, let playableRadio = playableManagedObject as? RadioMO else { return nil }
    return Radio(managedObject: playableRadio)
  }

  public func isAvailableToUser() -> Bool {
    switch derivedType {
    case .song:
      return asSong?.isAvailableToUser() ?? false
    case .podcastEpisode:
      return asPodcastEpisode?.isAvailableToUser() ?? false
    case .radio:
      return asRadio?.isAvailableToUser() ?? false
    }
  }

  public func infoDetails(for api: ServerApiType?, details: DetailInfoType) -> [String] {
    var infoContent = [String]()
    if details.type == .long {
      if year > 0 {
        infoContent.append("Year \(year)")
      }
      if duration > 0 {
        infoContent.append("\(duration.asDurationString)")
      }
      if bitrate > 0 {
        infoContent.append("Bitrate \(bitrate)")
      }
      if details.isShowDetailedInfo {
        if isCached {
          if let contentType = contentType, let fileContentType = fileContentType,
             contentType != fileContentType {
            infoContent.append("Transcoded MIME Type: \(fileContentType)")
            infoContent.append("Original MIME Type: \(contentType)")
          } else if let contentType = contentType {
            infoContent.append("Cache MIME Type: \(contentType)")
          } else if let fileContentType = fileContentType {
            infoContent.append("Cache MIME Type: \(fileContentType)")
          }
        }
      }
    }
    return infoContent
  }

  override public func getDefaultArtworkType() -> ArtworkType {
    switch derivedType {
    case .song:
      return .song
    case .podcastEpisode:
      return .podcastEpisode
    case .radio:
      return .radio
    }
  }

  override public func playedViaContext() {
    // keep empty to ignore context based play
  }

  public func countPlayed() {
    lastTimePlayed = Date()
    playCount += 1
  }
}

// MARK: PlayableContainable

extension AbstractPlayable: PlayableContainable {
  public var name: String { title }
  public var subtitle: String? { creatorName }
  public var subsubtitle: String? { asSong?.album?.name }
  public var playables: [AbstractPlayable] {
    [self]
  }

  public var playContextType: PlayerMode {
    switch derivedType {
    case .radio, .song:
      return .music
    case .podcastEpisode:
      return .podcast
    }
  }

  @MainActor
  public func fetchFromServer(
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    playableDownloadManager: DownloadManageable
  ) async throws {
    guard let song = asSong else { return }
    try await librarySyncer.sync(song: song)
  }

  public var isRateable: Bool {
    switch derivedType {
    case .song:
      return true
    case .podcastEpisode, .radio:
      return false
    }
  }

  public var isFavoritable: Bool {
    switch derivedType {
    case .song:
      return true
    case .podcastEpisode, .radio:
      return false
    }
  }

  @MainActor
  public func remoteToggleFavorite(syncer: LibrarySyncer) async throws {
    guard let song = asSong else { return }
    guard let context = song.managedObject.managedObjectContext else {
      throw BackendError.persistentSaveFailed
    }
    isFavorite.toggle()
    let library = LibraryStorage(context: context)
    library.saveContext()
    try await syncer.setFavorite(song: song, isFavorite: isFavorite)
  }

  public var isDownloadAvailable: Bool {
    switch derivedType {
    case .song:
      return true
    case .podcastEpisode:
      return asPodcastEpisode?.isAvailableToUser() ?? false
    case .radio:
      return false
    }
  }

  public func getArtworkCollection(theme: ThemePreference) -> ArtworkCollection {
    ArtworkCollection(defaultArtworkType: getDefaultArtworkType(), singleImageEntity: self)
  }

  public var containerIdentifier: PlayableContainerIdentifier {
    let containerType = switch derivedType {
    case .song:
      PlayableContainerBaseType.song
    case .podcastEpisode:
      PlayableContainerBaseType.podcastEpisode
    case .radio:
      PlayableContainerBaseType.radio
    }

    return PlayableContainerIdentifier(
      type: containerType,
      objectID: playableManagedObject.objectID.uriRepresentation().absoluteString
    )
  }
}

extension Array where Element: AbstractPlayable {
  public func filterCached() -> [Element] {
    filter { $0.isCached }
  }

  public func filterCached(dependigOn isFilterActive: Bool) -> [Element] {
    isFilterActive ? filter { $0.isCached } : self
  }

  public func filterCustomArt() -> [Element] {
    filter { $0.artwork != nil }
  }

  public var hasCachedItems: Bool {
    lazy.filter { $0.isCached }.first != nil
  }

  public var isCachedCompletely: Bool {
    filterCached().count == count
  }

  public func sortById() -> [Element] {
    sorted { $0.id < $1.id }
  }

  public func sortByTitle() -> [Element] {
    sortById().sorted { $0.title < $1.title }
  }

  public func sortByTrackNumber() -> [Element] {
    sortById().sorted { $0.track < $1.track }
  }

  public func filterSongs() -> [Song] {
    compactMap { $0.asSong }
  }
}
