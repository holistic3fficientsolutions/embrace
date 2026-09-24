require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "crymble-ui/testing/keys"

include Persistency

# A SCRIPT TYPING INTO EMBRACE, event by event, the way the SFML run loop receives it.
#
# Wolfgang, 2026-09-23, AutoHotkey on Windows: an empty record, four fields; the script types four
# values separated by Tab, adds a record with Ctrl+R, then Tab Tab to reach the new line and skip
# Rank. "When the delay after Ctrl+r is too short, the record shows up, but the two tabs stay in
# the first line." Starting with two empty records it was fine.
#
# The loop dispatches a whole batch of queued events and renders once. Ctrl+R only REQUESTS the
# rebuild that grows the grid, so Tabs queued behind it navigated the old one-row grid and wrapped
# back to row 0; with two records the old grid already had a row 1 to wrap to. Every example below
# queues the burst at once and hands it to TestRenderer#deliver, which batches it the way the run
# loop does (EventBatch, one frame per batch), so what reaches a handler is what the running app
# would hand it.

private alias Keys = CrymbleUI::Testing::Keys

# Four fields and `records` empty records; the grid shows Rank as its first column.
private def make_app(records : Int32) : {EmbraceApp, CrymbleUI::Testing::TestRenderer}
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    rows = Array.new(records) { " |  |  | " }
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << (["T", "a | b | c | d"] + rows).join("\n")
    app.shapes.clear
    app.shapes << ShapeState.new("T", p, p.context.clone, hash["T"].as(TableLID))
    app.request_rebuild
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    {app, renderer}
end

private def matrix(app : EmbraceApp) : CrymbleUI::VirtualMatrix
    app.shapes.first.matrix_adapter.not_nil!.virtual_matrix.not_nil!
end

private def row_values(app : EmbraceApp, row : Int32) : Array(String)
    adapter = app.shapes.first.matrix_adapter.not_nil!
    (1..4).map { |col| adapter.cell_read({row, col}).to_s }
end

# The script's record: four values, Ctrl+R, then Tab Tab onto the new line's first field.
private def burst : Array(LibCSFML::Event)
    tab = Keys.tap(SF::Keyboard::Key::Tab)
    Keys.typed("s1") + tab + Keys.typed("s2") + tab + Keys.typed("s3") + tab + Keys.typed("s4") +
        Keys.ctrl(SF::Keyboard::Key::R) + tab + tab + Keys.typed("t1") + tab
end

describe "a scripted burst (keys queued faster than frames)" do
    it "Tabs queued behind Ctrl+R move into the record it adds" do
        app, renderer = make_app(1)
        CrymbleUI::Widget.focus_manager.focus(matrix(app))
        matrix(app).set_cursor_from_cell({0, 1}) # the first field, as the script starts
        renderer.deliver(app, burst)

        row_values(app, 0).should eq(["s1", "s2", "s3", "s4"])
        row_values(app, 1).should eq(["t1", "", "", ""])
        matrix(app).cursor_rc.should eq({1, 2})
    end

    # Control: the row the Tabs wrap into exists before the burst, so the order of rebuild and
    # navigation cannot matter. Green before and after the fix.
    it "does the same when the grid already has the next row" do
        app, renderer = make_app(2)
        CrymbleUI::Widget.focus_manager.focus(matrix(app))
        matrix(app).set_cursor_from_cell({0, 1})
        renderer.deliver(app, burst)

        row_values(app, 0).should eq(["s1", "s2", "s3", "s4"])
        row_values(app, 1).should eq(["t1", "", "", ""])
        matrix(app).cursor_rc.should eq({1, 2})
    end

    # SPEED, with the order above intact. Every committed cell requests a rebuild (the other views
    # of the data re-derive), but a PER-CELL write changes nothing the queued keys navigate, so its
    # rebuild need not stop the batch; Ctrl+R's must. The burst's batches then end only at Ctrl+R:
    # one rebuild for the four values and the chord, one for what follows. Stopping at every
    # commit cost five (2026-09-23, measured when the barrier treated every rebuild alike).
    it "rebuilds once per batch that needs it, not once per committed cell" do
        app, renderer = make_app(1)
        CrymbleUI::Widget.focus_manager.focus(matrix(app))
        matrix(app).set_cursor_from_cell({0, 1})
        before = CrymbleUI::App.rebuild_count
        renderer.deliver(app, burst)

        (CrymbleUI::App.rebuild_count - before).should eq(2)
        row_values(app, 0).should eq(["s1", "s2", "s3", "s4"])
        row_values(app, 1).should eq(["t1", "", "", ""])
    end
end
