require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# The beta tester's scenario, end to end: New file (demo) → expand Filter → "Add filter: Person" →
# drag the shape panel narrower → then wider. Widening left the chip rows packed for the old narrow
# width while the Perspective was positioned against a freshly measured (short) Filter section, so the
# Perspective was drawn on top of the filter list — and the overlap survived mouse-up.
#
# Everything is driven through the real event path (click the tree_node, click the add-filter button,
# drag the panel edge) so rebuild timing and invalidation match the running GUI.

private def make_demo_app : EmbraceApp
    app = EmbraceApp.new
    persistency = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Persons
        Person | City
        Alan | Boston
        Amanita | San Francisco
        Denny | Boston
        Helen | New York
        Jared | Arizona
        Jezelia | Morrighan
        Kaden | Venda
        Max | New York
        Melanie | Arizona
        Rafferty | Dalbreck
        Riley | Reykjavik
        Samwise | Shire
        Sauron | Mordor
        Wanda | unknown
        Will | Chicago

        Allocations
        Person_Person | Project | Allocation
        Alan | Law | 100
        Denny | Law | 100
        Sauron | Suppression | 100
        Samwise | Peace | 100
        Wanda | Peace | 100
        Melanie | Survival | 100
        Jared | Survival | 100
        Jezelia | Autonomy | 100
        Rafferty | Curiosity | 100
        Kaden | Loyalty | 100
        Max | Healing | 100
        Helen | Healing | 100
        Will | Justice | 100
        Riley | Arts | 100
        Amanita | Arts | 100
    EOT
    alloc_lid = hash["Allocations"].as(TableLID)
    app.shapes.clear
    app.shapes << ShapeState.new("Allocations", persistency, persistency.context.clone, alloc_lid)
    app.request_rebuild
    app
end

private def click_widget(app : EmbraceApp, id : String) : Nil
    w = app.find(id) || raise "Widget '#{id}' not found"
    b = w.absolute_bounds
    center = CrymbleUI::Vec2.new(b.x + b.width / 2, b.y + b.height / 2)
    app.handle_mouse_down(center)
    app.handle_mouse_up(center)
end

# The chip container has no id of its own — reach it through the filter row that does.
private def chip_flow(app : EmbraceApp, col : Int32, shape_id : String) : CrymbleUI::FlowLayout
    row = app.find("filter_row_#{col}_#{shape_id}") || raise "filter row for column #{col} not found"
    found = nil.as(CrymbleUI::FlowLayout?)
    walk = uninitialized Proc(CrymbleUI::Widget, Nil)
    walk = ->(w : CrymbleUI::Widget) do
        if w.is_a?(CrymbleUI::FlowLayout)
            found ||= w.as(CrymbleUI::FlowLayout)
        else
            w.children.each { |c| walk.call(c) }
        end
        nil
    end
    walk.call(row)
    f = found
    raise "no FlowLayout inside filter row #{col}" if f.nil?
    f
end

describe "Filter chips re-flow when the shape panel is resized" do
    it "re-packs on widen and never lets the Perspective overlap the filter list" do
        app = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1400, 900)
        renderer.settle_rendering(app)
        shape = app.shapes.first

        person_col = shape.column_names.index("Person") || shape.column_names.index("Person_Person")
        raise "Person column not found in #{shape.column_names}" if person_col.nil?

        # The tester's steps: expand Filter, then "Add filter: Person".
        click_widget(app, "filter_#{shape.id}")
        renderer.settle_rendering(app)
        click_widget(app, "filter_add_#{person_col}_#{shape.id}")
        renderer.settle_rendering(app)

        flow = chip_flow(app, person_col, shape.id)
        flow.children.size.should be > 5 # precondition: enough chips to wrap

        rows_of = ->{ flow.children.map(&.absolute_bounds.y).uniq.size }
        # The chips' OWN bottom, never the filter row's height — that is the stale value that lies.
        chips_bottom = ->{ flow.children.map(&.absolute_bounds.bottom).max }
        perspective_top = ->{ (app.find("matrix_#{shape.id}") || raise "no matrix section").absolute_bounds.y }

        panel = app.find(shape.id) || raise "shape panel not found"
        wide_rows = rows_of.call
        perspective_top.call.should be >= chips_bottom.call # sane baseline

        # --- narrow the panel (works today; pinned so the fix cannot invert it) ---
        right = panel.absolute_bounds.right
        mid_y = panel.absolute_bounds.y + 300.0
        app.handle_mouse_down(CrymbleUI::Vec2.new(right - 4.0, mid_y))
        renderer.settle_rendering(app)
        app.handle_mouse_move(CrymbleUI::Vec2.new(right - 800.0, mid_y))
        renderer.settle_rendering(app)
        app.handle_mouse_up(CrymbleUI::Vec2.new(right - 800.0, mid_y))
        renderer.settle_rendering(app)

        # NOTE: headless core specs measure text width 0, so a chip is only its box + padding and 16 of
        # them fit in ~505px. The drag below is therefore large (down to ~300px panel width) — that is
        # what makes them wrap here, not a claim about real-world panel sizes.
        narrow_rows = rows_of.call
        narrow_rows.should be > wide_rows
        perspective_top.call.should be >= chips_bottom.call

        # --- widen it back: the reported defect ---
        right2 = panel.absolute_bounds.right
        app.handle_mouse_down(CrymbleUI::Vec2.new(right2 - 4.0, mid_y))
        renderer.settle_rendering(app)
        app.handle_mouse_move(CrymbleUI::Vec2.new(right2 + 320.0, mid_y))
        renderer.settle_rendering(app)

        rows_of.call.should eq(wide_rows)                    # re-packs DURING the drag
        perspective_top.call.should be >= chips_bottom.call   # and no overlap mid-drag

        app.handle_mouse_up(CrymbleUI::Vec2.new(right2 + 320.0, mid_y))
        renderer.settle_rendering(app)

        rows_of.call.should eq(wide_rows)                    # …and after release
        perspective_top.call.should be >= chips_bottom.call

        # A rebuild must not reintroduce it (reconciliation carries layout state).
        app.request_rebuild
        renderer.settle_rendering(app)
        rows_of.call.should eq(wide_rows)
        perspective_top.call.should be >= chips_bottom.call
    end
end
