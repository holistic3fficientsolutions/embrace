require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# The hover callback fires on EVERY mouse-move (position-dependent widgets like
# the matrix need per-move updates). The parent-chain hover_text walk must be
# memoised by hovered WIDGET — a widget's hover_text is invariant while the
# mouse stays on it, so sweeping across the matrix (a single widget) must not
# re-walk to the root every frame.
private def make_matrix_app : EmbraceApp
    app = EmbraceApp.new
    persistency = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        T
        A | B | C
        a1 | b1 | c1
        a2 | b2 | c2
        a3 | b3 | c3
        a4 | b4 | c4
    EOT
    t_lid = hash["T"].as(TableLID)
    app.shapes.clear
    app.shapes << ShapeState.new("T", persistency, persistency.context.clone, t_lid)
    app.request_rebuild
    app
end

describe "hover statusbar perf" do
    it "does not re-walk hover_text on every move while the mouse stays on one widget" do
        app = make_matrix_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        vm = app.shapes.first.matrix_adapter.not_nil!.virtual_matrix.not_nil!
        b = vm.absolute_bounds
        base = app.hover_text_walks
        # Sweep horizontally across the matrix interior — same widget, different
        # cells. Each move fires the hover callback.
        moves = 30
        moves.times do |i|
            x = b.x + 6.0 + i.to_f
            y = b.y + b.height / 2.0
            app.handle_mouse_move(CrymbleUI::Vec2.new(x, y))
        end
        # Memoised by hovered widget ⇒ the expensive parent-chain walk runs a
        # handful of times at most, NOT once per move.
        (app.hover_text_walks - base).should be < 5
    end
end
