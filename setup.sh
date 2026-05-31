# Environment setup for embrace-crystal on Linux.
#
# Thin shim: sources crymble-ui's own setup.sh — the GUI lib owns the
# SFML / CSFML vendored libs and is the single source of truth for build
# env wiring.
#
# Usage: source setup.sh (from any directory)
#
# and initially you need to run once: shards install

EMBRACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$EMBRACE_DIR/lib/crymble-ui/setup.sh" ]; then
    source "$EMBRACE_DIR/lib/crymble-ui/setup.sh"
else
    echo "ERROR: crymble-ui not found in lib/ — run 'shards install' first" >&2
    return 1 2>/dev/null || exit 1
fi
