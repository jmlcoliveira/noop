#!/usr/bin/env bash
# Local Pulse AltStore-source updater. It never uploads or publishes an IPA.
#
#   Tools/update-altstore-source.sh inspect <ipa>
#   Tools/update-altstore-source.sh update --ipa <ipa> --tag pulse-v<version>
#
# Use update only after the matching IPA exists on the Pulse fork's release.
# The previous positional NOOP-release form is intentionally not accepted: it
# could point this Pulse source at an asset uploaded to the upstream repository.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"
exec "$PYTHON" "$HERE/update_pulse_altstore.py" "$@"
