#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
cd "$RADAR_ROOT"

python3 Scripts/check_architecture.py
python3 -m unittest discover -s Tests/InfrastructureTests -p 'test_*.py'
while IFS= read -r shell_script; do
  bash -n "$shell_script"
done < <(find Scripts script -type f -name '*.sh' -print)
swift test
swift run GhostProcessSniperCoreChecks
swift build --configuration release --product "$RADAR_PRODUCT"
printf 'Verification passed. No running application was stopped or relaunched.\n'
