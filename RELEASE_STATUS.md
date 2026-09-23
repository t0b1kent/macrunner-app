# Release status

**MacRunner 1.0.2 · Local preview · September 23, 2026**

MacRunner has been built as a standalone native Mac application. Public distribution is being prepared. The current Wine/FEX/DXMT engine bundle is separate from ongoing DirectX 12 research.

## Ready in the local preview

| Area | Verified result |
| --- | --- |
| Application | Release build and packaging completed successfully |
| Bundle integrity | Local ad hoc signature verification passed |
| App checks | 61 CPU tests passed, including 16 update tests |
| Packaging checks | 13 tests passed |
| Languages | 12 localizations checked for matching keys and valid substitutions |
| Bundled tools | A diagnostic launch found the required helper tools inside the app |

These checks validate the application and packaging. They do not establish game compatibility or replace testing on other Macs. Local ad hoc signing is not Developer ID signing or notarization for public distribution.

## Graphics: current bundle

The current app bundle contains an experimental Wine/FEX/DXMT route for **64-bit Direct3D 10/11** software. FEX translates x86-64 CPU instructions, Wine provides Windows API compatibility, and DXMT translates graphics to Metal. A listed launch profile is not a compatibility certification.

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

The next work is complete pipeline integration and game-level validation. Current optimization focuses on **Elden Ring**, with rendering correctness and performance as active goals. These results do not establish that the game is fully playable or meets a particular frame rate.

### Ray-tracing research

Isolated shadow/radiance and acceleration-structure tests have passed through the Wine/FEX path, including 24 targeted ray cases and 48 acceleration-structure cases on September 22.

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

- Validate the complete choose, add, and launch workflow with an agreed engine bundle.
- Publish compatibility results tied to specific program and engine versions.
- Complete signed distribution and update-delivery validation.
- Prepare a public download when those checks are complete.

[Back to MacRunner](README.md) · [Credits](CREDITS.md)
