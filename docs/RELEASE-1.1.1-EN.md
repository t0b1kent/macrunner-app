# MacRunner 1.1.1 · build 120

Released November 16, 2026. Apple Silicon; declared minimum macOS 26.5. [Download MacRunner](https://github.com/t0b1kent/macrunner-app/releases/tag/v1.1.1) · [HyperBridge](https://github.com/t0b1kent/hyperbridge/releases/tag/v1.1.1) · [HyperBridge DX9](https://github.com/t0b1kent/dxmt/releases/tag/v1.1.1). These are ordinary releases, not prereleases. Game compatibility remains experimental.

## What changed

- Integrates the accepted c33r runtime, 32-bit Gothic 3 / Direct3D 9 work, state-block improvements and thread-suspension changes.
- Includes automatic Retina selection, fullscreen display-mode support, shader-cache migration and updated bottle preparation.
- Provides a per-game calculation-accuracy setting for titles that need the exact arithmetic path.
- Brings the selected application, Wine, translator, graphics and installer-tool components together through recorded GitHub source builds.
- The Mac application is signed with a Developer ID, notarized by Apple and stapled. Notarization checks distribution security; it does not certify game compatibility.

## Checks and their limits

The source-build recipe checks passed. The actual assembled engine was read by 549 passing headless Swift tests in 76 suites, using the same application product-source test binary. The packaged installer extractor starts with its own runtime dependencies. The final archive inventory and update signature were checked. Those checks do not replace gameplay testing; no new live games were launched during final packaging.

## Owner testing and known problems · November 16

Gothic 3 launches through the 32-bit Direct3D 9 path. Owner testing of the downloaded 1.1.1 package on November 16 found two problems: the first launch can show `g_App::Create failed`, while a retry starts; and the cursor can jump to a corner when clicking with Retina enabled. Explicitly disabling Retina in the saved per-game setting removed the cursor jump in the owner's test. The 1.1.1 switch incorrectly turns an off choice back into Automatic; its source fix is prepared but is not in the published package.

Elden Ring currently exits at startup in the owner's 1.1.1 tests. The cause remains under investigation. Earlier Elden Ring recordings describe the older c32r/1.1.0 configuration and do not establish compatibility of 1.1.1. Hollow Knight and Horde of Distraction launched and closed in the owner's November 16 checks; these were short checks, not long-session certification.

A rare abnormal shutdown seen in synthetic testing remains unresolved. It is distinct from the newly reported startup and cursor problems. The owner approved publishing 1.1.1 before new live-game acceptance of the final package.

## Gothic 3 comparison

The owner reports approximately **78 FPS in MacRunner versus 30 FPS in Windows on Arm / Prism for Gothic 3**: **2.6 times the reported frame rate**, or about 160% higher. The retained report does not yet identify all matching scene, resolution, graphics-setting, game-version and VM details. Treat these as owner-reported observations, not a reproducible benchmark of the final signed 1.1.1 package or a measurement of the CPU translator alone.

The owner also reports that Gothic 3 did not launch in the CrossOver/Rosetta configurations they tried. This is a result for those configurations, not a general incompatibility claim: a community reporter describes running Gothic 3 through a Rosetta-based Wine lane in [issue #2](https://github.com/t0b1kent/macrunner-app/issues/2).

## Downloads and corresponding source

The MacRunner ZIP contains the application and bundled runtime. The separate HyperBridge and DX9 ZIPs are component packages, not standalone game launchers. Each release includes BUILDINFO and SHA256SUMS files.

- [Application source at v1.1.1](https://github.com/t0b1kent/macrunner-app/tree/v1.1.1)
- [HyperBridge source at v1.1.1](https://github.com/t0b1kent/hyperbridge/tree/v1.1.1)
- [Graphics source at v1.1.1](https://github.com/t0b1kent/dxmt/tree/v1.1.1)
- [Wine build sources](https://github.com/t0b1kent/macrunner-wine/tree/release/1.1.1-c33r); the exact producer revision is recorded in the application's build information.

MacRunner's HyperBridge port is based on FEX-Emu under MIT. Wine and other bundled projects retain their respective licenses and notices. A library/catalog entry is not a compatibility guarantee. For a problem, include the game version, Mac/macOS version and the run log through the app's report controls.
