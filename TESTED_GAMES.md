# Tested games & engines

**Last updated: September 23, 2026**

This page records what has actually been observed while developing MacRunner. A title in the library or launch-profile catalog is not automatically a tested game. Results apply to the configurations used for those sessions.

All entries below used **FEX + Wine**. FEX translates x86-64 CPU instructions; Wine provides Windows API compatibility. The graphics path is listed separately for each game.

## Current installed app

| Game | Graphics path | Check date | Confirmed result | Still to verify |
| --- | --- | --- | --- | --- |
| **Hollow Knight** | **DXMT: Direct3D 11 → Metal** | September 23, 2026 | The tester confirmed gameplay and subsequently a successful launch, game entry and normal exit in the installed app. | Repeated-run reliability, long sessions, save/reload, complete cinematic playback and measured performance. |

A title-specific startup correction was applied. Missing media components were also added and passed isolated component checks. An earlier session required MacRunner's Stop button after the game had been exited; the latest user check completed normally. Startup duration and residual-process cleanup were not independently measured in that latest session.

## Earlier development checks

These results came from earlier development configurations. **They have not all been retested in the current packaged app.** The dates identify the checks, not public release dates.

| Game | Graphics path | Check date | What was verified | Remaining limits |
| --- | --- | --- | --- | --- |
| **Factorio** | DXMT: Direct3D 11 → Metal | September 11, 2026 | User-confirmed tutorial gameplay, saving, returning to the menu and reloading. | Long sessions and measured performance were not established. |
| **Vampire Survivors** | DXMT: Direct3D 11 → Metal | September 11, 2026 | User-confirmed gameplay, movement, audio and voluntary exit, with a gameplay screenshot. | Long-session stability and measured performance were not established. |
| **Hedon Bloodrite** | OpenGL through Wine | September 12, 2026 | User-confirmed gameplay, keyboard/mouse, audio, saving and reload at the saved position; clean exits recorded. | Broader scene coverage and long-session performance were not established. |
| **DOOM 64** | OpenGL through Wine | September 12, 2026 | In-level rendering, mouse, audio and save/load; a subsequent English-keyboard-layout check confirmed keyboard operation. Intro/attract sequence and voluntary exit were also accepted. | Other keyboard layouts and long sessions need further testing. |
| **Ion Fury** | Software renderer | September 12, 2026 | User-confirmed gameplay, save/load and voluntary exit. | Accelerated OpenGL remained unresolved. This was not a GPU-accelerated rendering result. |
| **Dome Keeper** | Native OpenGL path through Wine | September 12, 2026 | Movement, audio, return to menu and continuation of saved state; a repeated mining-scene run with voluntary exit. | Shutdown resource warnings remained; longer sessions need verification. |
| **WRATH: Aeon of Ruin** | Native OpenGL path through Wine | September 14, 2026 | User-confirmed gameplay, audio and loading. | The run ended through a test timer. Manual save/reload, voluntary exit and long sessions were not verified. |

## Elden Ring — active development

**Path:** FEX + Wine + MacRunner's experimental **DXMT-based DirectX 12 → Metal** development path, separate from the current preview app's Direct3D 10/11 bundle.

On **September 16, 2026**, the original menus and character-creation interface rendered, with sound and input confirmed. The character preview was black and loading remained unresolved. **Gameplay is not verified.**

Later work has reached shader-loading and controlled GPU-rendering milestones. These are graphics-development results, not evidence of a completed playable game session. Full in-game ray tracing is also still in development. [Detailed graphics progress →](RELEASE_STATUS.md#directx-12-development)

## Development hardware

The primary development Mac is a **MacBook Pro with an Apple M1 Pro**, **8 CPU cores (6 performance + 2 efficiency)**, **14 GPU cores** and **32 GB unified memory**. The current system is **macOS 27.0, build 26A428**. Historical rows do not establish that each earlier session used this exact OS build.

This describes the development machine, not minimum requirements or validation of other Macs. [Current installation requirements and release readiness →](RELEASE_STATUS.md)

## Reading the graphics paths

- **DXMT → Metal:** Direct3D 10/11 graphics are translated to Apple's Metal API and executed by the GPU. Translation is still involved.
- **OpenGL through Wine:** these runs used an OpenGL path; they should not be described as DXMT/Metal results.
- **Software rendering:** rendering work is performed in software, as in the recorded Ion Fury check.
- **Experimental DXMT-based DirectX 12 → Metal:** MacRunner's separate development path, not a released feature of the current app bundle or a claim of upstream DXMT DirectX 12 support.

[Back to MacRunner](README.md#tested-games--engines) · [Release status](RELEASE_STATUS.md) · [Vote for the next title](https://github.com/t0b1kent/macrunner-app/issues/1)
