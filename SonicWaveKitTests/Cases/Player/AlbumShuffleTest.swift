//
//  AlbumShuffleTest.swift
//  SonicWaveKitTests
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

@testable import SonicWaveKit
@preconcurrency @testable import AudioStreaming
import AVFoundation
import CoreData
import XCTest

// MARK: - AlbumShuffleTest

/// G21 album-queue shuffle ("album radio"): session grouping, lazy pool
/// appends on queue drain, user-queue precedence, opt-out fallbacks and
/// the `AlbumProgressInfo` computation.
///
/// Seeded albums (account 1 / `TestAccountInfo.create1`):
/// - "59"  Dreams    -> songs "38" (t4), "41" (t5) — all cached
/// - "6BTR0" Let it go -> songs "54".."5e9lll" (t1..t198) — all cached
@MainActor
class AlbumShuffleTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var mockAlertDisplayer: MOCK_AlertDisplayable!
  var mockCoreDataManager: MOCK_CoreDataManager!
  var storage: PersistentStorage!
  var eventLogger: EventLogger!
  var userStatistics: UserStatistics!
  var songDownloader: MOCK_SongDownloader!
  var backendApi: MOCK_BackendApi!
  var networkMonitor: MOCK_NetworkMonitor!
  var backendPlayer: BackendAudioPlayer!
  var mockMusicPlayable: MOCK_MusicPlayable!
  var playerData: PlayerData!
  var testMusicPlayer: SonicWaveKit.AudioPlayer!
  var testPlayer: SonicWaveKit.PlayerFacade!
  var testQueueHandler: SonicWaveKit.PlayQueueHandler!
  var mockAudioStreamingPlayer: MOCK_AudioStreamingPlayer!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    songDownloader = MOCK_SongDownloader()
    mockAudioStreamingPlayer = MOCK_AudioStreamingPlayer()
    mockAlertDisplayer = MOCK_AlertDisplayable()
    mockCoreDataManager = MOCK_CoreDataManager(persistentContainer: cdHelper.persistentContainer)
    storage = PersistentStorage(coreDataManager: mockCoreDataManager)
    eventLogger = EventLogger(storage: storage)
    userStatistics = library.getUserStatistics(appVersion: "")
    backendApi = MOCK_BackendApi()
    networkMonitor = MOCK_NetworkMonitor()
    backendPlayer = BackendAudioPlayer(
      createAudioStreamingPlayerCB: { self.mockAudioStreamingPlayer },
      audioSessionHandler: AudioSessionHandler(),
      eventLogger: eventLogger,
      getBackendApiCB: { accountInfo in self.backendApi },
      networkMonitor: networkMonitor,
      getPlayableDownloaderCB: { accountInfo in self.songDownloader },
      cacheProxy: library,
      userStatistics: userStatistics
    )
    mockMusicPlayable = MOCK_MusicPlayable()
    playerData = library.getPlayerData()
    testQueueHandler = PlayQueueHandler(playerData: playerData)
    testMusicPlayer = AudioPlayer(
      coreData: playerData,
      queueHandler: testQueueHandler,
      backendAudioPlayer: backendPlayer,
      settings: storage.settings,
      userStatistics: userStatistics
    )
    testPlayer = PlayerFacadeImpl(
      playerStatus: playerData,
      queueHandler: testQueueHandler,
      musicPlayer: testMusicPlayer,
      library: library,
      backendAudioPlayer: backendPlayer,
      userStatistics: userStatistics
    )
    testPlayer.addNotifier(notifier: mockMusicPlayable)

    // deterministic defaults — UserDefaults persist between tests
    storage.settings.user.isAutoplayEnabled = false
    storage.settings.user.isPlaybackStartOnlyOnPlay = false
    storage.settings.accounts.updateSetting(account.info) {
      $0.isAlbumShuffleActive = true
    }
  }

  override func tearDown() {
    storage.settings.accounts.updateSetting(account.info) {
      $0.isAlbumShuffleActive = false
    }
  }

  // MARK: helpers

  func album(_ albumId: String) -> Album? {
    let album = library.getAlbum(
      for: account,
      id: albumId,
      isDetailFaultResolution: true
    )
    if album == nil { XCTFail("seeded album \(albumId) missing") }
    return album
  }

  func albumPlayables(_ albumId: String) -> [AbstractPlayable] {
    album(albumId)?.playables ?? []
  }

  func currentAlbumId() -> String? {
    testPlayer.currentlyPlaying?.asSong?.album?.id
  }

  func finishTrack() {
    backendPlayer.responder?.didItemFinishedPlaying()
  }

  // MARK: session start

  func testAlbumShuffle_StartsWithWholeAlbumInTrackOrder() {
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))

    XCTAssertTrue(testPlayer.isShuffle)
    XCTAssertTrue(testPlayer.isAlbumShuffleSessionActive)
    let albumId = currentAlbumId()
    XCTAssertTrue(albumId == "59" || albumId == "6BTR0")
    // only the first shuffled album is in the queue — in album track order
    let expected = albumPlayables(albumId!)
    var queuedIds = testPlayer.getAllNextQueueItems().map { $0.id }
    queuedIds.insert(testPlayer.currentlyPlaying!.id, at: 0)
    XCTAssertEqual(queuedIds, expected.map { $0.id })
  }

  func testAlbumShuffle_SingleAlbumContext_FallsBackToSongShuffle() {
    testPlayer.playShuffled(
      context: PlayContext(name: "Album", playables: albumPlayables("59"))
    )
    // one album = nothing to shuffle across -> regular shuffle semantics
    XCTAssertFalse(testPlayer.isAlbumShuffleSessionActive)
    XCTAssertEqual(testPlayer.nextQueueCount, 1)
    XCTAssertNotNil(testPlayer.currentlyPlaying)
  }

  func testAlbumShuffle_Disabled_FallsBackToSongShuffle() {
    storage.settings.accounts.updateSetting(account.info) {
      $0.isAlbumShuffleActive = false
    }
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))
    XCTAssertFalse(testPlayer.isAlbumShuffleSessionActive)
    // all songs land in the queue, shuffled at song level
    XCTAssertEqual(testPlayer.nextQueueCount, playables.count - 1)
  }

  // MARK: infinite append

  func testAlbumShuffle_AppendsNextAlbumWhenQueueDrains() {
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))

    let firstAlbumId = currentAlbumId()!
    let firstCount = albumPlayables(firstAlbumId).count
    let secondAlbumId = firstAlbumId == "59" ? "6BTR0" : "59"
    let secondCount = albumPlayables(secondAlbumId).count

    for _ in 0 ..< firstCount { finishTrack() }

    // the second album was appended and its first track is playing
    XCTAssertEqual(currentAlbumId(), secondAlbumId)
    XCTAssertEqual(testPlayer.nextQueueCount, secondCount - 1)
    XCTAssertEqual(testPlayer.prevQueueCount, firstCount)
    XCTAssertTrue(testPlayer.isAlbumShuffleSessionActive)
  }

  func testAlbumShuffle_StopsWhenPoolIsExhausted() {
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))

    for _ in 0 ..< playables.count { finishTrack() }

    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertFalse(testPlayer.isAlbumShuffleSessionActive)
  }

  func testAlbumShuffle_UserQueueTakesPrecedenceOverPoolAppend() {
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))

    let firstAlbumId = currentAlbumId()!
    let firstCount = albumPlayables(firstAlbumId).count
    let secondAlbumId = firstAlbumId == "59" ? "6BTR0" : "59"

    // reach the last track of the first album, then queue a user song
    for _ in 0 ..< firstCount - 1 { finishTrack() }
    guard let userSong = library.getSong(for: account, id: "36")
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [userSong])

    finishTrack()
    // the user-queue song plays before the next album materializes
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, userSong.id)

    finishTrack()
    // afterwards the album radio resumes with the next album
    XCTAssertEqual(currentAlbumId(), secondAlbumId)
  }

  // MARK: session end conditions

  func testAlbumShuffle_ToggleShuffleOff_EndsSession() {
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))
    XCTAssertTrue(testPlayer.isAlbumShuffleSessionActive)

    testPlayer.toggleShuffle()
    XCTAssertFalse(testPlayer.isAlbumShuffleSessionActive)
    XCTAssertFalse(testPlayer.isShuffle)

    // no more pool appends — the queued album just drains and stops
    for _ in 0 ..< playables.count { finishTrack() }
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testAlbumShuffle_NewContextPlay_ResetsSession() {
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))
    XCTAssertTrue(testPlayer.isAlbumShuffleSessionActive)

    guard let song = library.getSong(for: account, id: "36") else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "Song", playables: [song]))
    XCTAssertFalse(testPlayer.isAlbumShuffleSessionActive)
  }

  func testAlbumShuffle_RepeatAllSingleItemReplay_SkippedWhilePoolPending() {
    // only album "59" (2 songs) + one loose song? -> use single album "59"
    // twice? Instead: session over two albums, repeat .all, queue drained:
    // the pending album must win over the repeat-all single-item replay
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    testPlayer.playShuffled(context: PlayContext(name: "Albums", playables: playables))
    testPlayer.setRepeatMode(.all)

    let firstAlbumId = currentAlbumId()!
    let firstCount = albumPlayables(firstAlbumId).count
    let secondAlbumId = firstAlbumId == "59" ? "6BTR0" : "59"
    for _ in 0 ..< firstCount { finishTrack() }
    XCTAssertEqual(currentAlbumId(), secondAlbumId)
  }

  // MARK: progress

  func testAlbumShuffle_ProgressComputation() {
    let playables = albumPlayables("59") + albumPlayables("6BTR0")
    for playable in playables { playable.playDuration = 100 }
    let context = PlayContext(name: "Albums", playables: playables)

    guard let plan = AlbumShuffleHandler.planSession(context: context)
    else { XCTFail(); return }
    let handler = AlbumShuffleHandler()
    handler.activate(plan: plan)

    let group = plan.activeGroup
    let first = group.playables[0]
    var info = handler.progress(currentlyPlaying: first, elapsedTime: 30)
    XCTAssertEqual(info?.albumName, group.name)
    XCTAssertEqual(info?.totalTrackCount, group.playables.count)
    XCTAssertEqual(info?.playedTrackCount, 0)
    XCTAssertEqual(info?.totalDurationInSeconds, group.playables.count * 100)
    XCTAssertEqual(info?.playedDurationInSeconds, 30)
    XCTAssertEqual(info?.queuedAlbumCount, 1)
    XCTAssertEqual(info?.nextAlbumName, plan.pendingGroups.first?.name)

    let second = group.playables[1]
    info = handler.progress(currentlyPlaying: second, elapsedTime: 10)
    XCTAssertEqual(info?.playedTrackCount, 1)
    XCTAssertEqual(info?.playedDurationInSeconds, 110)

    // an item outside the active album (e.g. user queue) -> no info
    guard let outsider = library.getSong(for: account, id: "36")
    else { XCTFail(); return }
    XCTAssertNil(handler.progress(currentlyPlaying: outsider, elapsedTime: 5))

    // dequeue flips progress to the next album
    let next = handler.dequeueNextAlbum()
    XCTAssertNotNil(next)
    info = handler.progress(
      currentlyPlaying: next!.playables[0],
      elapsedTime: 0
    )
    XCTAssertEqual(info?.playedTrackCount, 0)
    XCTAssertEqual(info?.queuedAlbumCount, 0)
    XCTAssertNil(info?.nextAlbumName)
    XCTAssertNil(handler.dequeueNextAlbum())
  }

  func testAlbumShuffle_PlanGroupsByAlbumAndSortsTracks() {
    // interleave songs of both albums to prove grouping does not depend
    // on input order
    let a = albumPlayables("59")
    let b = albumPlayables("6BTR0")
    var interleaved = [AbstractPlayable]()
    for i in 0 ..< max(a.count, b.count) {
      if i < a.count { interleaved.append(a[i]) }
      if i < b.count { interleaved.append(b[i]) }
    }
    let context = PlayContext(name: "Albums", playables: interleaved)
    guard let plan = AlbumShuffleHandler.planSession(context: context)
    else { XCTFail(); return }
    let allGroups = [plan.activeGroup] + plan.pendingGroups
    XCTAssertEqual(allGroups.count, 2)
    for group in allGroups {
      // each group is one album in ascending track order
      let albumIds = Set(group.playables.compactMap { $0.asSong?.album?.id })
      XCTAssertEqual(albumIds.count, 1)
      XCTAssertEqual(
        group.playables.map { $0.track },
        group.playables.map { $0.track }.sorted()
      )
    }
  }
}
