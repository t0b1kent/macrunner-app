# Tested games & engines

**Last updated: September 24, 2026**

This page records what has actually been observed while developing MacRunner. A title in the library or launch-profile catalog is not automatically a tested game. Results apply to the configurations used for those sessions.

**HyperBridge transition:** the game sessions and FPS figures on this page were recorded using earlier runtime configurations. **They are not HyperBridge compatibility or performance results.** The independent engine is being integrated and will receive its own application/game validation. [HyperBridge status and roadmap →](HYPERBRIDGE.md)

## Test Mac

| Component | Test configuration |
| --- | --- |
| Mac | MacBook Pro |
| Chip | Apple M1 Pro |
| CPU | 8 cores: 6 performance + 2 efficiency |
| GPU | 14 cores |
| Unified memory | 32 GB |
| Current OS | macOS 27.0, build 26A428 |

This is the primary development machine. Historical checks do not establish that each earlier session used this exact OS build. [Current installation requirements and release readiness →](RELEASE_STATUS.md)

## FPS measurements

The FPS values below are **maintainer-reported gameplay observations on the test Mac**, reported on September 24, 2026. Resolution, graphics settings, scene and sample duration have not yet been recorded, so these figures are not standardized benchmark averages or minimums. **Not measured** means a result is still pending. Future benchmark checks will record these conditions alongside frame timings.

**Historical test runtime: FEX + Wine.** All game entries below used that earlier runtime. Its identity is retained to make the results reproducible; these checks will not be relabelled as HyperBridge runs. The graphics path is listed separately for each game.

## Game engines & test coverage

The **game engine** is the technology used to build the game. It is separate from the CPU compatibility runtime and graphics translation. The short **Working** result on the main page describes the earlier tested configuration; the detailed results below identify the functions actually checked.

| Game | Game engine | What this adds to the test set |
| --- | --- | --- |
| **Hollow Knight** | [Unity](https://unity.com/made-with-unity/hollow-knight) | A Unity title running through Direct3D 11 → Metal. |
| **Divinity: Original Sin — Enhanced Edition** | [Divinity Engine](https://forums.larian.com/ubbthreads.php?Number=580882&ubb=showflat) | Larian's RPG engine using Direct3D 11 → Metal. |
| **Factorio** | [Custom engine (Wube)](https://www.factorio.com/blog/post/fff-230) | A custom renderer and simulation workload. |
| **Vampire Survivors** | Unity (IL2CPP) | The tested Unity build uses an IL2CPP-compiled game assembly; a different Unity execution path. |
| **Hedon Bloodrite** | GZDoom | Doom-derived engine technology using OpenGL. |
| **DOOM 64** | KEX (PC re-release) | The PC re-release's KEX framework and OpenGL path. |
| **Ion Fury** | [Build / EDuke32](https://3drealms.com/games/ion-fury/) | Build-derived technology using the tested software renderer. |
| **Dome Keeper** | [Godot](https://godotengine.org/showcase/dome-keeper/) | A Godot title using OpenGL. |
| **WRATH: Aeon of Ruin** | [DarkPlaces (Quake-derived)](https://github.com/Official3DRealms/wrath-darkplaces) | Quake-derived 3D engine technology using OpenGL. |
| **Elden Ring** | [FromSoftware in-house engine](https://careers.fromsoftware.jp/jp/interview_008.html) | A proprietary modern 3D engine using the DirectX 12 → Metal development path. |

This selection provides coverage across different engines, runtime requirements and graphics APIs. A result applies to the tested game and configuration; other titles using the same engine still need their own checks.

Engine labels describe the inspected game versions. In particular, **Vampire Survivors** refers to the tested Unity/IL2CPP build, and **DOOM 64** refers to the PC re-release. Local runtime evidence identifies UnityPlayer/GameAssembly for Vampire Survivors, GZDoom resources for Hedon, KEX in the DOOM 64 runtime, and EDuke32 in Ion Fury.

## September 23 installed-app check

| Game | Graphics path | Check date | Confirmed result | FPS | Still to verify |
| --- | --- | --- | --- | --- | --- |
| **Hollow Knight** | **DXMT: Direct3D 11 → Metal** | September 23, 2026 | The tester confirmed gameplay and subsequently a successful launch, game entry and normal exit in the installed app. FPS reported on September 24. | **60** | Repeated-run reliability, long sessions, save/reload, complete cinematic playback and a timed benchmark with recorded settings. |

A title-specific startup correction was applied. Missing media components were also added and passed isolated component checks. An earlier session required MacRunner's Stop button after the game had been exited; the latest user check completed normally. Startup duration and residual-process cleanup were not independently measured in that latest session.

## Earlier development checks

These results came from earlier development configurations. **They have not all been retested in the current packaged app.** The dates identify the checks, not public release dates.

| Game | Graphics path | Check date | What was verified | FPS | Remaining limits |
| --- | --- | --- | --- | --- | --- |
| **Divinity: Original Sin — Enhanced Edition** | DXMT: Direct3D 11 → Metal | September 14, 2026 | User-confirmed gameplay and menu navigation. The maintainer reported 100 FPS on September 24; the FPS observation is separate from the earlier development check. | **100** | Save/reload, voluntary exit, long sessions and complete automated graphics-path verification. The earlier run ended through a test timer. |
| **Factorio** | DXMT: Direct3D 11 → Metal | September 11, 2026 | User-confirmed tutorial gameplay, saving, returning to the menu and reloading. | Not measured | Long sessions and measured performance were not established. |
| **Vampire Survivors** | DXMT: Direct3D 11 → Metal | September 11, 2026 | User-confirmed gameplay, movement, audio and voluntary exit, with a gameplay screenshot. | Not measured | Long-session stability and measured performance were not established. |
| **Hedon Bloodrite** | OpenGL → Metal (Apple driver) | September 12, 2026 | User-confirmed gameplay, keyboard/mouse, audio, saving and reload at the saved position; clean exits recorded. | Not measured | Broader scene coverage and long-session performance were not established. |
| **DOOM 64** | OpenGL → Metal (Apple driver) | September 12, 2026 | In-level rendering, mouse, audio and save/load; a subsequent English-keyboard-layout check confirmed keyboard operation. Intro/attract sequence and voluntary exit were also accepted. | Not measured | Other keyboard layouts and long sessions need further testing. |
| **Ion Fury** | Software renderer | September 12, 2026 | User-confirmed gameplay, save/load and voluntary exit. | Not measured | Accelerated OpenGL remained unresolved. This was not a GPU-accelerated rendering result. |
| **Dome Keeper** | OpenGL → Metal (Apple driver) | September 12, 2026 | Movement, audio, return to menu and continuation of saved state; a repeated mining-scene run with voluntary exit. | Not measured | Shutdown resource warnings remained; longer sessions need verification. |
| **WRATH: Aeon of Ruin** | OpenGL → Metal (Apple driver) | September 14, 2026 | User-confirmed gameplay, audio and loading. | Not measured | The run ended through a test timer. Manual save/reload, voluntary exit and long sessions were not verified. |

## Elden Ring — tested & working

**Status: Tested & working — DirectX 12.**

**FPS: Not measured.**

**Path:** FEX + Wine + MacRunner's **DXMT-based DirectX 12 → Metal** development path, separate from the current preview app's Direct3D 10/11 bundle.

The maintainer confirmed on **September 23, 2026** that the game had already been launched successfully with DirectX 12 and was working in gameplay. This newer confirmation supersedes the earlier September 16 menu-only status. The status describes the tested configuration.

**Current focus: further optimization**, including rendering quality and performance. Full in-game ray tracing remains in development. [Detailed graphics progress →](RELEASE_STATUS.md#directx-12-development)

## Reading the graphics paths

- **DXMT → Metal:** Direct3D 10/11 graphics are translated to Apple's Metal API and executed by the GPU. Translation is still involved.
- **OpenGL → Metal (Apple driver):** the game uses OpenGL through Wine, and macOS executes those graphics calls through Apple's Metal-backed OpenGL driver on the tested M1 Pro. Metal participates, but this is separate from DXMT and D3DMetal. The recorded OpenGL version strings and driver traces establish this path for Hedon, DOOM 64, Dome Keeper and WRATH.
- **D3DMetal:** a Direct3D-to-Metal translation component. It is different from the Metal API itself and from Apple's OpenGL driver; the OpenGL rows above are not D3DMetal runs.
- **Software rendering:** rendering work is performed in software, as in the recorded Ion Fury check.
- **Experimental DXMT-based DirectX 12 → Metal:** MacRunner's separate development path, not a released feature of the current app bundle or a claim of upstream DXMT DirectX 12 support.

[Back to MacRunner](README.md#tested-games--engines) · [Release status](RELEASE_STATUS.md) · [Vote for the next title](https://github.com/t0b1kent/macrunner-app/issues/1)
