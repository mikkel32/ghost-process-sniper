#!/usr/bin/env bash
# Compatibility entry point; development workflows live in Scripts/.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT_DIR/Scripts/dev.sh" "$@"
