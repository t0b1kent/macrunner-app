# HyperBridge

**MacRunner's x86-64 / x86 → ARM64 CPU engine for Windows software on Apple Silicon.**

HyperBridge is built on **[FEX-Emu](https://github.com/FEX-Emu/FEX)** (MIT) and carries MacRunner's own patch series on top of it. Its source, build script, releases, status and measurements are public under the MIT license at **[t0b1kent/hyperbridge](https://github.com/t0b1kent/hyperbridge)**. FEX-Emu has not reviewed or endorsed these modifications, and they are not contributions to FEX-Emu. [License terms and third-party scope →](HYPERBRIDGE_LICENSE.md)

## Engine version in MacRunner

| MacRunner | HyperBridge engine |
| --- | --- |
| **1.0.6**, October 1, 2026 | FEX-Emu `fd141ed6d` with patches **0001–0026**; x18 ABI trust, DIV/IDIV exception correction and pre-exception EFLAGS restoration enabled by default |
| **1.0.5**, September 30, 2026 | Engine 0015; `FEX_HOSTFEATURES=enablecrypto` exposes SSE4.2, AES, PCLMULQDQ and SHA; Wine fixes L3 reporting and unaligned shared-section loading |
| **1.0.4**, September 29, 2026 | Engine 0015; Wine-server mapping fix |
| **1.0.3** development preview | **[engine 0015](https://github.com/t0b1kent/hyperbridge/releases/tag/engine-0015)**: FEX-Emu `fd141ed6d` with patches 0001–0015 |
| 1.0.2 local preview | FEX-Emu `fd141ed6d` with patches 0001–0007 |

What changed in each engine build is listed in its [release notes](https://github.com/t0b1kent/hyperbridge/releases). How the engine compares with Microsoft Prism, the FEX build in CrossOver Preview and native macOS code: [HyperBridge compared](https://github.com/t0b1kent/hyperbridge/blob/main/COMPARISON.md).

## What the engine does

HyperBridge translates x86-64 and x86 instructions into ARM64 code and runs them on Apple Silicon, inside Wine's ARM64EC (64-bit programs) and WOW64 (32-bit programs) execution models.

| Component | Responsibility |
| --- | --- |
| **HyperBridge** | CPU instruction translation and guest execution state |
| **Wine** | Windows APIs, application loading and operating-system compatibility |
| **DXMT** | Direct3D 10/11 graphics translation to Metal |
| **MacRunner DirectX 12 development** | The separate DXMT-based DirectX 12 → Metal graphics path |
| **Metal** | Native graphics execution on the Apple GPU |
| **MacRunner app** | The macOS library, launch controls, runtime packaging and diagnostics |

HyperBridge is not a replacement for Wine or a graphics API.

## Host and Windows architectures

**Host platform: Apple Silicon Macs running macOS (ARM64).** This describes the Mac's processor; the architecture of a Windows executable is a separate question.

| Windows executable | Execution path | Scope |
| --- | --- | --- |
| **x64 / x86-64** | HyperBridge (`xtajit64.dll`, ARM64EC) translates CPU instructions to ARM64; Wine provides Windows compatibility | Primary focus; games checked on it are listed in [tested games](TESTED_GAMES.md) |
| **x86 / 32-bit** | HyperBridge (`xtajit.dll`, WOW64) | Development only, not working in released 1.0.6. Heroes III reached its main menu on our signed Wine loader on October 1; a rare post-menu crash remains open. Gameplay and broad compatibility are unverified. |
| **ARM64** | ARM64 CPU execution with Wine handling Windows APIs, loading and calling conventions | Not yet validated as a supported application target |

Windows ARM64 programs do not need x64 → ARM64 instruction translation for their ARM64 code. An **ARM64EC** application may also contain x64 modules; those modules still need the x64 translation path.

## Hardware memory ordering and signing

**October 2, 2026:** our Developer ID provisioning profile carries Apple's cross-architecture-support entitlement, and a native probe succeeds. Integration of hardware x86 memory ordering (TSO) into the engine is in progress; speed has not been measured. The September 29 comparison used software ordering and remains dated to that engine.

The Apple Developer account was approved on October 1. Our Wine loader is signed with Developer ID, and Apple accepted a trial notarization on October 2. This is preparation for the next release: the released 1.0.6 app remains signed ad hoc and not notarized. The separate 1.0.6-indiana preview does not establish general game compatibility. [Release boundaries and testing stands →](RELEASE_STATUS.md)

## Foundations and acknowledgements

HyperBridge is FEX-Emu with MacRunner's modifications. The engine binaries statically link components of the FEX-Emu source tree ({fmt}, xxHash, unordered_dense, range-v3, rpmalloc, tiny-json, cpp-optparse, Cephes, SoftFloat 3e); their notices ship with every engine release and inside the app. [Full credits and provenance →](CREDITS.md)

[MacRunner](README.md) · [Application release status](RELEASE_STATUS.md) · [Recorded game tests](TESTED_GAMES.md)
