# Tested games & engines

**Last updated: September 23, 2026**

This page records what has actually been observed while developing MacRunner. A title in the library or launch-profile catalog is not automatically a tested game. Results apply to the configurations used for those sessions.

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

Gameplay benchmark results have not yet been published for these titles. **Not measured** means the measurement is pending. Future results will record the measured FPS together with resolution, graphics settings, test scene, duration and graphics path.

All entries below used **FEX + Wine**. FEX translates x86-64 CPU instructions; Wine provides Windows API compatibility. The graphics path is listed separately for each game.

## Current installed app

| Game | Graphics path | Check date | Confirmed result | FPS | Still to verify |
| --- | --- | --- | --- | --- | --- |
| **Hollow Knight** | **DXMT: Direct3D 11 → Metal** | September 23, 2026 | The tester confirmed gameplay and subsequently a successful launch, game entry and normal exit in the installed app. | Not measured | Repeated-run reliability, long sessions, save/reload, complete cinematic playback and measured performance. |

A title-specific startup correction was applied. Missing media components were also added and passed isolated component checks. An earlier session required MacRunner's Stop button after the game had been exited; the latest user check completed normally. Startup duration and residual-process cleanup were not independently measured in that latest session.

## Earlier development checks

These results came from earlier development configurations. **They have not all been retested in the current packaged app.** The dates identify the checks, not public release dates.

| Game | Graphics path | Check date | What was verified | FPS | Remaining limits |
| --- | --- | --- | --- | --- | --- |
| **Factorio** | DXMT: Direct3D 11 → Metal | September 11, 2026 | User-confirmed tutorial gameplay, saving, returning to the menu and reloading. | Not measured | Long sessions and measured performance were not established. |
| **Vampire Survivors** | DXMT: Direct3D 11 → Metal | September 11, 2026 | User-confirmed gameplay, movement, audio and voluntary exit, with a gameplay screenshot. | Not measured | Long-session stability and measured performance were not established. |
| **Hedon Bloodrite** | OpenGL through Wine | September 12, 2026 | User-confirmed gameplay, keyboard/mouse, audio, saving and reload at the saved position; clean exits recorded. | Not measured | Broader scene coverage and long-session performance were not established. |
| **DOOM 64** | OpenGL through Wine | September 12, 2026 | In-level rendering, mouse, audio and save/load; a subsequent English-keyboard-layout check confirmed keyboard operation. Intro/attract sequence and voluntary exit were also accepted. | Not measured | Other keyboard layouts and long sessions need further testing. |
| **Ion Fury** | Software renderer | September 12, 2026 | User-confirmed gameplay, save/load and voluntary exit. | Not measured | Accelerated OpenGL remained unresolved. This was not a GPU-accelerated rendering result. |
| **Dome Keeper** | Native OpenGL path through Wine | September 12, 2026 | Movement, audio, return to menu and continuation of saved state; a repeated mining-scene run with voluntary exit. | Not measured | Shutdown resource warnings remained; longer sessions need verification. |
| **WRATH: Aeon of Ruin** | Native OpenGL path through Wine | September 14, 2026 | User-confirmed gameplay, audio and loading. | Not measured | The run ended through a test timer. Manual save/reload, voluntary exit and long sessions were not verified. |

## Elden Ring — tested & working

**Status: Tested & working — DirectX 12.**

**FPS: Not measured.**

**Path:** FEX + Wine + MacRunner's **DXMT-based DirectX 12 → Metal** development path, separate from the current preview app's Direct3D 10/11 bundle.

The maintainer confirmed on **September 23, 2026** that the game had already been launched successfully with DirectX 12 and was working in gameplay. This newer confirmation supersedes the earlier September 16 menu-only status. The status describes the tested configuration.

**Current focus: further optimization**, including rendering quality and performance. Full in-game ray tracing remains in development. [Detailed graphics progress →](RELEASE_STATUS.md#directx-12-development)

## Reading the graphics paths

- **DXMT → Metal:** Direct3D 10/11 graphics are translated to Apple's Metal API and executed by the GPU. Translation is still involved.
- **OpenGL through Wine:** these runs used an OpenGL path; they should not be described as DXMT/Metal results.
- **Software rendering:** rendering work is performed in software, as in the recorded Ion Fury check.
- **Experimental DXMT-based DirectX 12 → Metal:** MacRunner's separate development path, not a released feature of the current app bundle or a claim of upstream DXMT DirectX 12 support.

[Back to MacRunner](README.md#tested-games--engines) · [Release status](RELEASE_STATUS.md) · [Vote for the next title](https://github.com/t0b1kent/macrunner-app/issues/1)
