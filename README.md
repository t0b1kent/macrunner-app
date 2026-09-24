<p align="center">
  <img src="assets/macrunner-icon.png" width="128" height="128" alt="MacRunner app icon">
</p>

<h1 align="center">MacRunner</h1>

<p align="center"><strong>Your Windows apps. Your Mac.</strong></p>

<p align="center">A native macOS app for bringing Windows software to Apple Silicon.</p>

<p align="center">
  <a href="#the-experience">The experience</a> ·
  <a href="#tested-games--engines">Tested games &amp; engines</a> ·
  <a href="#progress">Progress</a> ·
  <a href="https://github.com/t0b1kent/macrunner-app/issues/1">Vote for the next title</a> ·
  <a href="RELEASE_STATUS.md">Release status</a> ·
  <a href="#contributors--credits">Contributors &amp; credits</a>
</p>

---

MacRunner is built around a simple idea: **choose an app or game, add it to your library, and launch it from one familiar Mac interface.** The application brings together the runtime, graphics components, settings, and diagnostics needed to make that experience possible.

**Currently in local preview.** Hollow Knight has been played through the installed app on the development Mac, including a successful launch and normal exit in the latest user check. Broader compatibility, public downloads and automatic update delivery are being prepared. [See the tested games and engines below.](#tested-games--engines)

## Tested games & engines

**Test Mac:** MacBook Pro · **Apple M1 Pro** (8-core CPU / 14-core GPU) · **32 GB unified memory** · **macOS 27.0**. [Full machine details below.](#development-mac)

**Compatibility runtime: FEX + Wine.** The game engine is the technology the game itself was built with; the graphics column shows the path used to run it on this Mac.

| Game | Game engine | Graphics path | Status | FPS |
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
| **FEX contributors** | x86/x86-64 translation technology |
| **DXMT contributors** | Direct3D 10/11 translation to Metal |
| **MacRunner DirectX 12 development** | DXMT-based DirectX 12 → Metal integration, shader and runtime work; [Elden Ring gameplay confirmed by the maintainer](TESTED_GAMES.md#elden-ring--tested--working) |
| **Apple Metal, Swift and SwiftUI teams** | Native graphics and application foundations |
| **All other upstream authors and maintainers** | [Complete project and dependency acknowledgements](CREDITS.md) |

These credits recognise people, development tools and upstream projects. GitHub's sidebar separately lists authors of commits to this public presentation repository. Acknowledgements do not imply affiliation or endorsement.

## The experience

| 1 · Choose | 2 · Add | 3 · Launch |
| --- | --- | --- |
| Pick the Windows app or game you want to use. | Keep your games and apps together in one library. | Start it from the app and follow its status in one place. |

### Made to feel at home on macOS

- **A native interface.** Built with SwiftUI, with a library, settings, and diagnostic tools inside a regular Mac app.
- **One place for your software.** Find your games and apps together in your MacRunner library.
- **A complete bundle.** The app, runtime, and graphics components are packaged as one matched version.
- **Updates designed to stay in sync.** The update system is being prepared to deliver that complete bundle through MacRunner.
- **12 interface languages.** Localization resources are included and checked for consistency.

## Progress

| Milestone | What it means |
| --- | --- |
| **Native Mac app** | Local preview 1.0.2 builds and packages successfully. |
| **Automated application checks** | Launch status, installation, localization, packaging and update coordination are covered by passing checks. |
| **45,998 shaders** | The separate DirectX 12 development path passes native loading and parsing/reflection checks for this shader corpus. |
| **27 targeted GPU frames** | Geometry-shader tests pass, including indexed drawing. These are controlled tests, not full game validation. |

### Current focus: Elden Ring

**Elden Ring is tested and working on the DirectX 12 path**, as confirmed by the maintainer. Current optimization work focuses on rendering quality and performance. Graphics development has also reached shader-loading and targeted GPU-validation milestones. **Ray-tracing research** has passed isolated shadow/radiance and acceleration-structure tests; full in-game DXR remains in development.

These graphics results belong to a separate development branch. The current app bundle uses an experimental **Wine/FEX/DXMT path for 64-bit Direct3D 10/11**. Individual games still need their own compatibility checks. [Read the exact scope of each milestone →](RELEASE_STATUS.md)

**Full 32-bit Windows support is still in development.** Apple Developer account approval is also pending. Account approval alone will not complete 32-bit implementation or compatibility testing.

## How it works

| Part of a Windows program | Path to your Mac |
| --- | --- |
| CPU instructions | Windows x86-64 → FEX translation → Apple Silicon CPU |
| Windows system calls and APIs | Wine → macOS |
| Direct3D 10/11 graphics in the current bundle | DXMT → Metal → Apple GPU |

**Metal is the native graphics backend.** Windows APIs, CPU instructions, and shaders still need translation. The separate DirectX 12 development path also targets Metal; it is not included in the current preview bundle.

## Availability

MacRunner is intended for **Macs with Apple Silicon**. The current development bundle contains libraries that require **macOS 27.0**. A broader supported macOS range and launch on Macs with standard security settings have not yet been validated.

There is no public installer yet. This repository is the project's public presentation and progress page; application source code and binaries are not included here.

Next: validate the complete app workflow, prepare signed distribution, and test real updates between installed versions. [See what's ready and what's next →](RELEASE_STATUS.md)

## Help choose what's next

Elden Ring is the current focus. Help choose which **games and apps to optimize next**: add a 👍 reaction to an existing title, or suggest one title per comment.

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

MacRunner builds on the work of **Wine, FEX, DXMT**, and the many projects that support them. Development has been assisted by **Claude** and **Codex**. Special thanks to **Jev**.

We want the people and projects behind this work to be visible. [Meet the foundations and acknowledgements →](CREDITS.md)

---

<p align="center"><sub>Independent project · Experimental preview · Updated September 23, 2026</sub></p>
