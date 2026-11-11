#!/bin/bash
# Generate the ignored Xcode project before opening a fresh checkout.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

case "${1:-}" in
  ""|--generate-only) ;;
  *) echo "Usage: $0 [--generate-only]" >&2; exit 2 ;;
esac

# A Mac can have Xcode installed while xcode-select still points at CommandLineTools.
# Select Xcode for this process without changing the machine-wide developer setting.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  selected_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -x "$selected_dir/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$selected_dir"
  elif [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Install and launch Xcode first, or set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
  exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
  generator="$(command -v xcodegen)"
elif [[ -x "$repo_dir/build/tools/xcodegen/bin/xcodegen" ]]; then
  generator="$repo_dir/build/tools/xcodegen/bin/xcodegen"
else
  echo "XcodeGen is required: brew install xcodegen" >&2
  echo "Alternatively, unpack the official XcodeGen release into build/tools/." >&2
  exit 1
fi

cd "$repo_dir"
"$generator" generate
if [[ "${1:-}" != --generate-only ]]; then
  open -a Xcode "$repo_dir/Strand.xcodeproj"
fi
echo "Project ready: $repo_dir/Strand.xcodeproj"
echo "Select the NOOPiOS scheme and your iPhone or an iPhone simulator."
