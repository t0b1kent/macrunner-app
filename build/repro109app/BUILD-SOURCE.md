# Source application producer

The checkout contains the 375-file source snapshot selected by `source.lock.json`.
The guard checks every source byte and executable flag before compilation.
Frameworks, vendored binaries, prebuilt Python helpers and the PE test fixture
are excluded. The fixture is recreated from its pinned byte specification.
The two source images are stored as UTF-8 Base64 files. Preparation restores
the original PNG and ICNS only after validating the fixed destinations, sizes,
SHA-256 values and image headers in `encoded_assets`. Packaging consumes the
restored ICNS from the prepared tree. No image bytes are changed.
Fixtures use synthetic roots; privacy samples construct a synthetic mailbox
and use the operating system's home path. APP32 requires `MACRUNNER_ROOT` to
select a complete checkout explicitly.

Run the offline admission on a checkout:

```sh
export REPRO109_TEST_TMP="${TMPDIR:-/tmp}/repro109-app-tests"
mkdir -p "$REPRO109_TEST_TMP"
/usr/bin/python3 -I -B build/repro109app/build_source.py --plan
for module in test_source test_frameworks test_compile test_package test_public_app; do
  /usr/bin/python3 -I -B -m unittest discover -s build/repro109app -p "$module.py"
done
```

Source work runs on an ARM64 GitHub macos-26 or Xcode Cloud machine with the
toolchain recorded in `frameworks.lock.json`: Xcode major 27, SDK 27.0,
ld 27037.1.0 and Apple clang 21. The exact selected versions and paths are
recorded before downloading any third-party source. Sparkle 2.6.4 and
PLCrashReporter 1.11.2 use official repositories, pinned commits, clean-tree
checks and retained source/license inventories.

First run `repro109-app-source-matrix-xcode27-arm64.yml`. Its five independent
cells cover normal/optimized offline tests, both framework components and the
same full producer used by the command below. The matrix uses `fail-fast: false`.
The component selectors do not alter revisions, compiler flags or tool checks.

```sh
/usr/bin/python3 -I -B build/repro109app/build_source.py --build \
  --work "$RUNNER_TEMP/repro109-app-source" \
  --publish-dir "$RUNNER_TEMP/repro109-app-results" --jobs 4 --minutes 100
```

The fresh work directory must be outside the checkout and results directory.
The producer builds both frameworks, prepares the verified application tree,
builds and tests Swift products, records native architectures and dependencies,
and creates an unsigned partial `MacRunner.app`. Logs and receipts remain on
failure. Local third-party source work is refused. Signing and installation are
disabled.

This tree derives from the published 1.0.8 source input. `source_origin` records
its original inventory; `source_transformations` records the portable changes.
The earlier input differed from the privacy-normalized 1.0.9 source archive
at 14 SHA values with no executable-flag differences. That historical count
does not describe this derived tree. The sanitizer and removal algorithm are
preserved; native compilation and accepted application binary equality remain
unmeasured. Engine, loader and Python
helpers must subsequently come from their source producers before whole-bundle
composition and package/stand acceptance. A successful component build alone
does not close that boundary.
