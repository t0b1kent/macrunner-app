# Release status

**MacRunner 1.0.3 development preview · HyperBridge engine 0015 · September 29, 2026**

MacRunner is a standalone native Mac application. Its CPU engine is **HyperBridge**: FEX-Emu with MacRunner's patch series, public under MIT at [t0b1kent/hyperbridge](https://github.com/t0b1kent/hyperbridge). The 1.0.3 preview and the DirectX 12 graphics research are distinct development configurations.

## MacRunner 1.0.3 development preview

**[Download from the release page](https://github.com/t0b1kent/macrunner-app/releases/tag/v1.0.3).** Apple Silicon, macOS 27.0.

| Change from 1.0.2 | What it means |
| --- | --- |
| **HyperBridge engine 0015** | Replaces the 1.0.2 engine. [What changed in the engine →](https://github.com/t0b1kent/hyperbridge/releases/tag/engine-0015) |
| **Faster start-up** | `MACRUNNER_HB_MAPSCAN_SKIP=1` is now on by default: Wine no longer scans the whole address space when it maps memory. Hollow Knight reached its menu in about 45 s instead of about 3 minutes in our measurements |
| **Cleaner runtime** | 20 leftover backup files (64 MB) removed from the bundled Wine |

**Checked on this exact engine:** Hollow Knight 1.5.12620 (Windows build) starts, loads a save and plays King's Pass; frame rate at the 120 Hz display limit on the test Mac. [Measurements →](TESTED_GAMES.md#macrunner-103--hyperbridge-engine-0015)

**Not yet re-checked on 1.0.3:** the other titles in [tested games](TESTED_GAMES.md), long sessions, save/reload and clean exit across games.

**Distribution status:** signed ad hoc, **not notarized** (Apple Developer account approval is pending), automatic updates off. macOS may refuse the first launch; the release notes describe how to open it. The release attaches the license texts and the **corresponding source of the bundled LGPL/GPL components** (Wine and DXMT with MacRunner's changes, and the third-party libraries listed in the inventory).

## Engine

MacRunner 1.0.3 uses HyperBridge [engine 0015](https://github.com/t0b1kent/hyperbridge/releases/tag/engine-0015). The engine's status, measurements (including the comparison with Prism, CrossOver Preview and native code) and roadmap are on the [HyperBridge page](https://github.com/t0b1kent/hyperbridge). [Engine versions in MacRunner →](HYPERBRIDGE.md)

## Checked in the 1.0.2 local preview

| Area | Verified result |
| --- | --- |
| Application | Release build and packaging completed successfully |
| Bundle integrity | Local ad hoc signature verification passed |
| App checks | Focused CPU suites passed for launch status, installation relocation, graphics selection, localization and update coordination |
| Packaging checks | 13 archive/update packaging checks and 16 media-assembly checks passed |
| Media runtime | 33 media plugins packaged; all 27 selected playback elements loaded and created in an isolated check |
| Languages | 12 localizations checked for matching keys and valid substitutions |
| Bundled tools | A diagnostic launch found the required helper tools inside the app |

These checks validate the application and packaging. They do not establish game compatibility or replace testing on other Macs. Local ad hoc signing is not Developer ID signing or notarization for public distribution.

The exact earlier development bundle requires **macOS 27.0** because of its bundled media dependencies. Launch on Macs with standard security settings remains unverified. The main application and bundled runtime are ARM64; an optional Intel-only Legendary store helper may require Rosetta. The recorded core game path does not use Rosetta. These are preview-bundle facts, not a finalized HyperBridge release support matrix.

The 1.0.3 release attaches the third-party license texts and the corresponding source of the distributed LGPL/GPL components.

### Hollow Knight: local gameplay check

Gameplay was confirmed on the development Mac on September 23 after a title-specific startup correction. The test also identified missing video-playback components, which have been added to the packaged runtime and passed isolated component checks. Complete cinematic playback still needs another game-level check.

An earlier session left the game process running after the user exited, requiring MacRunner's Stop button. In the latest check on September 23, the user confirmed that launching, entering the game and exiting all worked normally. This is a user-observed successful cycle; startup time and process cleanup were not independently measured in that latest session. Long-session stability, save/reload and performance measurements remain unverified. This result applies to the tested configuration, not every Mac or game.

**[Tested games and their runtime/graphics paths →](TESTED_GAMES.md)**

## Graphics

MacRunner 1.0.3 runs **64-bit Direct3D 10/11** software through **DXMT**, which translates the graphics calls to Metal; Wine provides Windows API compatibility and HyperBridge translates the CPU instructions. Earlier game results in the [game tests](TESTED_GAMES.md) used the previous runtime. A listed launch profile is not a compatibility certification.

Support for every DirectX version, every Windows game, or 32-bit Windows software is not claimed.

### 32-bit support and developer account

Windows x64 is HyperBridge's primary integration target. Full Windows x86 / 32-bit support is a future milestone. Apple Developer account approval is pending; approval does not itself complete the 32-bit implementation or compatibility validation.

The host Mac and Wine's native components use ARM64. Windows ARM64 applications have a separate native-code path through Wine, but standalone Windows ARM64 application support has not yet been validated here. Mixed ARM64EC/x64 workloads may still need x64 translation. [Architecture scope →](HYPERBRIDGE.md#host-and-windows-architectures)

## DirectX 12 development

This work is in a **separate development branch**, not the preview app bundle.

| Verified milestone | Scope |
| --- | --- |
| 45,998 ordinary shaders | Pass the native loader and shader parsing/reflection checks; this is not execution of every complete graphics pipeline. |
| 33 actual geometry shaders | Compile with controlled companion vertex/pixel shaders; 27 use original root signatures and 6 use synthetic signatures. |
| 27 GPU-rendered geometry-shader test frames | 3 non-indexed and 24 indexed cases, with 27,648 pixel checks; bounded triangle-list tests with one instance/group. |

**Elden Ring: tested & working — DirectX 12.** On September 23, the maintainer confirmed successful DirectX 12 launch and gameplay, superseding the older menu-only report. Current optimization focuses on rendering quality and performance. The game check is separate from the isolated graphics milestones above; no measured frame-rate target has been published.

### Ray-tracing research

Isolated shadow/radiance and acceleration-structure tests passed through the earlier runtime, including 24 targeted ray cases and 48 acceleration-structure cases on September 22. These are graphics-research results, not HyperBridge integration results.

The public DirectX ray-tracing state-object and ray-dispatch path is not yet connected. Complete coverage of the game's 4,281 ray-tracing libraries, in-game ray tracing, and performance validation remain open. Ray tracing is not a released feature of the current bundle.

## Updates

MacRunner uses Sparkle to prepare for updating the **app, runtime, and graphics together**. Bundle contents and checksums are verified during packaging. Tests cover coordination between program launch and update installation, including recovery when an installation's result is uncertain.

Automatic update delivery is **disabled in the local preview**: a production feed and verification key have not been configured. Real updates between two installed, signed releases still need validation. The prepared format is a complete archive; delta downloads are not implemented.

Before delivery can be enabled:

1. Choose HTTPS hosting for the update feed and archives.
2. Configure the public verification key and prepare signed archives.
3. Validate Developer ID signing, notarization, and runtime entitlements.
4. Test a real update, cancellation, interrupted downloads, invalid signatures, and preservation of user data.
5. Install the first release containing the configured feed and key once; later updates can use the built-in updater.

## Next release milestones

- Repeat the recorded game checks on HyperBridge and publish results with comparable benchmark conditions (game version, scene, settings, frame timings).
- Move to newer HyperBridge engine builds after their checks ([engine releases](https://github.com/t0b1kent/hyperbridge/releases)).
- Developer ID signing, notarization and update-delivery validation once the Apple Developer account is approved.

[Back to MacRunner](README.md) · [Credits](CREDITS.md)
