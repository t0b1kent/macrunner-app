<p align="center">
  <img src="assets/macrunner-icon.png" width="128" height="128" alt="MacRunner app icon">
</p>

<h1 align="center">MacRunner</h1>

<p align="center"><strong>Your Windows apps. Your Mac.</strong></p>

<p align="center">A native Mac app. An independently developed translation engine for Apple Silicon.</p>

<p align="center">
  <a href="#the-experience">The experience</a> ·
  <a href="HYPERBRIDGE.md">HyperBridge engine</a> ·
  <a href="#tested-games--engines">Tested games &amp; engines</a> ·
  <a href="#progress">Progress</a> ·
  <a href="https://github.com/t0b1kent/macrunner-app/issues/1">Vote for the next title</a> ·
  <a href="RELEASE_STATUS.md">Release status</a> ·
  <a href="#contributors--credits">Contributors &amp; credits</a>
</p>

---

MacRunner is built around a simple idea: **choose an app or game, add it to your library, and launch it from one familiar Mac interface.** The application brings together the runtime, graphics components, settings, and diagnostics needed to make that experience possible.

**The next chapter is HyperBridge:** MacRunner's own **x86-64 → ARM64 translation engine for Windows x64 software on Apple Silicon**. The project is moving toward an **open-source engine release under MIT**, with Wine providing Windows API compatibility and Metal handling graphics through the relevant translation components. [Explore the engine, its current scope and roadmap →](HYPERBRIDGE.md)

**Development preview.** HyperBridge integration is in progress. The installed app and game results below come from earlier runtime configurations and will be retested on the independent engine. Public source and download links will be added when those artifacts are published.

## Tested games & engines

**Test Mac:** MacBook Pro · **Apple M1 Pro** (8-core CPU / 14-core GPU) · **32 GB unified memory** · **macOS 27.0**. [Full machine details below.](#development-mac)

**Earlier runtime results — HyperBridge retests pending.** These sessions establish MacRunner's development baseline; they are **not HyperBridge compatibility or FPS results**. The game engine is the technology the game itself was built with; the graphics column shows the path used during each check. [Exact test configurations →](TESTED_GAMES.md)

| Game | Game engine | Graphics path | Recorded result | FPS |
| --- | --- | --- | --- | --- |
| **Hollow Knight** | Unity | DXMT → Metal | **Working** | **60** |
| **Divinity: Original Sin — Enhanced Edition** | Divinity Engine | DXMT → Metal | **Working** | **100** |
| **Factorio** | Custom engine (Wube) | DXMT → Metal | **Working** | Not measured |
| **Vampire Survivors** | Unity (IL2CPP) | DXMT → Metal | **Working** | Not measured |
| **Hedon Bloodrite** | GZDoom | OpenGL → Metal (Apple driver) | **Working** | Not measured |
| **DOOM 64** | KEX (PC re-release) | OpenGL → Metal (Apple driver) | **Working** | Not measured |
| **Ion Fury** | Build / EDuke32 | Software rendering | **Working** | Not measured |
| **Dome Keeper** | Godot | OpenGL → Metal (Apple driver) | **Working** | Not measured |
| **WRATH: Aeon of Ruin** | DarkPlaces (Quake-derived) | OpenGL → Metal (Apple driver) | **Working** | Not measured |
| **Elden Ring** | FromSoftware in-house engine | DXMT-based DirectX 12 → Metal | **Working** | Not measured |

**OpenGL → Metal** means the game uses OpenGL through Wine and Apple's Metal-backed OpenGL driver on the test Mac. This is a separate path from DXMT and D3DMetal. [How to read the graphics paths →](TESTED_GAMES.md#reading-the-graphics-paths)

**Working** means gameplay works in the tested configuration. Hollow Knight was checked through the current installed app on September 23; the other rows record checks of specific development configurations. **[Test dates, verified functions and remaining issues →](TESTED_GAMES.md)**

**FPS values are maintainer-reported gameplay observations on the test Mac**, reported on September 24, 2026. Resolution, graphics settings, scene and sample duration have not yet been recorded for these figures. “Not measured” means a result is still pending, not zero FPS.

**Why these games?** Together they exercise Unity, Godot, custom engines and Doom/Build/Quake-derived technology, across Direct3D 11, Direct3D 12, OpenGL and software rendering. This variety helps find issues shared by different kinds of games. Results remain title-specific. [Game engines and test coverage →](TESTED_GAMES.md#game-engines--test-coverage)

## Contributors & credits

| Person, tool or project | Role |
| --- | --- |
| **[t0b1kent](https://github.com/t0b1kent)** | Project creator and maintainer |
| **Jev** | Special thanks |
| **Claude · Anthropic** | AI assistance during development |
| **Codex · OpenAI** | AI assistance during development, review and validation |
| **Wine contributors** | Windows API compatibility |
| **HyperBridge development** | MacRunner's independently developed x86-64 → ARM64 translation core and ongoing Wine integration |
| **DXMT contributors** | Direct3D 10/11 translation to Metal |
| **MacRunner DirectX 12 development** | DXMT-based DirectX 12 → Metal integration, shader and runtime work; [Elden Ring gameplay confirmed by the maintainer](TESTED_GAMES.md#elden-ring--tested--working) |
| **Apple Metal, Swift and SwiftUI teams** | Native graphics and application foundations |
| **All other upstream authors and maintainers** | [Dependency acknowledgements, component provenance and earlier runtime credits](CREDITS.md) |

These credits recognise people, development tools and upstream projects. GitHub's sidebar separately lists authors of commits to this public presentation repository. Acknowledgements do not imply affiliation or endorsement.

## The experience

| 1 · Choose | 2 · Add | 3 · Launch |
| --- | --- | --- |
| Pick the Windows app or game you want to use. | Keep your games and apps together in one library. | Start it from the app and follow its status in one place. |

### Made to feel at home on macOS

- **A native interface.** Built with SwiftUI, with a library, settings, and diagnostic tools inside a regular Mac app.
- **One place for your software.** Find your games and apps together in your MacRunner library.
- **A complete bundle.** The local preview packages the app, runtime, and graphics components together; a HyperBridge-based bundle is the next integration target.
- **Updates designed to stay in sync.** The update system is being prepared to deliver that complete bundle through MacRunner.
- **12 interface languages.** Localization resources are included and checked for consistency.

## Progress

| Milestone | What it means |
| --- | --- |
| **Independent HyperBridge core** | CPU translation, arithmetic, memory, translated-code cache and native-call mechanisms have focused validation. Full application integration remains in progress. |
| **Native Mac app** | Local preview 1.0.2 builds and packages successfully. |
| **Automated application checks** | Launch status, installation, localization, packaging and update coordination are covered by passing checks. |
| **45,998 shaders** | The separate DirectX 12 development path passes native loading and parsing/reflection checks for this shader corpus. |
| **27 targeted GPU frames** | Geometry-shader tests pass, including indexed drawing. These are controlled tests, not full game validation. |

### Current focus: HyperBridge integration and graphics

**HyperBridge integration is the engine priority.** Once the remaining integration checks pass, real application and game checks will be repeated on the independent engine, including startup, gameplay, saving and clean exit.

**Elden Ring remains the graphics optimization focus.** DirectX 12 gameplay was confirmed by the maintainer on the earlier development configuration. Graphics work has also reached shader-loading and targeted GPU-validation milestones. **Ray-tracing research** has passed isolated shadow/radiance and acceleration-structure tests; full in-game DXR remains in development. These results do not yet establish the same game's operation on HyperBridge. [Read the scope of each milestone →](RELEASE_STATUS.md)

**Windows x64 is the primary focus; full Windows x86 / 32-bit support is a future milestone.** Native Windows ARM64 application support requires separate Wine validation and is not confirmed yet. [Host and Windows architectures →](HYPERBRIDGE.md#host-and-windows-architectures)

Apple Developer account approval is also pending. Account approval alone will not complete 32-bit implementation or compatibility testing.

## How it works

**Architecture being integrated for HyperBridge:**

| Part of a Windows program | Path to your Mac |
| --- | --- |
| CPU instructions | Windows x86-64 → HyperBridge → ARM64 instructions on Apple Silicon |
| Windows system calls and APIs | Wine → macOS |
| Direct3D 10/11 graphics | DXMT → Metal → Apple GPU |
| DirectX 12 graphics development | MacRunner's DXMT-based DirectX 12 path → Metal → Apple GPU |

HyperBridge handles **CPU translation**; Wine and the graphics components perform different jobs. **Metal is the native graphics backend.** Windows APIs, CPU instructions, and shaders still need translation. The separate DirectX 12 development path is not included in the current preview bundle. [Engine boundaries and integration status →](HYPERBRIDGE.md)

## Availability

MacRunner is intended for **Macs with Apple Silicon**. The current development bundle contains libraries that require **macOS 27.0**. A broader supported macOS range and launch on Macs with standard security settings have not yet been validated.

**HyperBridge's MIT license is selected; its open-source release is planned.** This repository currently contains the project presentation, [engine license information](HYPERBRIDGE_LICENSE.md) and progress reports, not engine or application source code. There is no public installer yet.

Next: prepare the engine's source package, dependency notices and reproducible build instructions; complete integration and repeat the app/game checks; prepare signed distribution and validate real updates. [Engine release roadmap →](HYPERBRIDGE.md#open-source-release-roadmap) · [App release status →](RELEASE_STATUS.md)

## Help choose what's next

Help choose which **games and apps to validate and optimize on HyperBridge next**: add a 👍 reaction to an existing title, or suggest one title per comment. Elden Ring remains a graphics-development priority.

**[Vote or suggest a title →](https://github.com/t0b1kent/macrunner-app/issues/1)**

A vote guides priorities; it is not a promise of compatibility or a release date.

## Development Mac

The current primary development and test machine is:

| | |
| --- | --- |
| Mac | MacBook Pro |
| Chip | Apple M1 Pro |
| CPU | 8 cores · 6 performance + 2 efficiency |
| GPU | 14 cores |
| Unified memory | 32 GB |
| Operating system | macOS 27.0 · build 26A428 |

This is the machine used for current development, not a minimum specification or certification of other Macs.

## Built with a lot of help

MacRunner develops **HyperBridge** alongside its integration with **Wine, DXMT and Metal**. Supporting libraries and earlier development foundations are acknowledged in the full credits. Development has been assisted by **Claude** and **Codex**. Special thanks to **Jev**.

We want the people and projects behind this work to be visible. [Meet the foundations and acknowledgements →](CREDITS.md)

---

<p align="center"><sub>Independent engine development · Open-source release planned · Updated September 24, 2026</sub></p>
