require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# A keystroke into an OPEN cell editor must not rebuild the pivot hierarchy.
#
# `Table::Lazy::Pivot::Hierarchic#update` rebuilds the WHOLE hierarchy — parse_fieldlist, the
# tree, calc_offsets, calc_projections — whenever `@parent.version + @fields.version` differs
# from the cached `@version`. That walk is O(total rows). The pivot caches exactly ONE version,
# but the sum is CONTEXT-DEPENDENT: the same pivot object reports one version inside
# `with_shape_context` and a different one outside it (measured: 51362 vs 51364). So a read on
# one side of that boundary followed by a read on the other invalidates the cache and rebuilds
# everything — to a state it already had. Nothing in the data changed.
#
# Field report (2026-09-18): "every keystroke is slow; with --release, press-and-hold stalls,
# but press-and-hold BACKSPACE doesn't". Measured in --release at 2561 rows: a typed character
# costs TWO such rebuilds (~33 ms each) — one from `on_text_input` -> `get_assignability`, one
# from the next frame's `pre_render_flush` -> `cell_read` — while backspace costs none. That is
# 69-77 ms/key against this machine's 30.3 ms autorepeat, i.e. 2.5x behind and falling behind
# further every key.
#
# Counted, not timed, on purpose: the rebuild COUNT is exactly what the row count multiplies, so
# the assertion is machine-independent and cannot flake — and it stays true at any table size.
private def make_edit_app : Tuple(EmbraceApp, CrymbleUI::Testing::TestRenderer)
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Notes
        Name | Body
        Al | alpha
        Bo | beta
        Cy | gamma
        Di | delta
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("N", p, p.context.clone, hash["Notes"].as(TableLID))
    app.request_rebuild
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 600)
    renderer.settle_rendering(app)
    {app, renderer}
end

# Put the cursor on a data cell and open its editor by typing one character, the way the user
# does. The editor must already be OPEN before anything is counted: opening it is a different
# (and legitimately more expensive) path than typing into it.
private def open_editor(app, renderer)
    shape = app.shapes.first
    adapter = shape.matrix_adapter.not_nil!
    vm = adapter.virtual_matrix.not_nil!
    rows, cols = adapter.get_scrollorder
    vm.set_cursor_from_cell({rows[0], cols[1]})
    vm.on_text_input('a')
    renderer.settle_rendering(app)
    {adapter.virtual_matrix.not_nil!, shape}
end

# Type, then let the frame render — the loop a held-down key actually runs. Deliberately NO
# `request_rebuild`: that tears the cells down and commits the edit, and a commit is a real write
# that may legitimately change the hierarchy. Counting it here would measure the spec's own
# teardown instead of the keystroke.
private def rebuilds_during(app, renderer, &) : Int64
    before = Table::Lazy::Pivot::Hierarchic.rebuild_count
    yield
    renderer.settle_rendering(app)
    Table::Lazy::Pivot::Hierarchic.rebuild_count - before
end

describe "typing into an open cell editor" do
    original_font = CrymbleUI::Widget.font
    before_each { CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new }
    after_each { CrymbleUI::Widget.font = original_font }

    it "counts hierarchy rebuilds at all (without this, every count below is vacuous)" do
        app, renderer = make_edit_app
        # Loading and laying out a Shape MUST rebuild the hierarchy, or the counter is not wired
        # to the code path under test and the `eq 0` assertions below would pass for the wrong
        # reason. The control that must move.
        Table::Lazy::Pivot::Hierarchic.rebuild_count.should be > 0
        open_editor(app, renderer)
    end

    it "does not rebuild the pivot hierarchy for a typed character" do
        app, renderer = make_edit_app
        vm, _ = open_editor(app, renderer)

        typed = rebuilds_during(app, renderer) { vm.on_text_input('b') }

        # The pivot's SHAPE did not change: same rows, same fields, same hierarchy. Every rebuild
        # counted here is a full O(total rows) walk this keystroke does not need.
        typed.should eq 0
    end

    it "does not rebuild the pivot hierarchy for a backspace (the user's own control)" do
        app, renderer = make_edit_app
        vm, _ = open_editor(app, renderer)
        vm.on_text_input('b')
        app.request_rebuild
        renderer.settle_rendering(app)

        deleted = rebuilds_during(app, renderer) do
            vm.on_key_down(SF::Keyboard::Key::Backspace, false, false)
        end

        # Backspace already costs nothing in the field, which is what proves the typed-character
        # cost above is avoidable rather than inherent to editing a cell.
        deleted.should eq 0
    end
end
