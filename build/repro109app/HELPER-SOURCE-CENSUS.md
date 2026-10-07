# Helper source census

The full helper build and the three source-only matrix jobs call the same
`checkout_source()` implementation. Each fetches one exact public commit,
verifies HEAD, hashes every tracked regular file and checks the helper's
requirements or pyproject control when present. Source-only mode builds no
native runtime, package or helper executable.

Git records regular files as executable (`100755`) or non-executable (`100644`).
The canonical compact JSON census uses `0o755` and `0o644` respectively. The
checked-out owner executable bit must agree with the index. Archive and checkout
group-write permissions are not a Git source property and depend on export or
umask. Bytes, paths and executable status remain mandatory.

`python-helpers.candidate.lock.json` retains the historical tar inventory hashes
as `retained_archive_inventory_sha256`; the current source hashes use the Git
mode convention. The source revisions and source package pins do not change.

The matrix has 23 independent package jobs plus three independent source jobs:
legendary, gogdl and xdelta3. `fail-fast: false` retains every available failure.
Run the full helper build after all 26 jobs pass. A source check does not prove
that packaging, freezing, portable CLI smoke or application assembly succeeds.

For example, on an authorized macOS ARM64 cloud worker from the repository root:

```sh
/usr/bin/python3 -I -B build/repro109app/build_python_helpers.py \
  --verify-source legendary --work "$RUNNER_TEMP/helper-source" --minutes 8
```

Use a fresh work directory for each source check. Complete bounded command logs
and `RESULT.json` live under its `reports/` directory, including failed checks.
This mode requires the existing cloud identity guard and does not authorize
local third-party acquisition or execution.
