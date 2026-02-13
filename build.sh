#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build "$@"
codesign --force --sign - .build/debug/Clockoo
echo "✓ Built and signed: .build/debug/Clockoo"
