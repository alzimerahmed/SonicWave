# SonicWave — Rules for AI Agents

## Project

SonicWave = open-source music player for **iOS + iPadOS + macOS (Catalyst)** (Swift), forked from Amperfy (upstream: https://github.com/BLeeEZ/amperfy, fork base `master@f889ef39`, ~v2.1.1). Streams from self-hosted servers: **Ampache API** and **Subsonic API** (Navidrome, Gonic, Airsonic, Funkwhale, Nextcloud Music). Core surfaces: offline downloads, CarPlay, gapless playback + EQ/ReplayGain/visualizers, music+podcast+radio, Siri/App Intents, scrobbling, multi-account. The highest-severity defect surfaces are **CoreData persistence (manual staged migrations, fatalError on failure), the AudioStreaming player pipeline, per-account service lifecycle (`MetaManager`), and plaintext credential storage** (Keychain migration is a planned phase).

**License:** GPL-3.0. Upstream `LICENSE` and copyright headers in existing source files must be preserved — GPLv3 does not permit stripping attribution. New files get the header from `Helper/license-header.txt` (already updated to Alzimer Ahmed). Upstream PayPal/funding/AppStore-badge assets were removed in the fork sweep — do not restore.

**Scope:** Single `SonicWave.xcodeproj` (no `Package.swift` at root, no `.xcworkspace`) — 3 targets: `SonicWave` app, `SonicWaveKit` framework (**all logic lives here**), `SonicWaveKitTests` (hosted unit tests, `TEST_HOST = SonicWave.app`). Rebrand (Phase 4) is complete — dirs, targets, bundle IDs (`com.alzimerahmed.*`), `sonicwave://` scheme, and notification names all carry the SonicWave identity; some internal `Amper*` type names still stand (see Gotchas — typos are API).

## Ground Truth (read first)

- **`docs/architecture.md`** is the architecture & conventions ground truth — read it before touching code. `docs/research.md` (ADRs/gotchas) and `docs/CONCEPTS.md` (vocabulary) back it up. `docs/` is fully gitignored — private, never push.
- **`AGENTS.md`** (this file) is the workflow/rules layer — the only tracked agent doc.
- `.swiftformat` + `BuildTools/applyFormat.sh` own style (Google Swift Style, `--indent 2 --maxwidth 100`) — don't hand-police what the formatter owns.

## How It Works (domain constraints — read before touching the code)

- **App shell vs. kit:** `SonicWave/` = UI only (UIKit screens, SwiftUI settings, CarPlay, Intents). `SonicWaveKit/` = everything else (`Api/`, `Player/`, `Storage/`, `Download/`, `Common/`). New logic goes in the kit.
- **DI = service locator:** `AmperKit.shared` (sic — typo is baked in) is `@MainActor`, lazily vends storage/settings/player/eventLogger + per-account `MetaManager` graph. `player` is lazy — remote commands don't work until first access. Global `appDelegate` accessor couples every VC to AppDelegate.
- **Scenes are 100% programmatic** — `Info.plist` has no `UISceneConfigurations`. `AppDelegate.configurationForConnecting` dispatches: `.carTemplateApplication` → CarPlay, `com.alzimerahmed.sonicwave.settings` → Settings scene, `com.alzimerahmed.sonicwave.miniplayer` → MiniPlayer scene, else `SceneDelegate` → Login/Sync/Update/main split.
- **Persistence:** CoreData container "SonicWave", **49 staged model versions**, manual `CoreDataMigrator` (no auto-migration, `fatalError` on load fail). A schema change needs ALL 5 steps: new model version + `CoreDataMigrationVersion` entry + mapping + `LibrarySyncVersion` bump + `LibraryUpdater` step. Settings = Codable JSON in **UserDefaults — including plaintext passwords** (security debt). `AsyncCoreDataAccessWrapper.perform` swallows errors then saves — don't use it for integrity-critical writes.
- **Player = `AudioStreaming` SPM, not AVPlayer:** `AudioStreamingPlayer` + `attach(nodes:)` → 10-band EQ + ReplayGain mixer + visualizer taps; gapless via `nextPlayablePreloadCB`. `PlayerFacade` is the only API surface app code may call. Queues: `prev`/`next`/`user` on `PlayerData` MO.
- **API layer:** Ampache (sha256-time passphrase → session token) + Subsonic (md5-salt `t`/`s`, legacy plaintext fallback, version negotiated to 1.11.0). `BackendProxy` auto-detects ampache→subsonic→subsonic_legacy. `getOpenSubsonicExtensions` is the feature-gate point for new server capabilities (only `songLyrics` used today). **Always log `CleansedURL`s — never credentials.**
- **Syncers per API** (`AmpacheLibrarySyncer` 1460L, `SubsonicLibrarySyncer` 1430L) populate the CoreData mirror; `LibraryStorage.swift` (**3071 lines, highest-risk file**) owns all queries + duplicate resolution.
- **Cross-process notification names** (`com.alzimerahmed.sonicwave.*`, `com.alzimerahmed.SonicWave.*`) are API — renames break CarPlay/multi-window. Don't rename ad hoc.

## Tech Stack & Conventions (do not fight it)

- **Xcode 26+ required** (iOS 26 SDK, `LastUpgradeCheck 2600`, Icon Composer `.icon`, `UITab`/glass APIs). `SWIFT_VERSION = 6.0` + `SWIFT_STRICT_CONCURRENCY = complete` + all upcoming features — `@MainActor`/Sendable are compiler-enforced, not convention. Deployment iOS **26.0** all targets; `SUPPORTS_MACCATALYST = YES`.
- **SPM deps inside `project.pbxproj`**, all `exactVersion` pins: AudioStreaming 1.4.4 (+ogg/vorbis bins, SnapKit), Alamofire 5.6.2, MarqueeLabel 4.5.3, NotificationBanner 3.2.0, ID3TagEditor 4.6.0, CallbackURLKit 3.0.0, Ifrit 2.0.3, swift-collections 1.1.4, VYPlayIndicator 1.5.4, DominantColors 1.2.2. Vendored: `AudioVisualizerKit`, `iOS-SpotifyEquilizerView`.
- **No localization** — English hardcoded strings; l10n infra is a planned phase.
- **Commits:** Conventional Commits (`type(scope): description`). Work on `main` (fresh repo, no develop branch yet).
- **Upstream:** remote removed by design. Cherry-pick from `BLeeEZ/amperfy` only if deliberately decided — prefer additive changes so cherry-picks stay cheap.
- **Brand identity:** rebrand done in Phase 4 — bundle IDs are `com.alzimerahmed.SonicWave*`, dirs/targets/scheme are `SonicWave*`, URL scheme `sonicwave://`, BGTask ID `com.alzimerahmed.SonicWave.RefreshTask`, notification names `com.alzimerahmed.sonicwave.*`/`com.alzimerahmed.SonicWave.*`. Upstream `Amperfy` strings survive only in GPL copyright headers, `LICENSE`, and README attribution — never touch those.

## Build / Verify

```bash
# CI only — .github/workflows/ci.yml (push to main, PRs to main):
#   macos runner w/ Xcode 26 → xcodebuild -resolvePackageDependencies
#   → xcodebuild -project SonicWave.xcodeproj -scheme SonicWave -configuration Debug
#       -destination 'platform=iOS Simulator,name=iPhone 17'
#       CODE_SIGNING_ALLOWED=NO build-for-testing
#   → test-without-building -only-testing:SonicWaveKitTests
```

**Remote-first verification (mandatory):** this workspace is **Windows — we do NOT build or test locally.** No Xcode here; local work is edit-only + static review. Push and let GitHub Actions verify — a CI green check counts as the gate.

**No secret-dependent jobs:** CI builds/tests unsigned on the simulator — never add steps needing signing certs, App Store Connect keys, or real server credentials.

## Removed on Purpose — Do NOT Re-add

- `.github/FUNDING.yml` (upstream PayPal), `.github/AppStore/` store badges (upstream's App Store listing — not ours), empty `.gitmodules`.
- Upstream ownership strings replaced: GitHub links → `alzimerahmed/SonicWave`, support email → `alzimerahmed84@gmail.com`, `ORGANIZATIONNAME`, `NSHumanReadableCopyright`, LaunchScreen copyright, license-header template.
- Do NOT remove upstream copyright headers in existing source files or `LICENSE` (GPLv3 legal requirement), and do NOT remove upstream attribution from README.
- `Intents.intentdefinition` stays — its `INPlayMediaIntent` mediaContainer combination is the Siri media-suggestions opt-in; deleting it kills Siri/lock-screen suggestions.
- Dead scheme refs removed in Phase 2 (upstream names): `AmperfyTests`/`AmperfyUITests` testables (deleted targets), `AmperfyIntents.xcscheme` (dead appex), appex `BuildActionEntry` in `DebugCoreData.xcscheme` — don't reintroduce testables or appex entries for removed targets.

## Gotchas

- **No local build safety net** — grep all references (`project.pbxproj`, entitlements, `Info.plist`, schemes, imports, URL scheme) before deleting or renaming anything.
- **Schemes:** `SonicWave` (shared) builds app+kit and tests `SonicWaveKitTests` only — CI still passes `-only-testing:SonicWaveKitTests` explicitly. `DebugCoreData.xcscheme` is a CoreData-debug utility, not for CI.
- **SwiftFormat build phase on `SonicWaveKitTests` mutates all sources** during `xcodebuild test` and compiles SwiftFormat from source on first run (~minutes) — cache `BuildTools/.build` in CI; expect format diffs after test runs.
- **Typos are API:** `AmperKit`, `BackenApiType`, `isVisualUpadateNeeded` — rename only in coordinated passes. (`AmpertyKitTests`/`AmpertyKit` typos were fixed in the Phase 4 rebrand; `Amper*` type-name family remains.)
- **Hosted tests** (`TEST_HOST = SonicWave.app`): `xcodebuild test` builds the full app first — CI time ≈ 2 builds.
- `MacWindowHelper` uses undocumented ObjC-runtime `NSWindow` hacking — fragile, App-Store-risky.
- `UIRequiredDeviceCapabilities = armv7` is stale; `NSAllowsArbitraryLoads = YES` is required for self-hosted HTTP servers.
- Windows checkout: shell scripts (`*.sh`) and plist XML are line-ending sensitive — write LF.

## Agent Guidelines & Workflow (this repo's .devin system)

### Resource Discipline (mandatory, non-trivial tasks)
Before any non-trivial task:
1. Read `docs/toolset.md` intent-map (task type → resources)
2. Invoke every skill + sub-agent in that row
3. Read every rule for that task type (`.devin/rules/`)
4. At task end: `code-reviewer` sub-agent on final diff (non-negotiable)
5. Append learnings via `/ce-compound` if durable lesson

Phase implementations follow `.devin/prompt/phase.md`; quick tasks follow `.devin/prompt/quick.md` + `.devin/prompt/rules.md`. Skip all this for single-line edits, pure Q&A, reading files.

### Project-Type Filter (native iOS/macOS Swift app)
Per `docs/toolset.md` intent-map:
- **Skip irrelevant:** css-architect (no CSS), pwa-engineer (native app — keep offline-*patterns* only), web-scraper, design-cloner, monorepo-manager (single `.xcodeproj`), email-engineer (no email surface), payment-integrator (GPLv3 FOSS, no purchases), seo-specialist (deferred → ASO at ship phase).
- **Keep universal:** code-reviewer, debugger, test-engineer, security-auditor, performance-engineer, git-master, migration-specialist, docs-writer, build-optimizer, devops-engineer, dx-optimizer, caveman-compressor, vibe-coding-auditor.
- **Keep domain-fit:** media-optimizer (audio pipeline = core), animation-engineer, design-system-builder, frontend-designer (SwiftUI/UIKit taste, anti-slop), content-writer, backend-architect (API layer), state-manager, database-engineer (CoreData 49-version migrations), file-handler (downloads = core), search-architect (library search + Ifrit), realtime-engineer (WatchConnectivity/CarPlay/Live Activities phases), i18n-specialist (greenfield l10n), type-safety-engineer (Swift 6 strict concurrency), a11y-specialist (VoiceOver), analytics-engineer (local-only event log/user stats), pixel-analyst, researcher.
- **Quality gates:** CI-only — unsigned simulator build + `SonicWaveKitTests` on GitHub Actions macOS runner. No local builds.

## Communication Style

Default **caveman-lite** (lightly compressed, readable, technically accurate). `/caveman` skill for full/ultra/wenyan modes.

## Key References

> `docs/` is the private knowledge layer — **fully gitignored**, local workspace only. `AGENTS.md` is the only tracked agent doc.

- `docs/toolset.md` — intent map (task type → skills, sub-agents, rules)
- `docs/plan.md` — phased plan + status (covers all `idea.md` gap items)
- `docs/project.md` — project state/structure
- `docs/tools-log.md` — .devin resources invoked per session
- `docs/CONCEPTS.md` — project vocabulary
- `docs/research.md` — research, ADRs, gotchas, open questions
- `docs/idea.md` — competitive analysis + Feature Gap List
- `docs/design/design-system.md` — UI tokens + rules
- `docs/architecture.md` — architecture ground truth
