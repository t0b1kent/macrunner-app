#!/bin/bash
# Same-task source frameworks and Swift outputs; final publication belongs to dispatcher.
set -euo pipefail
out=${1:?results directory required}
profile=${2:-xcode-cloud}
[ "$profile" = xcode-cloud ]
[ "${CI_XCODE_CLOUD:-}" = TRUE ]
repo=$(cd "$(dirname "$0")/.." && pwd)
work="${CI_WORKSPACE_PATH:-${TMPDIR:-/tmp}}/repro109-app-source-work"
[ ! -e "$work" ]
mkdir -p "$out"
rc=0
/usr/bin/python3 -B -I "$repo/repro109app/build_source.py" --build \
  --work "$work" --publish-dir "$out/checkpoints" --jobs 4 --minutes 95 || rc=$?
printf '%s\n' "$rc" > "$out/app-source-rc.txt"
if [ -d "$work/reports" ]; then
  cp -R "$work/reports/." "$out/"
fi
if [ -d "$work/frameworks/reports" ]; then
  mkdir -p "$out/frameworks-reports"
  cp -R "$work/frameworks/reports/." "$out/frameworks-reports/"
fi
# Preserve partial output as evidence on failure; APP-RESULT is the acceptance authority.
if [ -d "$work/prefix" ]; then
  tar -czf "$out/app-source-products.tar.gz" -C "$work/prefix" .
  shasum -a 256 "$out/app-source-products.tar.gz" > "$out/app-source-products.sha256"
fi
echo 'RESULTS_HANDOFF=PRESENT: existing Xcode Cloud dispatcher owns final publication'
exit "$rc"
