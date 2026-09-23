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

**Current installed app — September 23:** Hollow Knight gameplay, launching and normal exit have been confirmed by the tester on the development Mac.

| Game | Runtime & graphics | Observed result | FPS |
| --- | --- | --- | --- |
| **Hollow Knight** | FEX + Wine + DXMT → Metal | **Gameplay confirmed in the current app**, including a successful entry/exit cycle | Not measured |
| **Factorio** | FEX + Wine + DXMT → Metal | Earlier check: tutorial gameplay, save and reload confirmed | Not measured |
| **Vampire Survivors** | FEX + Wine + DXMT → Metal | Earlier check: gameplay, movement, audio and exit confirmed | Not measured |
| **Hedon Bloodrite** | FEX + Wine + OpenGL | Earlier check: gameplay, controls, audio and save/reload confirmed | Not measured |
| **DOOM 64** | FEX + Wine + OpenGL | Earlier check: in-level rendering, controls, audio and save/load confirmed | Not measured |
| **Ion Fury** | FEX + Wine + software rendering | Earlier check: gameplay, save/load and exit confirmed; accelerated OpenGL unresolved | Not measured |
| **Dome Keeper** | FEX + Wine + OpenGL | Earlier check: movement, audio and saved-state continuation confirmed | Not measured |
| **WRATH: Aeon of Ruin** | FEX + Wine + OpenGL | Earlier check: gameplay, audio and loading confirmed | Not measured |
| **Elden Ring** | FEX + Wine + DXMT-based DirectX 12 → Metal | **Tested & working — DirectX 12**, confirmed by the maintainer; optimization continues | Not measured |

The earlier checks used development configurations and have not all been repeated in the current app. They are recorded results, not a compatibility guarantee. **[Test dates, paths and remaining issues →](TESTED_GAMES.md)**

**FPS results will be added after timed gameplay checks**, with resolution, graphics settings and the tested scene recorded. “Not measured” is a pending measurement, not a zero-FPS result.

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
