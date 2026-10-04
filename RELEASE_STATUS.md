# Release status

**MacRunner 1.0.8 development preview · Updated October 5, 2026**

MacRunner is a standalone native Mac application. Its CPU engine is **HyperBridge**: FEX-Emu with MacRunner's patch series, public under MIT at [t0b1kent/hyperbridge](https://github.com/t0b1kent/hyperbridge). The ordinary 1.0.8 preview, the separate 1.0.6-indiana experimental preview and DirectX 12 graphics research are distinct configurations.

## MacRunner 1.0.8 development preview

**[Download from the release page](https://github.com/t0b1kent/macrunner-app/releases/tag/v1.0.8).** Released October 5, 2026; Apple Silicon; declares macOS 26.5 as its minimum, checked on macOS 27.0.

| Release | What changed since the previous preview |
| --- | --- |
| **1.0.4 · September 29** | Fixes an uninitialized placement hint and failure-path memory clearing in Wine's server shared-memory mapping. Engine 0015 is unchanged. |
| **1.0.5 · September 30** | Exposes SSE4.2, AES, PCLMULQDQ and SHA through `FEX_HOSTFEATURES=enablecrypto`; 12/12 crypto known-answer checks pass. Wine reports one L3 cache and loads unaligned shared writable executable sections as private copies. Those sections are not shared between processes as on Windows. |
| **1.0.6 · October 1** | Updates the FEX recipe to 0001–0026. Enables the x18 ABI-trust transition path, corrected DIV/IDIV exceptions and restoration of pre-exception EFLAGS. Also includes safe exits at guest address zero, thread-scoped memory-ordering handling and executable-range fixes. Newer experimental switches remain off. |
| **1.0.6 · Hedon profile** | Adds a forward-compatible OpenGL context profile; frames are presented, but menu and gameplay were not visually verified. |
| **1.0.7 · October 3** | First release signed with a Developer ID and notarized by Apple. Ships one Wine runtime and one signed loader for 64-bit and 32-bit programs. Completes thread suspension between Wine and its server and enables .NET's W^X mode, so Stardew Valley (.NET 6) reaches its menu. Corrects the carry flag of 16-bit SHLD/SHRD. |
| **1.0.8 · October 5** | Hardware x86 memory ordering by default. Four translator startup defaults that avoid translating the same code again. Three x87 state fixes for sound (Heroes III music, Hedon's mix); 32-bit programs see an audio device. The app can start 32-bit programs, with fixes for dropped window messages, viewport geometry, thread start and thread suspension in 32-bit code. Wine no longer resolves the Mac's own host name through the network at session start. AVX self-modifying code, the BLSR/BLSMSK carry flag and DAZ/FTZ handling are corrected; the code-buffer guard accounts for 16 KB host pages. The app selects a Latin keyboard layout while a game runs. Private build paths were removed from the packaged files. |

**CPU validation:** the packaged x64 DIV/IDIV probe matches all 88 Windows-on-ARM reference cases, including fault registers. EFLAGS restoration matches the retained reference within ARM64EC's context limits. These probes do not establish whole-game correctness. On the final 1.0.8 build the CPU stand checked 500,595 saved states with zero new mismatches, and the 32-bit application-path gate passed 21 of 21 cases. The regression comparison still records floating-point status-flag, alias/W^X and shared-section failures.

**Game measurements:** the September 29 Hollow Knight FPS results remain on 1.0.3/engine 0015. For 1.0.8 we measured 23% less game CPU time per frame in Hollow Knight's menu than under 1.0.7 (run-to-run spread 0.9%; the frame rate was already at the 120 Hz limit) and, with the new startup defaults, 25.4 s instead of 31.1 s to Hollow Knight's menu on this engine code before final packaging. Long sessions, save/reload and clean exit still require title-specific checks. [Dated observations →](TESTED_GAMES.md)

**Distribution status of 1.0.8:** signed with a Developer ID and **notarized by Apple** (as 1.0.7 was); automatic updates off. The release includes the corresponding source of its bundled LGPL/GPL components. Our Developer ID provisioning profile carries Apple's cross-architecture-support entitlement, which the Wine loader uses. Notarization is not proof of operation on other Macs or macOS versions.

### Separate Indiana preview

**[1.0.6-indiana](https://github.com/t0b1kent/macrunner-app/releases/tag/v1.0.6-indiana), October 1:** experimental support for Indiana Jones and the Great Circle (Windows GOG version) through HyperBridge/Wine 11 and MoltenVK. The notes report about 10–12 FPS at minimum settings on M1 Pro. Firing a weapon hung the GPU and restarted the macOS session; split frames, stutter and sky artifacts remain. Save your work before trying it. Its four shared engine-file replacements can affect other titles. **Ray tracing is experimental, not released.** [Exact preview scope →](TESTED_GAMES.md#indiana-jones--106-indiana-experimental-preview)

## Engine

MacRunner 1.0.8 uses FEX-Emu `fd141ed6d` with MacRunner's patch series; the patches are in the release's source archive. Both translator modules were rebuilt from those sources on a clean cloud Mac and matched the shipped files byte for byte. The [comparison with Prism, CrossOver Preview and native code](https://github.com/t0b1kent/hyperbridge/blob/main/COMPARISON.md) retains its September 29 numbers: engine 0015, with the explicitly marked 1.0.2 floating-point snapshot. It is not a benchmark of 1.0.8. [Engine versions →](HYPERBRIDGE.md)

## How we test

Three stands replay bounded inputs without starting a game. These are diagnostic checks, not FPS benchmarks or compatibility certificates. A PASS can include explicitly classified known defects; missing/reference-gap states are reported separately.

| Stand and dated result | What it found or checked | What it does not check |
| --- | --- | --- |
| **CPU · stages 4–6, October 1–2** | Stage 4: 499,487 of 540,861 saved states checked, 499,478 equal; all six code-generation mutations detected. Translated-block coverage by title: 59.9–96.9%. Stage 5: 500,595 checked, six known engine mismatches and zero new ones; two VEX reference gaps corrected by independent rules. Stage 6 adds an independent MXCSR status-flag oracle: 7,168 hardware-reference pairs / 14,336 executions, zero errors. The accepted-engine corpus run reports 651 known states, including 650 in the missing-status-flags class, and zero new states. Two full runs agree. | Separate blocks do not establish EC/native ABI correctness, SMC/aliases, cache lifetime, gameplay or FPS. x87 and unmasked #XM are outside this status oracle; memory writes of flags are not covered. The recorded YMM upper halves are all zero. Stage 5 still has 19 states without a reference and 602 mapping failures. |
| **32-bit · stage 1, October 1** | 616 saved states from four titles at base zero and a shifted 8 TiB base; 296/296 PE probes equal at each base. Unicorn32 plus independent integer x87 rules compare 80-bit state, FCW/FSW/FTW and memory. Five mutations and six guard controls detected. Found pop-tag, sticky-invalid and saved-tag defects: 22, 4 and 32 cases respectively; empty-slot bytes remain disputed. | Small corpus: 105–194 blocks per title. Not Wine startup, native ABI, GPU, gameplay or speed. Known defects make this first-stage gate return failure even with zero new cases. A recorded wall-clock timeout remains explicit. |
| **Graphics · October 2** | Native Direct3D 11 trace replay without Wine: 300 Hollow Knight, 191 Divinity and 248 ABZU frames, three repeats per series. Two full series on macOS 27.0.1 give 4,434 exact frame comparisons against truth recorded on 27.0. Ten identity controls and six negative controls behave as expected. | Selected recorded frames, not whole games, gameplay FPS, DirectX 12, Vulkan or ray tracing. One earlier Divinity frame had four RGB samples differ by ±1 (0.00027%, PSNR 109.8 dB); six later repeats did not reproduce it and the cause is open. Historical device capabilities were not fully recorded. |

**October 5, final 1.0.8 build:** the CPU stand checked 500,595 states with zero new mismatches (651 known states, 19 without a reference). The 32-bit application-path gate passed 21 of 21 cases, including a Direct3D 7 frame with a negative control and a Miles Sound System decoder output byte-identical to Windows.

The processor stand revealed both engine defects and gaps in Unicorn; independent VEX and MXCSR rules keep those distinct. The graphics stand exposed a replay pipeline-state reset that skipped draws. Its A/A timing check reported 6.64% spread and 2.37% CV with frame readback included; this is measurement noise, not a product speed claim. The CPU and 32-bit stand sources are published in [hyperbridge/stands](https://github.com/t0b1kent/hyperbridge/tree/main/stands), without game recordings or binaries; the graphics stand source is published in [the DXMT fork](https://github.com/t0b1kent/dxmt/tree/macrunner-trace-stand/docs/trace-stand).

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

The ordinary MacRunner 1.0.8 preview runs **64-bit Direct3D 10/11** software through **DXMT**, which translates the graphics calls to Metal; since 1.0.8, 32-bit DirectDraw and Direct3D 7 programs can start through Wine's software renderer (experimental; our checks cover a DirectDraw window and one Direct3D 7 frame); Wine provides Windows API compatibility and HyperBridge translates the CPU instructions. Earlier game results in the [game tests](TESTED_GAMES.md) retain their recorded runtime. A listed launch profile is not a compatibility certification.

Support for every DirectX version, every Windows game, or 32-bit Windows software is not claimed.

### 32-bit support and developer account

Windows x64 is the main integration target. Since 1.0.8 the app can start 32-bit programs (experimental): Heroes of Might and Magic III reaches its main menu with music on the final build. Menu evidence does not establish gameplay or general 32-bit compatibility, and x87 floating-point code is still slow.

**Hardware memory ordering:** enabled by default since 1.0.8; the measured effect is in the game measurements above.

The host Mac and Wine's native components use ARM64. Windows ARM64 applications have a separate native-code path through Wine, but standalone Windows ARM64 application support has not yet been validated here. Mixed ARM64EC/x64 workloads may still need x64 translation. [Architecture scope →](HYPERBRIDGE.md#host-and-windows-architectures)

## DirectX 12 development

This work is in a **separate development branch**, not the preview app bundle.

| Verified milestone | Scope |
| --- | --- |
| 45,998 ordinary shaders | Pass the native loader and shader parsing/reflection checks; this is not execution of every complete graphics pipeline. |
| 33 actual geometry shaders | Compile with controlled companion vertex/pixel shaders; 27 use original root signatures and 6 use synthetic signatures. |
| 27 GPU-rendered geometry-shader test frames | 3 non-indexed and 24 indexed cases, with 27,648 pixel checks; bounded triangle-list tests with one instance/group. |

**Elden Ring: tested & working — DirectX 12.** On September 23, the maintainer confirmed successful DirectX 12 launch and gameplay, superseding the older menu-only report. Current optimization focuses on rendering quality and performance. The game check is separate from the isolated graphics milestones above; no measured frame-rate target has been published.

### Ray tracing

**Experimental, not released.**

**Historical research, September 22, 2026:** isolated shadow/radiance and acceleration-structure tests passed through the earlier runtime, including 24 targeted ray cases and 48 acceleration-structure cases. These are graphics-research results, not HyperBridge integration results.

At that checkpoint, the public DirectX ray-tracing state-object and ray-dispatch path was not connected. Complete coverage of the game's 4,281 ray-tracing libraries, in-game ray tracing, and performance validation remained open. These dated results do not establish ray tracing in MacRunner 1.0.8 or in the separate Indiana preview.

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

- Engine speed: calls and returns, ordinary arithmetic and flags, x87, and a persistent translation cache.
- Shorter startup: a warm Wine session and faster creation of a new bottle.
- Repeat the recorded game checks with comparable benchmark conditions (game version, scene, settings, frame timings), then title-by-title work.
- Real update delivery.

[Back to MacRunner](README.md) · [Credits](CREDITS.md)
