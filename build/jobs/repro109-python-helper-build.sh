#!/bin/bash
set -euo pipefail
out=${1:?results directory required}
profile=${2:-xcode-cloud}
[ "$profile" = xcode-cloud ]
[ "${CI_XCODE_CLOUD:-}" = TRUE ]
[ "$(uname -s)" = Darwin ]
[ "$(uname -m)" = arm64 ]
repo=$(cd "$(dirname "$0")/.." && pwd -P)
work="${CI_WORKSPACE_PATH:-${TMPDIR:-/tmp}}/repro109-python-helper-build-work"
[ ! -e "$work" ]
mkdir -p "$out"
rc=0
/usr/bin/python3 -B -I "$repo/repro109app/build_python_helpers.py" --build \
  --work "$work" --publish-dir "$out" --minutes 120 --jobs 8 || rc=$?
printf '%s\n' "$rc" > "$out/helper-build-rc.txt"
if [ -d "$work/reports" ]; then
  # Source bodies stay in cloud work. Keep exact fingerprints of omitted bodies
  # and mark their returned-byte coverage rather than publishing source archives.
  /usr/bin/python3 -B -I - "$work/reports" "$out" <<'PY'
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
echo 'RESULTS_HANDOFF=PRESENT: existing dispatcher owns private publication'
exit "$rc"
