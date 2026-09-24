# HyperBridge

**MacRunner's independently developed x86-64 → ARM64 translation engine for Apple Silicon.**

HyperBridge is being developed as MacRunner's own CPU translation core. The aim is to make the engine inspectable, buildable and open to contributions through a future open-source release. **MIT has been selected for original HyperBridge code; source publication is planned.** This repository currently presents the project and its progress. [License terms and third-party scope →](HYPERBRIDGE_LICENSE.md)

## What the engine does

HyperBridge translates supported x86-64 instructions into ARM64 code for execution on Apple Silicon. Its implementation includes instruction decoding, an intermediate representation, ARM64 code generation, translated-code caching, arithmetic and memory handling, and bridges to native functions.

| Component | Responsibility |
| --- | --- |
| **HyperBridge** | CPU instruction translation and guest execution state |
| **Wine** | Windows APIs, application loading and operating-system compatibility |
| **DXMT** | Direct3D 10/11 graphics translation to Metal |
| **MacRunner DirectX 12 development** | The separate DXMT-based DirectX 12 → Metal graphics path |
| **Metal** | Native graphics execution on the Apple GPU |
| **MacRunner app** | The macOS library, launch controls, runtime packaging and diagnostics |

The independent translation core and its Wine integration are distinct from the earlier runtime used for MacRunner's recorded game sessions. HyperBridge is not presented as a replacement for Wine or as a graphics API.

## Verified progress

**Status snapshot: September 24, 2026.**

| Area | Current evidence |
| --- | --- |
| Translation core | Implemented instruction translation, arithmetic, memory, code-cache and native-call mechanisms with focused validation suites |
| Wine integration | Separate HyperBridge runtime modules build and load through Wine's emulator interface |
| First isolated Windows x64 checks | A console fixture and a C++ fixture passed their expected-output checks with the independent HyperBridge backend verified |
| Broader execution checks | CPU, threading and exception-handling integration still have unresolved failures |
| Full applications and games | Compatibility runs on the new independent runtime are still pending |

Passing isolated fixtures is an integration milestone, not proof of full instruction coverage, full Windows compatibility or game readiness. The [existing game and FPS results](TESTED_GAMES.md) remain attributed to the earlier configurations that produced them.

## What comes next

1. Resolve the remaining CPU, threading and exception-handling integration failures.
2. Complete native-call, graphics and media integration through Wine.
3. Repeat real application and game checks: launch, input, audio, gameplay, save/reload and clean exit.
4. Record comparable performance measurements with the game version, resolution, settings, test scene and frame timings.
5. Integrate the validated engine into MacRunner's application bundle.

## Open-source release roadmap

- **Completed: MIT selected** for original HyperBridge code, with third-party terms kept separate. [License →](HYPERBRIDGE_LICENSE.md)
- Preserve the licenses and provenance of third-party components.
- Prepare a clean source tree with build requirements and reproducible build/test instructions.
- Publish the source repository, contribution guide, issue templates and an explicit support matrix.
- Attach release notes and checksums to any future engine binaries.

An engine-source release and a signed MacRunner application release are separate milestones. Neither public download is available from this presentation repository yet.

## Foundations and acknowledgements

HyperBridge has its own translation core and uses third-party components where appropriate, including SoftFloat-derived arithmetic code and Cephes routines. Their original notices and source provenance will accompany the source release. [Full credits and provenance →](CREDITS.md)

[MacRunner](README.md) · [Application release status](RELEASE_STATUS.md) · [Recorded game tests](TESTED_GAMES.md)
