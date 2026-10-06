# ARM64 Python helper build: GitHub fallback

All helper build sources live under `build/`; the workflow alone lives under
`.github/workflows/`. Resolve commands from the checkout root. Relative imports
stay within `build/` and do not depend on a local lane or absolute source path.
Checkpoint publication requires an explicit `RESULTS_REMOTE`; this GitHub
helper workflow does not publish checkpoints and does not set that variable.

This workflow is a source-only proposal for owner-approved publication into
`t0b1kent/macrunner-app`. Copy only the publication manifest files to its root.
Do not publish the private clone, its history, `jobs/JOB`, cloud dispatcher,
existing results, downloaded source bodies, release inputs or game data.
The local private base is `dce9b70d7d6e23b81b908c977ab9ed9c8a1d440e`.

After approval and publication, dispatch
`.github/workflows/repro109-python-helpers-macos15-arm64.yml` at the approved
recipe revision. Checkout uses the immutable dispatch `github.sha`;
checkout/upload actions are pinned to their existing accepted full revisions.
There is no push trigger, signing, notarization or private-repository token.

The official GitHub `macos-15` runner is ARM64. Select Xcode **16.4 / 16F6**,
SDK **15.5**, Apple clang **17.0.0** and installed bootstrap Python **3.14.7**.
The task refuses drift before vendor acquisition; no Homebrew or setup-python
install runs. Record actual linker output and host macOS alongside selected
compiler/SDK receipts. The runner image itself is mutable; these version checks
do not claim byte-identical tool installations or results.

Run from a clean checkout on that approved cloud runner:

    bash build/jobs/repro109-python-helper-build-github.sh "$RUNNER_TEMP/repro109-helper-results"

Provider facts and `REPRO109_HELPER_PROFILE=github-macos15-arm64` pass explicitly
to source-built package workers. Xcode Cloud is a separate unchanged JOB;
the GitHub job never sets `CI_XCODE_CLOUD=TRUE`.

The new native deployment target is **14.0**, allowing the prefix-hidden help
checks to execute on macOS 15. CPython **3.14.5**, OpenSSL **3.6.4**, all **23**
sdist hashes, Legendary, gogdl and xdelta3 revisions/inventories are unchanged.
This is the same source build task on a different pinned toolchain/target;
historical binary equivalence is not inferred from it.

Build OpenSSL and CPython, bootstrap package backends from source, replace
precompiled PyInstaller bootloaders with the ARM64 source build, compile
Legendary/gogdl and xdelta3, run architecture/dependency/CLI checks, hide the
owned prefix and repeat both helper CLI checks. Source acquisition reuses
existing bounded official-host/SHA transports. Jobs use three CPU workers,
a 120-minute build deadline and a 150-minute workflow deadline.

Upload helpers.tar.gz, licenses and complete bounded reports even on failure;
`.body` source responses remain in cloud work, with SHA/size/coverage receipts.
Actions artifacts are temporary (14 days); the curator preserves accepted
outputs in the designated private evidence/release store. No release upload
or private credentials are configured in this fallback.

Own local fixtures establish provider/source/preflight/worker/wrapper behavior
only. Actual GitHub source build, full embedded dylib relocation, final app,
license acceptance, r2 function/section comparison, four stands and public
BUILD.md execution remain unaccepted until their real results are measured.

Official runner references:
[hardware/labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[macOS 15 ARM64 tools](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).
