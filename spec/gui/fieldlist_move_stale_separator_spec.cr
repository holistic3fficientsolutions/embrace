require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Tester repro (post v2.0.18): a Field-list move sequence on the demo file leaves broken row
# separators in the Perspective's first column (c1), exactly where cells were previously merged.
#
# Sequence (Allocations shape): Time -> Columns; Project -> Rows (below Rank); Person -> Rows
# (below Project); Rank -> Unused; Project -> Rows (below Person). Before the last move c1 is
# Project with five span-2 merges (Arts/Healing/Law/Peace/Survival x2); after it c1 is Person,
# all span 1 -- every row boundary must show a separator again.
#
# ROOT: ShapeState#update's version gate (persistency + context) misses the FIELDLIST's own
# version, so a field-list drop never fires matrix_adapter.invalidate_all! and the
# VirtualMatrix's flush_invalidate_all -- the buffer-clear channel -- never runs. The rebuild
# recreates the cells (data and geometry correct) into the RETAINED viewport_cache buffer; the
# 3px separator gaps vacated by the old span-2 cells are covered by no widget and keep the old
# cell fill. The crymbleui reconcile clear (VirtualMatrix#copy_state_from) only fires when grid
# DIMENSIONS change -- this sequence goes 16x5 -> 16x5, its exact blind spot.
#
# The pixel oracle is valid here: TestRenderBackend retains stale buffer pixels just like the
# real RenderTexture does in this flow, and a correct clear+rerender overwrites the band with
# the layer background -- asserting "band == background" is RED without the fix, GREEN with it.

private CI_NAME  = GUI::Widget::FieldlistConstants::ColumnIndices::Name
private CI_CLASS = GUI::Widget::FieldlistConstants::ColumnIndices::Class
private CI_RANK  = GUI::Widget::FieldlistConstants::ColumnIndices::Rank
private RC_COL   = GUI::Widget::FieldlistConstants::RowClass::ColumnHeader
private RC_ROW   = GUI::Widget::FieldlistConstants::RowClass::RowHeader
private RC_AGG   = GUI::Widget::FieldlistConstants::RowClass::Aggregate
private RC_FREE  = GUI::Widget::FieldlistConstants::RowClass::Unused

private def make_demo_app : EmbraceApp
    app = EmbraceApp.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash)
    help << <<-EOT
        Projects
        Project
        Arts
        Autonomy
        Curiosity
        Healing
        Justice
        Law
        Loyality
        Peace
        Suppression
        Survival

        Times
        Time
        Former
        Future
        Present

        Persons
        Person
        Alan
        Amanita
        Denny
        Helen
        Jared
        Jezelia
        Kaden
        Max
        Melanie
        Rafferty
        Riley
        Samwise
        Sauron
        Wanda
        Will

        Allocations
        Person_Person | Time_Time | Project_Project | Allocation
        Alan | Present | Law | 100
        Denny | Present | Law | 100
        Sauron | Former | Suppression | 100
        Samwise | Former | Peace | 100
        Wanda | Future | Peace | 100
        Melanie | Future | Survival | 100
        Jared | Future | Survival | 100
        Jezelia | Future | Autonomy | 100
        Rafferty | Future | Curiosity | 100
        Kaden | Future | Loyality | 100
        Max | Present | Healing | 100
        Helen | Present | Healing | 100
        Will | Present | Justice | 100
        Riley | Present | Arts | 100
        Amanita | Present | Arts | 100
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("Allocations", app.persistency, app.persistency.context.clone,
        hash["Allocations"].as(TableLID))
    app.request_rebuild
    app
end

# All DropZoneBoxes under `root` with the given hover text that contain no draggable --
# i.e. a section's append/catch-all zone, not a field's own insert-before zone.
private def append_drop_zone(app : EmbraceApp, hover : String) : CrymbleUI::DropZoneBox
    shape = app.shapes.first
    root = app.find("fieldlist_#{shape.id}").not_nil!
    found = [] of CrymbleUI::DropZoneBox
    stack = [root.as(CrymbleUI::Widget)]
    while w = stack.pop?
        if w.is_a?(CrymbleUI::DropZoneBox) && w.hover_text == hover
            has_draggable = false
            inner = [w.as(CrymbleUI::Widget)]
            while x = inner.pop?
                (has_draggable = true; break) if x.is_a?(CrymbleUI::DraggableBox)
                x.children.each { |c| inner << c }
            end
            found << w unless has_draggable
        end
        w.children.each { |c| stack << c }
    end
    found.empty?.should be_false, "no append drop zone for #{hover.inspect}"
    found.max_by(&.absolute_bounds.y)
end

# Perform one real Field-list drag-drop: invoke the section's drop handler (the exact proc a
# GUI drag runs -- class/level/rank writes + request_rebuild), then settle like the app would.
private def fl_move(app : EmbraceApp, renderer, name : String, hover : String)
    adapter = app.shapes.first.fieldlist_adapter.not_nil!
    ri = (0...adapter.size).find { |i| adapter.cell_read({i, CI_NAME}).to_s == name }.not_nil!
    append_drop_zone(app, hover).on_drop(FieldDragData.new(ri, name), CrymbleUI::Vec2.new(0.0, 0.0))
    renderer.settle_rendering(app)
end

private def run_move_sequence(app : EmbraceApp, renderer, &between : ->)
    shape = app.shapes.first
    app.find("fieldlist_#{shape.id}").not_nil!.as(CrymbleUI::TreeNode).toggle
    app.request_rebuild
    renderer.settle_rendering(app)

    fl_move(app, renderer, "Time", "Columns cluster block, level 1")
    fl_move(app, renderer, "Project", "Rows cluster block, level 1")
    fl_move(app, renderer, "Person", "Rows cluster block, level 1")
    fl_move(app, renderer, "Rank", "Unused block")
    between.call
    fl_move(app, renderer, "Project", "Rows cluster block, level 1")
end

private def assert_final_config(app : EmbraceApp)
    adapter = app.shapes.first.fieldlist_adapter.not_nil!
    state = (0...adapter.size).map do |ri|
        {adapter.cell_read({ri, CI_NAME}).to_s,
         adapter.cell_read({ri, CI_CLASS}),
         adapter.cell_read({ri, CI_RANK}).as(Int64)}
    end.to_h { |name, cls, rank| {name, {cls, rank}} }
    state["Rank"][0].should eq(RC_FREE)
    state["Time"][0].should eq(RC_COL)
    state["Person"][0].should eq(RC_ROW)
    state["Project"][0].should eq(RC_ROW)
    state["Allocation"][0].should eq(RC_AGG)
    (state["Person"][1] < state["Project"][1]).should be_true # Person ABOVE Project
end

describe "Field-list move: separators where cells were previously merged" do
    around_all do |example|
        ENV["EMBRACE_SHAPE_PANEL_WIDTH"] = "900"
        ENV["EMBRACE_SHAPE_PANEL_HEIGHT"] = "700"
        example.run
        ENV.delete("EMBRACE_SHAPE_PANEL_WIDTH")
        ENV.delete("EMBRACE_SHAPE_PANEL_HEIGHT")
    end

    it "repaints the vacated separator bands in c1 after the final move" do
        app = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1600, 1000)
        renderer.settle_rendering(app)
        shape = app.shapes.first

        # Anchor rows of the span-2 merged c1 cells BEFORE the final move (widget taller than
        # one 20px row) -- their bottom separator band is the one the old cell painted over.
        merged_anchors = [] of Int32
        singleton_h = 0.0
        run_move_sequence(app, renderer) do
            vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
            vm.active_cells.each do |key, w|
                next unless key[1] == 0
                if w.bounds.height > 30.0
                    merged_anchors << key[0]
                else
                    singleton_h = w.bounds.height
                end
            end
            merged_anchors.size.should eq(5) # Arts, Healing, Law, Peace, Survival
        end
        assert_final_config(app)

        vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
        layer = vm.@content_layer.not_nil!
        backend = layer.backend.not_nil!.as(CrymbleUI::Testing::TestRenderBackend)
        bg = layer.background_color

        # After the move every c1 cell is span-1 (data/geometry are known-correct; the bug is
        # purely the retained buffer pixels in the bands BETWEEN them).
        cells0 = vm.active_cells.select { |k, _| k[1] == 0 }
        cells0.each { |_, w| w.bounds.height.should be_close(singleton_h, 0.01) }

        checked = 0
        stale = [] of String
        merged_anchors.sort.each do |a|
            top_w = cells0[{a, 0}]?
            bot_w = cells0[{a + 1, 0}]?
            next unless top_w && bot_w
            band_top = top_w.absolute_bounds.y + top_w.bounds.height
            band_bot = bot_w.absolute_bounds.y
            # buffer coords: absolute -> layer-local -> minus buffer_origin
            bx0 = (top_w.absolute_bounds.x - layer.bounds.x - layer.buffer_origin.x).to_i + 2
            bx1 = bx0 + top_w.bounds.width.to_i - 4
            by0 = (band_top - layer.bounds.y - layer.buffer_origin.y).to_i
            by1 = (band_bot - layer.bounds.y - layer.buffer_origin.y).to_i - 1
            next if by1 >= backend.height || bx1 >= backend.width || by0 < 0 || bx0 < 0
            checked += 1
            (by0..by1).each do |by|
                (bx0..bx1).step(4) do |bx|
                    px = backend.get_pixel(bx, by)
                    next if px.nil? || px == bg
                    stale << "rows #{a}/#{a + 1} buffer(#{bx},#{by}) #{px} != bg #{bg}"
                end
            end
        end
        checked.should be >= 3 # instrument sanity: the bands are inside the buffer
        stale.should be_empty
    end

    {% if flag?(:cache_validation) %}
    it "the whole sequence is dual-pipeline clean (cached == immediate)" do
        app = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1600, 1000)
        renderer.settle_rendering(app)
        CrymbleUI::CacheValidation.enable_all
        CrymbleUI::CacheValidation.clear_failures!
        run_move_sequence(app, renderer) { }
        CrymbleUI::CacheValidation.assert_no_failures!
    end
    {% end %}
end
