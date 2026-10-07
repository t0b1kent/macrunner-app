#!/bin/bash
# Unsigned source frameworks only; existing Xcode dispatcher publishes final reports.
set -euo pipefail
out=${1:?results directory required}
profile=${2:-xcode-cloud}
[ "$profile" = xcode-cloud ]
[ "${CI_XCODE_CLOUD:-}" = TRUE ]
repo=$(cd "$(dirname "$0")/.." && pwd)
work="${CI_WORKSPACE_PATH:-${TMPDIR:-/tmp}}/repro109-app-frameworks-work"
[ ! -e "$work" ]
mkdir -p "$out"
rc=0
/usr/bin/python3 -B -I "$repo/repro109app/build_app_frameworks.py" --build \
  --work "$work" --publish-dir "$out/checkpoints" --jobs 4 --minutes 90 || rc=$?
printf '%s\n' "$rc" > "$out/frameworks-rc.txt"
if [ -d "$work/reports" ]; then
  cp -R "$work/reports/." "$out/"
fi
if [ -d "$work/prefix" ]; then
  tar -czf "$out/app-frameworks-prefix.tar.gz" -C "$work/prefix" .
  shasum -a 256 "$out/app-frameworks-prefix.tar.gz" > "$out/app-frameworks-prefix.sha256"
fi
echo 'RESULTS_HANDOFF=PRESENT: existing Xcode Cloud dispatcher owns final publication'
exit "$rc"
