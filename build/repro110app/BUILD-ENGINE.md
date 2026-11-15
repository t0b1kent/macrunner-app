# Assemble an engine from source build outputs

This consumer brings the existing MacRunner engine assembler into macrunner-app.
It assembles only Contents/Resources/engine from explicitly selected source build
outputs. The Swift application, helpers and final signing remain separate steps.
Running this recipe does not establish reproduction of the complete MacRunner.app.

## Inputs

First produce new outputs with the pinned hyperbridge, macrunner-wine and dxmt
recipes. Retain each RESULT, source/driver/lock SHA, output inventory and tool
versions. Run check-arm64ec-dist.py from the same pinned Wine recipe and retain
the number of checked EC modules. A historical release engine is a reference,
not a new source build output.

engine-inputs.json selects explicit paths, resolved relative to that JSON, with
the following fields:

| Field | Requirement |
|---|---|
| name | Source candidate name |
| wine | New install prefix: bin/wine, bin/wineserver, lib/wine, share/wine |
| fex | New Windows/Unix outputs of both translators |
| graphics | Selected new graphics outputs |
| dependencyRoots | Nonempty list of source-built dependency prefixes |
| dlopenLibraries | Explicit libraries loaded by name |
| licenseInputs | Nonempty list of pinned license texts, with name/path/sha256 |
| environment | Complete launch environment prepared from the pinned recipe |
| wineEntitlements | Source plist containing the expected ABI/JIT/Game Mode keys |
| wineEntitlementsSHA256 | Full plist SHA-256; required for deferred signing |
| graphicsMatrix | Layer/module/capability evidence matrix, when declared |
| stripTool, stripToolSHA256 | Pinned llvm-strip, used only with --strip-pe |
| tools | Optional to this consumer: name/path/sha256 records for `macrunner-job.exe` and `macrunner-session`, built by `build_engine_tools.py` and installed in `engine/tools` with mode 0755 |

Select paths and hashes from the specific build receipts. Do not substitute an
ambient Homebrew installation or a developer's working directory. Pin the
entitlement intent in the source input inventory before assembly. A matching
digest does not establish that every required entitlement is present: compare
the key set with the accepted loader recipe without printing identity values,
certificate fingerprints or credentials.

## Assemble before final signing

From a clean macrunner-app clone on macOS with the selected producer's toolchain:

```sh
python3 -I -B build/repro110app/assemble_engine.py work/engine-inputs.json work/engine --defer-signing
```

OUT must be a new directory. To embed the engine in a newly source-built app,
use its new Contents/Resources/engine directory as OUT. The app producer supplies
the native application path and its source receipt.

--defer-signing does not invoke codesign, inspect signatures or use the owner's
identity. It checks the plist digest and structure before creating OUT, then
rechecks the pin after copying and modifying Mach-O files. Exact source bytes
are preserved in signing/wine-loader.entitlements.plist and recorded with their
full SHA in ENGINE.json. report.signing.mode=DEFERRED_FOR_OWNER;
actual_entitlements and signature_validation are NOT_ENABLED;
final_owner_signing_required=true.

This is a package awaiting final signing. Incidental linker/input ad-hoc
signatures do not count as verified signatures: install_name_tool can invalidate
them. This mode does not establish Gatekeeper acceptance or execution with the
required ABI/JIT/Game Mode entitlements. Final signing and notarization belong
to the owner. Afterwards, verify the actual native loader, its entitlements and
the final hashes.

Without --defer-signing, the existing behavior remains: modified Mach-O files
receive ad-hoc signatures with their original entitlements. The selected native
Wine loader's keys must match the expected plist. A mismatch fails without
printing their values. Key-set validation does not establish trusted signing.

--strip-pe is optional and may appear before or after --defer-signing. It removes
DWARF only with the SHA-pinned llvm-strip and preserves Wine's builtin marker.
Without this option, the consumer preserves the PE bytes.

## Contents and limits

The consumer supports the legacy bin/wine-preloader layout and the installed
multiarch layout: bin/wine dispatcher, lib/wine/aarch64-unix/wine and
wine-preloader. Missing native loader/preloader or wineserver is an error.
Signed mode verifies the native loader rather than the dispatcher.

Linked and explicitly dlopen-loaded libraries must resolve within the selected
dependencyRoots. System /usr/lib and /System libraries are not copied. Nested
dependencies are traversed to completion. Duplicate leaf names, symlinks outside
the selected prefix and differing bytes for an existing library fail closed.
Absolute host references are checked after relocation.

The media consumer uses the existing GStreamer plugin/scanner set from the same
source-built installation, including Wine 11 deinterlace/videofilter support.
verify_engine_media.py checks offline media factories in the assembled engine.
The coordinated cloud producer runs that real check; the local offline unit
suite does not. File presence does not establish a working media flow.

wine/share/wine is copied, but font provenance and each component's license
mapping require a separate source census. ENGINE.json reports
licenseCoverage=INPUTS_HASHED_COMPONENT_MAPPING_NOT_AUDITED. Stock MoltenVK,
D3D11 support and Vulkan file presence do not establish Indiana-fork or
D3D12/DXIL acceptance.

## Offline tests of this consumer

On a machine with Python 3.9 or later:

```sh
mkdir -p work/engine-test-tmp
REPRO109_TEST_TMP="$PWD/work/engine-test-tmp" TMPDIR="$PWD/work/engine-test-tmp" python3 -I -B -m unittest discover -s build/repro110app -p 'test*engine.py'
REPRO109_TEST_TMP="$PWD/work/engine-test-tmp" TMPDIR="$PWD/work/engine-test-tmp" python3 -I -B -O -m unittest discover -s build/repro110app -p 'test*engine.py'
```

Tests use synthetic bytes and mocked native tools. They do not run Wine/GPU,
games, downloads or third-party components. Coverage includes dependency/media
closure, both Wine layouts, default signed checks and deferred intent,
malformed/empty/non-dictionary plists, digest drift, refusal before OUT/tools,
privacy failures and unknown/duplicate CLI flags. These are not engine
acceptance tests.

## Local LLVM23 validation before the engine freeze

Use the Wine compiler pinned by the large-release recipe. Generated configure
must match the pinned configure.ac. The cc1 async-SEH probe must survive
generation: the bare clang driver option can be rejected for MinGW targets.
Check the resulting aarch64, arm64ec, x86_64 and i386 EXTRACFLAGS and the actual
compiler argument tokens for `-Xclang -fasync-exceptions`. A one-command
ntdll/wow64 override is lost on a later recompilation. When the flag policy
changes, rebuild all affected objects coherently; an incremental success does
not establish that the existing objects use the new flags.

Private exports must have definitions on every architecture on which they are
exported. Validate the actual generated Makefile targets: ARM64EC ntdll objects
belong to the ARM64X aarch64 DLL; there is no separate ARM64EC ntdll.dll target.
Preserve original source, objects and complete logs. Any source repair used in
local validation remains an explicit diagnostic difference until adopted into
the final frozen public source. See BUILD-LARGE-RELEASE.md for the release order.

## Product acceptance

Create engine-inputs.json from the new output receipts. After the curator's
engine freeze and local acceptance, run this exact consumer in the coordinated
clean cloud job. Retain the unsigned source package, ENGINE.json and complete
bounded logs. Compare with the accepted reference using the same function/
section tools, explain every material difference, and run hb-stand-diff,
hb-stand32, dxmt-stand and app32-gate on the assembled package. Complete the
remaining large-release matrix and the final BUILD.md procedure.

The local consumer, offline tests and a prepared package do not establish
release acceptance. The curator coordinates the one final cloud build;
Developer ID signing, notarization and publication require the owner's later
instruction.

## Tool and bottle-catalogue builds

**Engine tools.** `build_engine_tools.py --build --work <fresh-directory>` builds
`source/engine-tools/*.c`: `macrunner-job.exe` with pinned llvm-mingw 20260908
(LLVM 23.1.1), and the arm64 `macrunner-session` with Apple clang and deployment
target 26.0. `engine-tools.lock.json` retains the previous release references
separately from the new recipe references. `ENGINE_TOOLS_BUILT_AS_PINNED` means
reproduction of the recipe's bytes, not runtime acceptance: compare the PE
exactly and the Mach-O after removing its linker ad-hoc signature and zeroing
LC_UUID. A different compiler version is refused. Outputs are `outputs/tools/*`,
`RESULT.json`, and byte-exact command stdout/stderr in `logs/`; no installation
or Developer ID signing occurs.

**Bottle-update catalogues.** `bottle_catalogues.py` extracts engine/ENGINE.json
from the published 1.0.9 and 1.0.8 archives. It verifies each archive's size and
SHA-256, plus the manifest's name and SHA-256, then writes
Resources/BottleCatalogues/bottle-inputs-<SHA-256>.json. The producer
(`build_source.py`) runs this after source preparation and before the Swift
build. Network-backed equality between those published manifests and the
accepted catalogue inputs remains unverified; a mismatch stops the step and
reports the observed name and hash.

**Downloaded dependency prefixes.** A local build may consume a byte-verified
dependency prefix produced at another absolute path. `assemble_engine.py` accepts
an optional `dependencyPrefixMappings` list in its input JSON. Each entry has
`from` (the normalized absolute producer prefix) and `to` (one explicitly selected
`dependencyRoots` directory). Source prefixes cannot overlap. The mapping applies
to transitive native dependencies and GStreamer core provenance; missing files,
path traversal, symlink escapes and foreign media cores still fail. Producer
binaries remain unchanged. Only copied package outputs receive relocated load
commands. An omitted list retains the original behavior.
