# Large release preparation

This source change prepares the next single release. It does not approve an engine, authorize signing, or publish an update.

## Application contents

- Sparkle uses `https://macrunner.app/appcast.xml`. Keep the EdDSA private key in the build Mac's Keychain. Test both a valid update and a foreign-signature rejection on an isolated test feed. Never use the production feed for acceptance tests.
- Automatic Retina follows the main display. Fullscreen resolution switching uses Wine's `EmulateModeset` setting together with Retina.
- PSO migration selects a source directory from the same canonical cache root used by the transplant operation. Catalogue entries require signed AIR/PSO equivalence; an unproved engine pair takes no migration route.
- Fast bottle updates use the checked registration policy only for an approved exact engine pair. Unchanged typelib modules are re-staged in Wine's order, and both full and fast preparation normalize shell32 registrations to the Windows system path.
- Gothic 3 detection also inspects the game's local graphics module when the executable provides no stronger evidence. Microsoft d3dx9 DLLs are discovered in the game's own DirectX cabinets, checked against the pinned release table and Authenticode data, and installed as the final bottle preparation step. DLL overrides apply to the selected game. The renderer is selected from package data: D3D9 x86 uses HyperBridge DX9; wined3d/OpenGL remains an internal fallback.

- Indiana Jones and the Great Circle uses the Vulkan route. The engine carries MoltenVK from the experimental ray-tracing branch with the MacRunner changes published with 1.0.6-indiana, staged at `graphics/moltenvk/libMoltenVK.dylib` through the assembler's pinned `vulkanDriver` input and named by the engine's Vulkan layer; its Apache-2.0 licence is a pinned licence input (`moltenvk-LICENSE.txt`). Sources, the four pinned upstream archives, the deployment target and the revision-string pin are in `moltenvk-indiana.lock.json`. The game profile carries the MoltenVK switches. `build_indiana.py` verifies the five archives, selects source trees without their packaged binaries and applies three explicit source postimages. Source preparation, clean cloud compilation and functional game acceptance are separate required results.

## Build tools and package requirements

Wine and the application's Windows helpers select **llvm-mingw 20260908, LLVM 23.1.1**. The compiler archive is `https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/llvm-mingw-20260908-ucrt-macos-universal.tar.xz`, 124,244,100 bytes, SHA-256 `d1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149`. Application helper pins are in `engine-tools.lock.json` and `bottle-tools.lock.json`. Retain each component's source lock, download verification and compiler-version report. The FEX and graphics recipes must use the final coordinated tool set before the cloud build; this application change does not establish their acceptance.

The package declares macOS **26.5**; every Mach-O targets 26.5 or earlier. The declared minimum is not lower because the ARM64EC path depends on the custom x18 ABI functions, which Apple documents from macOS 26.4, and no earlier system was available for a test. `assemble_release.py` rejects a different declared baseline and any Mach-O deployment target above it, including late-staged helpers. It does not raise the minimum to make a package pass. The native session helper is compiled for 26.5. The composer also runs INTEGRATE111's `check_no_backups.py`; backup copies inside any packaged `lib/wine` tree fail the build. Preserve backup files outside the application.

The native dependency closure preserves the names imported through `@rpath` and `@loader_path`, including versioned aliases whose source symlinks resolve to a different filename. Missing or conflicting selected-prefix inputs fail assembly. Every deliberately packaged GStreamer plugin must register from the package; JPEG and PNG decoder/encoder factories are also constructed in NULL state. This check creates no playback pipeline or output sink. Audio-output and game acceptance remain required.

Engine helper reproduction is pinned independently of historical release bytes.
The LLVM 23 job launcher and the supervisor targeting 26.5 have new recipe
references; the old LLVM 22 / 27.0 references remain in
`previous_release_reference`. The composer requires
`ENGINE_TOOLS_BUILT_AS_PINNED`. This status establishes recipe reproduction;
the final engine's functional gates remain required. Compiler commands and
their byte-exact output are retained in the tool build's `logs/` directory.

## Acceptance order

1. Bind the current local reference to its full ENGINE SHA-256, source revisions, patch hashes, toolchain and owner-approved default keys. Local recipe validation proceeds before the engine freeze. The prepared reference is c33r, ENGINE SHA-256 `2dff66a24b9f63ce395e9824b32b3512be618e4f6db11b10318f344e63171e35`. Preserve the selected candidate unchanged. Intermediate candidates remain local.
2. Rebuild the engine locally with LLVM 23 using INTEGRATE111's source recipe, including vkd3d 2.1 from Wine commit `a15ee2ccf20e2fc9f470badd916855801933d31f`, the local HLSL hash-table patch and the matching reflection IID header change. Retain the complete local source snapshot and build logs. Explain compiler/layout differences from the selected reference. These local bytes require an explicit curator freeze before they can become release inputs.
3. Run STAND-DIFF quick/full, STAND32 quick/full, STAND-GAMES, dxmt-stand and D3D12 G1–G5, HyperBridge DX9/replay checks, audio checks, the graphics ICB ABI check, package checks and public-check. Keep raw logs and distinguish absent, disabled and failed probes.
4. Validate fullscreen ER on a private test bottle using a byte-exact copy of the approved First Step save and silent audio output. Retain the selected/loaded binaries, settings, complete bounded diagnostics and save-restoration evidence. This is a functional check, not a performance comparison.
5. Approve the final bottle-update pair. Add PSO cache namespaces only after signed AIR/PSO equivalence. Historical pair approvals do not approve new engine bytes.
6. Wait for the curator's explicit engine-freeze line naming the engine and its full ENGINE SHA-256. After that freeze and local acceptance, build once on GitHub from the public repositories with exact source pins. Compare the result to the local build byte-for-byte or document every material difference. Run privacy scans before any Developer ID signature. Re-test Sparkle with the final archive on the test feed.
7. Prepare the unsigned candidate, hashes and English release notes for the curator. The owner authorized source publication and the normal MacRunner, HyperBridge and DX9 releases on November 15, 2026. This authorization covers Developer ID signing, notarization, tags and publication after the required acceptance results; it does not waive a failed gate or authorize interactive game checks while the Mac is occupied.

## Local checks

Run Python recipe tests with `python3 -I -B -m unittest discover -s build/repro110app -p 'test_*.py'` and `REPRO109_TEST_TMP` set to an owned existing fixture directory. Exercise entrypoints with their production `-I -B` flags from outside the repository.

Prepare a separate application source copy for Swift validation; keep framework symlinks outside the sealed snapshot. Use `swift test --jobs 2` at low priority. APP32 and Gothic catalogue checks need an explicit `APP32_ENGINE_ROOT`. Real-cabinet checks additionally require `GAMEREDIST_REAL_CABS`; game data is never uploaded or bundled. Preserve full test logs and report `install_skipped` separately.
