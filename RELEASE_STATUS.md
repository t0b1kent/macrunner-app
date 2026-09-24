# Release status

**MacRunner local preview · HyperBridge integration in progress · September 24, 2026**

MacRunner has been built as a standalone native Mac application. The project is now moving toward its own **HyperBridge x86-64 → ARM64 engine** and a future open-source engine release. The installed 1.0.2 preview, the independent HyperBridge integration and DirectX 12 graphics research are distinct development configurations.

## HyperBridge transition

The independent core is implemented and undergoing Wine integration. Initial isolated Windows x64 console and C++ checks passed with the HyperBridge backend verified. Broader CPU, threading and exception-handling checks still have unresolved failures, and real game validation on the new runtime remains pending.

Existing game results and FPS figures belong to the earlier runtime. They will be repeated on HyperBridge before becoming compatibility claims for the new engine. [Engine status and source-release roadmap →](HYPERBRIDGE.md)

## Ready in the local preview

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

Public download preparation also includes completing third-party license notices and the corresponding source/build materials required by the distributed LGPL/GPL components. Those materials are not yet ready; a download is not being advertised as available.

### Hollow Knight: local gameplay check

Gameplay was confirmed on the development Mac on September 23 after a title-specific startup correction. The test also identified missing video-playback components, which have been added to the packaged runtime and passed isolated component checks. Complete cinematic playback still needs another game-level check.

An earlier session left the game process running after the user exited, requiring MacRunner's Stop button. In the latest check on September 23, the user confirmed that launching, entering the game and exiting all worked normally. This is a user-observed successful cycle; startup time and process cleanup were not independently measured in that latest session. Long-session stability, save/reload and performance measurements remain unverified. This result applies to the tested configuration, not every Mac or game.

**[Tested games and their runtime/graphics paths →](TESTED_GAMES.md)**

## Graphics: earlier preview bundle

The installed preview uses the [earlier runtime documented in the game tests](TESTED_GAMES.md) for **64-bit Direct3D 10/11** software. Wine provides Windows API compatibility and DXMT translates graphics to Metal. The HyperBridge-based replacement is still being integrated. A listed launch profile is not a compatibility certification.

Support for every DirectX version, every Windows game, or 32-bit Windows software is not claimed.

### 32-bit support and developer account

Full 32-bit Windows support is still in development. Apple Developer account approval is pending. These are separate unfinished milestones: account approval does not itself complete the 32-bit implementation or compatibility validation required before support can be claimed.

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

- Apply the selected MIT terms to the original HyperBridge source release, preserve component notices and prepare clean source-release materials. [License scope →](HYPERBRIDGE_LICENSE.md)
- Complete the independent engine's Wine integration and resolve outstanding execution failures.
- Validate the complete choose, add, and launch workflow with the HyperBridge engine bundle.
- Repeat the recorded game checks on HyperBridge and publish results with comparable benchmark conditions.
- Complete signed distribution and update-delivery validation.
- Prepare a public download when those checks are complete.

[Back to MacRunner](README.md) · [Credits](CREDITS.md)
