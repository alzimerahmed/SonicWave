CHANGELOG
=========

See the changes in each release here: [https://github.com/alzimerahmed/SonicWave/releases](https://github.com/alzimerahmed/SonicWave/releases)

1.0.0 (2026-10-27)
------------------

First SonicWave release — a full re-engineering of the Amperfy codebase with
12 development phases of new features on top of the fork base (Amperfy ~v2.1.1).

**Identity & platform**
- Rebrand to SonicWave end-to-end: directories, Xcode project, targets, and
  schemes renamed (`Amperfy` → `SonicWave`, `AmperfyKit` → `SonicWaveKit`,
  `AmperfyKitTests` → `SonicWaveKitTests`); bundle identifiers moved to
  `com.alzimerahmed.SonicWave*`; URL scheme `amperfy://` → `sonicwave://`;
  cross-process notification names moved to `com.alzimerahmed.sonicwave.*`;
  CoreData model bundle, background-task identifier, OSLog subsystem,
  `INAlternativeAppName`, and Siri vocabulary updated to match. Upstream
  Amperfy copyright headers and attribution remain intact (GPLv3).
- New app icon (Icon Composer, iOS 26 liquid-glass pipeline).
- New platforms: `SonicWaveWatch` (watchOS remote control via WatchConnectivity)
  and `SonicWaveTV` (tvOS library + playback on shared SonicWaveKit).
- Home/lock-screen widgets, Live Activity / Dynamic Island, Spotlight indexing
  with lyric search, expanded App Intents.

**Playback & discovery**
- Synced lyrics (LRCLIB fallback + embedded/LRC), artwork-adaptive player
  theming + AMOLED option, infinite album shuffle, mini-player gestures,
  music haptics, codec/bitrate badge.
- Crossfade/transitions, skip-silence, per-network streaming quality,
  `transcodeOffset` seeking, parametric EQ with AutoEQ profiles and per-output
  assignment, playback speed, Opus→transcode handling, gapless repairs.
- Mixes hub, smart playlists (+ Navidrome `.nsp` read), artist/album
  enrichment shelves, share-link management, thumbs-down/dislike, bookmarks,
  music-folder selector, jukebox + UPnP/DLNA output, Lidarr requests,
  on-device listening statistics/Recap.

**Offline & security**
- Two-tier cache vs. download with caps + LRU trim, auto-sync downloads,
  play-queue persistence + server sync, auto-offline on unreachable server.
- Credentials migrated from UserDefaults plaintext to Keychain (passwords,
  custom HTTP headers, mTLS client certs, Lidarr API key).
- mTLS client-certificate + self-signed-certificate (TOFU pinning) support,
  `PrivacyInfo.xcprivacy` manifest.
- Quality-gate pass: CoreData memory-pinning fix, UPnP same-origin hardening,
  VoiceOver labels + minimum hit targets on player controls, Reduce-Motion
  support for visualizers/marquee, syncer page-count and GROUP BY fixes.
