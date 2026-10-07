#!/bin/bash
set -euo pipefail
repo=${MACRUNNER_ROOT:?Set MACRUNNER_ROOT to the selected complete MacRunner checkout}
[ -f "$repo/config/env.sh" ]
[ -f "$repo/scripts/probes/app32/gate.py" ]
cd "$repo"
. ./config/env.sh
exec python3 scripts/probes/app32/gate.py "$@"
