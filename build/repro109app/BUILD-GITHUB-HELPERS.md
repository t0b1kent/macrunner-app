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

For a short source-worker diagnosis, set ONE dispatch input:

| Input | Value for the first failed package | Meaning |
| --- | --- | --- |
| `only_package` | `flit-core` | Build this pinned package after its pinned prerequisites. |
| `only_step` | `1` | Select the 1-based package slot from `python-helpers.build.lock.json`. |

Leave both inputs empty for the complete helper build. Both inputs together,
unknown package names and slots outside 1..23 are refused. Shell values pass
as arguments, not executable text. Offline `--only-step 1` without `--build`
prints the selection plan and performs no acquisition or vendor execution.

The selected run calls the SAME `helper_package_worker.py` and SAME source
hashes as the full build. It uses a fresh venv from the pinned cloud bootstrap
Python 3.14.7, with `--without-pip`; it skips OpenSSL/CPython compilation and
does not produce helper executables. Earlier package slots are rebuilt into
that venv, so a late selector includes all preceding pinned prerequisites.
Slot 1 downloads and builds only flit-core 3.12.0. Its build budget is 180s,
with a 4-minute outer step limit; other selected runs have a 20-minute budget.
Queue time, upload time and actual duration are measured by Actions; a
2–3-minute turnaround is a target, not a locally established timing result.
All selected results are `DIAGNOSTIC_ONLY_NOT_HELPER_ACCEPTANCE`; they cannot
accept the source-built Python 3.14.5/OpenSSL 3.6.4 runtime or final helpers.

The artifact retains the complete selected worker stdout and stderr separately
(`flit-core-wheel.stdout.log` and `flit-core-wheel.stderr.log`), the driver and
wrapper exit codes, UTC/monotonic timeline, exact allowlisted child environment,
toolchain receipt, source acquisition hash/coverage and worker diagnostics.
Diagnostics record versions/state for pip, setuptools, flit, flit-core,
packaging and wheel before/after execution, plus root/suffix METADATA counts,
paths and built-wheel SHA even when the metadata reader refuses the wheel.
No ambient token or arbitrary environment dump is passed to source workers.
The combined stdout/stderr cap is 64 MiB per command; exceeding it stops the
owned process group and records `LOG_LIMIT_DROPPED`. Retained bytes remain
complete up to that stop. Downloaded source bodies stay in cloud work.

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

Full runs upload helpers.tar.gz and licenses; all runs upload complete bounded
reports even on failure;
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
