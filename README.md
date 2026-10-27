# SonicWave — a self-hosted music player for iOS, iPadOS, macOS, watchOS, and tvOS

<div align="center">

  <img src=".github/Icon-40.png" alt="SonicWave icon" />

  <br/>

  [![Platform](https://img.shields.io/badge/platform-iOS%2026%2B%20%7C%20iPadOS%20%7C%20macOS%20%7C%20watchOS%20%7C%20tvOS-blue?logo=apple&logoColor=white)](https://github.com/alzimerahmed/SonicWave)
  [![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
  [![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue?logo=gnu&logoColor=white)](LICENSE)
  [![Release](https://img.shields.io/github/v/release/alzimerahmed/SonicWave?logo=github&logoColor=white)](https://github.com/alzimerahmed/SonicWave/releases)
  [![CI](https://img.shields.io/github/actions/workflow/status/alzimerahmed/SonicWave/ci.yml?branch=main&logo=githubactions&logoColor=white)](https://github.com/alzimerahmed/SonicWave/actions)

  *Stream your own music. Any Ampache or Subsonic-API server, one polished native app on every Apple platform.*

  [Download](https://github.com/alzimerahmed/SonicWave/releases) ·
  [Features](#features) ·
  [Screenshots](#screenshots) ·
  [Tech Stack](#tech-stack) ·
  [Building](#building) ·
  [Usage](#usage) ·
  [Roadmap](#roadmap) ·
  [License](#attribution--license) ·
  [Contributing](#contributing)

</div>

---

SonicWave is a GPLv3 music streaming client for self-hosted servers, forked from
[Amperfy](https://github.com/BLeeEZ/amperfy). It speaks the **Ampache API** and the
**Subsonic/OpenSubsonic API**, so it works out of the box with Ampache, Navidrome,
Gonic, Airsonic, Funkwhale, Nextcloud Music, and most other Subsonic-compatible servers.

---

## Features

**Servers & library**
- Ampache API and Subsonic/OpenSubsonic API support
- Multiple accounts — switch between servers without re-syncing
- Music, podcasts, and internet radio in one library
- Server-side scrobbling, 5-star ratings, and favorites synced back to the server
- Synced lyrics (OpenSubsonic + LRCLIB fallback + embedded/LRC files) with line highlighting
- Smart playlists — rule-based local playlists, reads Navidrome `.nsp` files
- Mixes hub — favorites/decade/genre/time-of-day mixes, Instant Mix, autoplay-similar
- Bookmarks, music-folder selector, share-link management, thumbs-down/dislike
- Custom HTTP headers per account (e.g. Cloudflare Access service tokens)
- mTLS client certificates and self-signed-certificate (TOFU) support per account
- Configurable Home tab sections, artist/album enrichment shelves

**Playback**
- Gapless playback with crossfade and per-network streaming quality
- 10-band parametric equalizer (32 Hz – 16 kHz) with presets, AutoEQ profiles,
  and per-output assignment; replay gain; playback speed; skip-silence
- `transcodeOffset` seeking inside transcoded streams
- Audio visualizers: spectrum bars, waveform, ring, and generative art
- Artwork-adaptive player colors, AMOLED option, codec/bitrate badge
- Sleep timer, infinite album shuffle, mini-player gestures, music haptics
- Play-queue persistence with server sync (Subsonic `savePlayQueue`)
- Jukebox mode (Subsonic `jukeboxControl` / Ampache localplay) and UPnP/DLNA push output
- Lidarr integration — send missing albums/artists to Lidarr from the library

**Offline**
- Download songs, albums, playlists, and podcast episodes for offline playback
- Two-tier storage: managed cache (size cap + LRU trim) vs. permanent downloads
- Auto-download favorites, newest items, and playlists after sync
- Dedicated offline mode — cached-only browsing when you're off the grid

**Platform integration**
- CarPlay
- Siri media commands, Siri Shortcuts, and App Intents
- `x-callback-url` automation (`sonicwave://`)
- Interactive Home Screen and Lock Screen widgets, Live Activity / Dynamic Island
- Spotlight indexing — search your library and lyrics system-wide
- watchOS app — Now Playing remote control, Up Next, volume
- tvOS app — full library browsing and playback on Apple TV
- On-device listening statistics and yearly Recap (opt-out available)
- iOS, iPadOS, and macOS (Mac Catalyst) from a single codebase
- Six tint themes with light/dark variants

---

## Screenshots

### iOS

<img src=".github/Screenshots/Player.jpg" width="250" alt="Player view" /> &nbsp;
<img src=".github/Screenshots/AlbumDetail.jpg" width="250" alt="Album detail view" /> &nbsp;
<img src=".github/Screenshots/Library.jpg" width="250" alt="Library view" />

### macOS (Catalyst)

<img src=".github/Screenshots/macOS-Playlist.png" width="750" alt="Playlist view on macOS" />

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 6 (strict concurrency complete) |
| UI | UIKit (storyboards/XIBs) + SwiftUI (settings, watchOS, tvOS) |
| Audio engine | [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) + AVFoundation; parametric EQ, replay gain, crossfade, FFT visualizers |
| Networking | [Alamofire](https://github.com/Alamofire/Alamofire); Ampache XML + Subsonic/OpenSubsonic API clients |
| Persistence | Core Data — 52-version staged migration chain; credentials in Keychain |
| Extensions | WidgetKit widgets + Live Activity, WatchConnectivity, App Intents, Spotlight |
| Layout | [SnapKit](https://github.com/SnapKit/SnapKit) + Interface Builder |
| Platform | iOS 26+, iPadOS, macOS via Catalyst, watchOS, tvOS; CarPlay + Siri entitlements |
| Dependencies | Swift Package Manager (pinned in `Package.resolved`) |
| Tooling | Xcode 26+, [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (Google Swift style) |
| Tests | XCTest — `SonicWaveKitTests` (hosted) |
| CI | GitHub Actions — simulator build + tests, watchOS/tvOS/Catalyst builds, tag-triggered releases |

### Project structure

```
SonicWave/
├── SonicWave.xcodeproj/    # Xcode project — all targets in one project
├── SonicWave/              # App shell: UIKit screens, SwiftUI settings, CarPlay, App Intents
│   ├── Intents/            #   App Intents, x-callback-url registration, Siri handling
│   ├── CarPlay/            #   CarPlay scene + tab templates
│   └── SwiftUI/            #   Settings UI
├── SonicWaveKit/           # Core framework — all logic lives here
│   ├── Api/                #   Ampache + Subsonic/OpenSubsonic clients, parsers, syncers
│   ├── Player/             #   Audio engine, EQ, replay gain, crossfade, visualizers
│   ├── Storage/            #   Core Data stack + settings (52-version staged migrations)
│   ├── Download/           #   Background download manager
│   ├── Analytics/          #   On-device listening stats / Recap
│   ├── Lidarr/             #   Lidarr request client
│   ├── Output/             #   UPnP/DLNA renderer discovery + control
│   └── Assets/             #   Icons, theme artwork, custom SF Symbols
├── SonicWaveWatch/         # watchOS remote-control app (WatchConnectivity)
├── SonicWaveTV/            # tvOS app — kit-reuse library + playback
├── SonicWaveWidgets/       # WidgetKit + Live Activity extension
├── SonicWaveKitTests/      # Unit tests: API parsers, player, storage
├── BuildTools/             # SwiftFormat tooling (applyFormat.sh)
└── Helper/                 # License-header scripts
```

---

## Building

Requirements: **Xcode 26+** (iOS 26 SDK), macOS. SPM dependencies resolve automatically.

1. Clone the repository:
   ```sh
   git clone https://github.com/alzimerahmed/SonicWave.git
   cd SonicWave
   ```
2. Open `SonicWave.xcodeproj` in Xcode.
3. Select the **SonicWave** scheme and build & run (⌘R).

Or grab a prebuilt unsigned `.ipa` from
[Releases](https://github.com/alzimerahmed/SonicWave/releases) — sideload it with
AltStore/Sideloadly or re-sign it yourself.

<details>
<summary><strong>CarPlay & Siri entitlements on physical devices</strong></summary>

`SonicWave/SonicWave.entitlements` contains `com.apple.developer.carplay-audio` and
`com.apple.developer.siri`, which require Apple-approved provisioning profiles.
The simulator works as-is. To build on a device without those entitlements,
clear the entries in `SonicWave/SonicWave.entitlements` — the app runs fine without
CarPlay and Siri.

</details>

<details>
<summary><strong>Running the tests</strong></summary>

In Xcode: select the **SonicWave** scheme and press ⌘U.

From the command line:

```sh
xcodebuild -scheme SonicWave \
  -destination 'platform=iOS Simulator' \
  test -only-testing:SonicWaveKitTests
```

Running tests also applies the project's [SwiftFormat](https://github.com/nicklockwood/SwiftFormat)
style ([Google Swift Style Guide](https://google.github.io/swift), configured in `.swiftformat`).
To format manually: `./BuildTools/applyFormat.sh`.

</details>

---

## Usage

**Connect to a server** (Navidrome used as an example — the flow is identical for
Ampache or any Subsonic-compatible server):

1. Open **Settings → Accounts → +** and choose **Subsonic**.
2. Enter your server URL (`https://music.example.com`), username, and password.
3. SonicWave verifies the connection, then syncs your library in the background.
   Downloads, ratings, and scrobbling are per-account — add a second server any time.

**Automate playback via `x-callback-url`:**

```
sonicwave://x-callback-url/searchAndPlay?searchTerm=Awesome&searchCategory=playlist
```

Registered actions include `searchAndPlay`, `playID`, `playRandomSongs`, `play`,
`pause`, `togglePlayPause`, `playNext`, `playPreviousOrReplay`, `setShuffle`,
`setRepeat`, `setOfflineMode`, `rateCurrentlyPlayingSong`, and
`favoriteCurrentlyPlayingSong`. The full action list with parameters is browsable
in-app under **Settings → x-callback URLs**, and defined in
`SonicWave/Intents/IntentManager.swift`.

---

## Roadmap

- [x] Rebrand to the SonicWave identity (project/target names, bundle ID, icon, URL scheme)
- [x] Time-synced lyrics view (OpenSubsonic structured lyrics + LRCLIB)
- [x] Automatic download sync (favorites, newest, playlists)
- [x] Discovery surface: smart mixes, enrichment shelves, smart playlists
- [x] Home Screen widgets and Live Activities
- [x] watchOS companion app and tvOS app
- [x] Parametric EQ, crossfade, skip-silence, UPnP output, Lidarr
- [ ] Standalone watchOS downloads (no iPhone nearby)
- [ ] Localizations beyond English
- [ ] Jellyfin/Emby backend (under evaluation)

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) and the
[GitHub Releases](https://github.com/alzimerahmed/SonicWave/releases) page.

---

## Attribution & License

SonicWave is a fork of **[Amperfy](https://github.com/BLeeEZ/amperfy)** by
**Maximilian Bauer** ([@BLeeEZ](https://github.com/BLeeEZ)). All upstream copyright
and attribution are preserved as required by the license. SonicWave is maintained
by **Alzimer Ahmed**.

SonicWave is licensed under the
**[GNU General Public License v3](LICENSE)** — the same license as upstream Amperfy.
If you distribute modified versions, you must keep the upstream attribution and
license your changes under GPLv3.

### Third-party dependencies

| Dependency | Purpose | License |
|---|---|---|
| [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) | Streaming audio engine | MIT |
| [Alamofire](https://github.com/Alamofire/Alamofire) | HTTP networking | MIT |
| [SnapKit](https://github.com/SnapKit/SnapKit) | Auto Layout DSL | MIT |
| [MarqueeLabel](https://github.com/cbpowell/MarqueeLabel) | Scrolling labels | MIT |
| [NotificationBanner](https://github.com/Daltron/NotificationBanner) | In-app banners | MIT |
| [ID3TagEditor](https://github.com/chicio/ID3TagEditor) | ID3 tag parsing | MIT |
| [CallbackURLKit](https://github.com/phimage/CallbackURLKit) | x-callback-url handling | MIT |
| [Ifrit](https://github.com/ukushu/Ifrit) | Fuzzy search | MIT |
| [VYPlayIndicator](https://github.com/obrhoff/VYPlayIndicator) | Now-playing indicator | MIT |
| [DominantColors](https://github.com/DenDmitriev/DominantColors) | Artwork-adaptive colors | MIT |
| [AudioVisualizerKit](https://github.com/Kyome22/AudioVisualizerKit) | FFT audio analysis (vendored) | MIT |
| [iOS-swiftUI-spotify-equalizer](https://github.com/urvi-k/iOS-swiftUI-spotify-equalizer) | Visualizer reference (vendored) | MIT |
| [swift-collections](https://github.com/apple/swift-collections) | Data structures | Apache-2.0 |
| [ogg-binary-xcframework](https://github.com/sbooth/ogg-binary-xcframework) / [vorbis-binary-xcframework](https://github.com/sbooth/vorbis-binary-xcframework) | Ogg/Vorbis playback | BSD |
| [CoreDataMigrationRevised-Example](https://github.com/wibosco/CoreDataMigrationRevised-Example) | Staged-migration technique reference | MIT |

**Special thanks:** [Dirk Hildebrand](https://apps.apple.com/us/developer/dirk-hildebrand/id654444924)

---

## Contributing

Pull requests are welcome.

- `SonicWaveKitTests` must pass before merging.
- Code style is enforced by SwiftFormat ([Google Swift Style Guide](https://google.github.io/swift)); run `./BuildTools/applyFormat.sh` or just run the tests.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org).
- GPLv3: contributions are licensed under GPLv3, and upstream Amperfy attribution must be preserved.
