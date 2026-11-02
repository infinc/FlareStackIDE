#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION_SUFFIX="-debug" BUNDLE_PLUGINS=1 exec "$ROOT/build.sh"
