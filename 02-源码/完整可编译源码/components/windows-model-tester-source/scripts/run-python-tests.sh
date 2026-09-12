#!/bin/sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/../.."
python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
