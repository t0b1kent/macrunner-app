#!/bin/bash
set -euo pipefail
out=${1:?results directory required}
mkdir -p "$out"
trap 'wrapper_rc=$?; printf "%s\n" "$wrapper_rc" > "$out/helper-wrapper-rc.txt"' EXIT
[ "${GITHUB_ACTIONS:-}" = true ]
[ "${RUNNER_OS:-}" = macOS ]
[ "${RUNNER_ARCH:-}" = ARM64 ]
[ "$(uname -s)" = Darwin ]
[ "$(uname -m)" = arm64 ]
repo=$(cd "$(dirname "$0")/.." && pwd -P)
work="${RUNNER_TEMP:?}/repro109-python-helper-build-work"
[ ! -e "$work" ]
export REPRO109_HELPER_PROFILE=github-macos15-arm64
set --
minutes=120
if [ -n "${REPRO109_HELPER_ONLY_PACKAGE:-}" ]; then
  set -- "$@" --only-package "$REPRO109_HELPER_ONLY_PACKAGE"
  minutes=20
fi
if [ -n "${REPRO109_HELPER_ONLY_STEP:-}" ]; then
  set -- "$@" --only-step "$REPRO109_HELPER_ONLY_STEP"
  minutes=20
fi
if [ "${REPRO109_HELPER_ONLY_PACKAGE:-}" = flit-core ] || [ "${REPRO109_HELPER_ONLY_STEP:-}" = 1 ]; then
  minutes=3
fi
rc=0
python3 -B -I "$repo/repro109app/build_python_helpers.py" --build \
  --work "$work" --publish-dir "$out" --minutes "$minutes" --jobs 3 "$@" \
  > "$out/helper-driver.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out/helper-build-rc.txt"
if [ -d "$work/reports" ]; then
  python3 -B -I - "$work/reports" "$out" <<'PY'
import hashlib, json, pathlib, shutil, sys
source, out = map(pathlib.Path, sys.argv[1:])
omitted = []
for path in sorted(source.rglob('*')):
    if not path.is_file():
        continue
    relative = path.relative_to(source)
    if path.suffix == '.body':
        omitted.append(dict(path=relative.as_posix(), bytes=path.stat().st_size,
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            returned_bytes='NOT_PUBLISHED_SOURCE_BODY_CLOUD_WORK_ONLY'))
        continue
    target = out / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
(out / 'omitted-source-bodies.json').write_text(json.dumps(omitted, indent=2) + '\n')
PY
fi
echo 'RESULTS_HANDOFF=PRESENT: GitHub Actions artifact upload owns publication'
exit "$rc"
