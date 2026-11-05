## MacRunner 1.1.0

This release updates Wine memory allocation and exception handling, speeds up the QueryPerformanceCounter path, and optimizes D3D11 → Metal. A high-resolution Retina toggle is available on the game's page.

- Address-free allocations use reserved regions, with fewer redundant protection and mapping-cleanup operations. ER testing reduced lock hold time during loading; this does not measure total loading time.
- Asynchronous SEH is restored in the verified PE modules: IsBad*, lstrcpyn and LocalLock handle the tested inaccessible pointers correctly. The family audit identified 165 affected functions in ten modules; it does not establish that every exception issue is resolved.
- D3D11 optimizations combine depth clears and reduce redundant render-pass and shader work. In a separate HK series, GPU time fell from 2.70 to 2.24 ms; the direct comparison with native measured 2.27 versus 2.39 ms, at 1280×720 with a 60 FPS cap in one scene on M1 Pro.

Owner recordings from November 4, one M1 Pro machine, macOS 27.0, HUD sampled every 0.5 seconds, gameplay only:

| Game | MacRunner, mean FPS / GPU ms | Reference, mean FPS / GPU ms |
|---|---:|---:|
| Elden Ring, 1920×1200 High, Fullscreen selected in-game | 44.81 / 22.05 | CrossOver Preview 20261015, Rosetta + D3DMetal (GPTK 4.0b3): 24.84 / 23.80 |
| Hollow Knight 1.5.12620 | 118.66 / 6.23 at 3024×1964 | Native Mac: 119.71 / 6.07 at 3024×1898 |

Scenes are ER's Chapel of Anticipation and HK's King's Pass opening. Routes and standing durations differ; these are observations from individual c32r candidate recordings, not controlled speedup tests of the final package. MacRunner renders 3.48% more pixels in HK. Full medians, sampled HUD 1% lows and methodology are in the README performance tables. True per-frame 1% lows were not measured from these videos.

New experimental FEX/SYNC optimizations from laboratory measurements are not presented as release defaults. HEADER_BY_PC, RET_NOPOLL, CMP_ZC, RIP_LITERAL and QPC_INLINE are disabled. The result described as “on par with Rosetta” applies to the experimental M configuration on the benchmark. Cyberpunk 2077 reached its title screen and EULA on a separate experimental branch; this does not establish tested gameplay or support in 1.1.0.

### First launch

When you first launch a game after installing MacRunner, the app prepares its bottle, which can take several minutes. The game also compiles shaders during its first few minutes, so some stuttering is expected. On the second launch, preparation is already complete and cached shaders allow smoother play; new scenes may still require additional compilation.

For the best frame rates, close demanding background apps and disconnect your second monitor. Both remained active in the owner's recordings.

In 1.1.0, Retina is enabled with a toggle on the game's page. Automatic Retina selection, emulated fullscreen resolution changes (EmulateModeset), shader-cache migration between engine versions and faster bottle updates are planned for 1.1.1 and are not included in this release. Updating the engine may require bottle preparation and shader compilation again.

### DirectX 12 without Rosetta

Elden Ring (DirectX 12) runs on Apple Silicon without Rosetta — our own x86 translator (HyperBridge) and our own DX12 → Metal layer. As far as we know, this is a first: CrossOver Preview (FEX, no Rosetta) does not start Elden Ring. This was checked by the owner; its FEX bottles include only D3D10/11.

Version 1.1.0, build 119 was built locally under a one-time exception approved by the owner. Building from the public repositories on GitHub continues separately; convergence with this package has not yet been verified.

Automatic in-app updates are not enabled yet. Download new versions from the GitHub release page.
