#!/usr/bin/env bash
# The GUI specs that go red when ShapeState#update's change gate misses the fieldlist's version,
# built with -Dverify_bounds. CI runs this after the GUI group; run it before a push too.
#
# Why a flag and a list: the gate's announce is what crymble-ui's MatrixAdapter contract asks for,
# and the one check for a missed announce raises only under -Dverify_bounds and only for a change
# of the row or column COUNT - doc/08-shapes.md, "Shape Lifecycle", says how narrowly, and how a
# run fails.
#
# The list, measured 2026-09-26 over the whole GUI group under the flag with the gate's fieldlist
# term removed (the way the announce was once really lost): fieldlist_move_unmerge and ids_guards
# fail outright, embrace_ui through spec_helper's swallow check alone (fieldlist_move_unmerge is
# green in a plain build, which heals the missed announce).
# Re-derive it the same way when a new structural path is added (~30 min). NOT measured: the
# gate's announce removed as a whole - that run had 11 of its first 175 examples red, then hung.
#
# `[BOUNDS]` lines are the flag's layout diagnostics (a child overflowing its parent, a width under
# its minimum): reported, not failures. Linux only: what it checks is platform-independent, so one
# platform proves it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source setup.sh
exec crystal spec -Dverify_bounds \
    spec/gui/embrace_ui_spec.cr \
    spec/gui/fieldlist_move_unmerge_spec.cr \
    spec/gui/ids_guards_spec.cr
