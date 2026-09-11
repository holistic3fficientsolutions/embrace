require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# The placement harness on the reported Perspective — WITH A MEASURED LIMITATION, stated first
# because these examples pass and that is misleading on its own.
#
# Embrace's spec harness has no font: `Widget.measure_text` returns 0x0. Auto-size derives a row's
# height from its MEASURED content, so in here it never expands anything — verified 2026-09-08, the
# eight-line value in cell (0,2) gets `box h=20.0` instead of ~112. The tall row this fixture is
# supposed to contain therefore does not exist, and every invariant below passes over a grid where
# the reported scenario is absent.
#
# So this is NOT the instrument for auto-size-driven placement defects. Use
# crymbleui/spec/widgets/virtual_matrix/placement_invariants_spec.cr, whose harness has real text
# metrics. What this file is good for is the non-auto-size half: the compound span, the rank column,
# the sticky-column geometry, and index-space regressions in the embrace adapter itself.
#
# Kept because it exercises the real pivot rather than a synthetic adapter.
#
# crymbleui has the same invariants over the vmatrix demo's configuration, and they kept coming
# back green while he kept finding defects — because that fixture has single-line "(r,c)" cells
# and no compound over a multiline value. A grid with no overflowing block cannot show a defect
# about overflowing blocks. This reproduces the Perspective he reports from: a group column that
# SPANS, a rank column beside it, and a value that is many lines tall, with auto-size on.
#
#   I1  nothing moves further than the input that moved it
#   I3  content is never displaced outside its own box
#   I5  resizing the panel never moves content inside its own box
#
# and it sweeps the inputs he actually varies: scrolling, and the panel's HEIGHT and WIDTH.

private CI_NAME = GUI::Widget::FieldlistConstants::ColumnIndices::Name

private record Placed, text : String, x : Float64, y : Float64, box : CrymbleUI::Rect
private record Snapshot, input : Float64, items : Array(Placed)

private def fl_move(app : EmbraceApp, renderer, name : String, hover : String) : Nil
    adapter = app.shapes.first.fieldlist_adapter.not_nil!
    ri = (0...adapter.size).find { |i| adapter.cell_read({i, CI_NAME}).to_s == name }.not_nil!
    root = app.find("fieldlist_#{app.shapes.first.id}").not_nil!
    zones = [] of CrymbleUI::DropZoneBox
    stack = [root.as(CrymbleUI::Widget)]
    while w = stack.pop?
        if w.is_a?(CrymbleUI::DropZoneBox) && w.hover_text == hover
            has_drag = false
            inner = [w.as(CrymbleUI::Widget)]
            while x = inner.pop?
                (has_drag = true; break) if x.is_a?(CrymbleUI::DraggableBox)
                x.children.each { |c| inner << c }
            end
            zones << w unless has_drag
        end
        w.children.each { |c| stack << c }
    end
    zones.max_by(&.absolute_bounds.y).on_drop(FieldDragData.new(ri, name), CrymbleUI::Vec2.new(0.0, 0.0))
    renderer.settle_rendering(app)
end

# The reported Perspective: "ab" and "Rank" in ONE Rows cluster level (so "ab" spans and "Rank"
# labels each record), and a value column whose first record is many lines — his c3 showing
# A B C D E F G H.
private def reported_shape
    app = EmbraceApp.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    body = String.build do |io|
        io << "Items\nab | Val\n"
        io << "a | " << (0...8).map { |i| ('A' + i).to_s }.join("\\n") << "\n"
        (1...4).each { |i| io << "a | v#{i}\n" }
        (0...8).each { |g| (0...4).each { |i| io << "#{('b' + g)} | w#{g}#{i}\n" } }
    end
    TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash) << body
    app.shapes.clear
    app.shapes << ShapeState.new("Items", app.persistency, app.persistency.context.clone,
        hash["Items"].as(TableLID))
    app.request_rebuild
    renderer = CrymbleUI::Testing::TestRenderer.new(1100, 600)
    renderer.settle_rendering(app)
    app.find("fieldlist_#{app.shapes.first.id}").not_nil!.as(CrymbleUI::TreeNode).toggle
    app.request_rebuild
    renderer.settle_rendering(app)
    fl_move(app, renderer, "ab", "Rows cluster block, level 1")
    fl_move(app, renderer, "Rank", "Rows cluster block, level 1")
    vm = app.shapes.first.matrix_adapter.not_nil!.virtual_matrix.not_nil!
    vm.auto_size = true
    app.request_rebuild
    renderer.settle_rendering(app)
    {renderer, app, vm}
end

private def placed(vm) : Array(Placed)
    out = [] of Placed
    vm.active_cells.each do |key, w|
        row, col = key
        content = row >= vm.sticky_row_count && col >= vm.sticky_col_count
        dx = content ? vm.scroll_offset.x : 0.0
        dy = content ? vm.scroll_offset.y : 0.0
        box = CrymbleUI::Rect.new(w.absolute_bounds.x - dx, w.absolute_bounds.y - dy,
            w.bounds.width, w.bounds.height)
        w.to_primitives(w.bounds).each do |p|
            next unless p.is_a?(CrymbleUI::DrawText)
            next if p.text.empty?
            out << Placed.new("#{key[0]},#{key[1]}:#{p.text}", box.x + p.position.x,
                box.y + p.position.y, box)
        end
    end
    out
end

private def jumps(frames : Array(Snapshot), tol = 1.5) : Array(String)
    out = [] of String
    previous = nil.as(Snapshot?)
    frames.each do |snap|
        if prev = previous
            allowed = (snap.input - prev.input).abs + tol
            index = {} of String => Placed
            snap.items.each { |p| index[p.text] = p }
            prev.items.each do |old|
                next unless now = index[old.text]?
                moved = (now.y - old.y).abs
                next if moved <= allowed
                out << "#{old.text} moved #{moved.round(1)}px at #{snap.input.round(0)}"
            end
        end
        previous = snap
    end
    out
end

describe "Perspective placement invariants, on the reported shape" do
    it "I1: nothing moves further than the scroll that moved it" do
        renderer, app, vm = reported_shape
        frames = (0..80).map do |i|
            vm.scroll_offset = CrymbleUI::Vec2.new(0.0, i.to_f64)
            renderer.settle_rendering(app)
            Snapshot.new(i.to_f64, placed(vm))
        end
        jumps(frames).should be_empty,
            "on scroll:\n  #{jumps(frames).first(6).join("\n  ")}"
    end

    it "I5: resizing the panel never moves content inside its own box" do
        renderer, app, vm = reported_shape
        offenders = [] of String
        baseline = {} of String => Float64

        (300..380).each do |h|
            vm.layout(CrymbleUI::BoxConstraints.tight(CrymbleUI::Size.new(700.0, h.to_f64)),
                CrymbleUI::Vec2.zero)
            renderer.settle_rendering(app)
            placed(vm).each do |p|
                next if p.box.height <= 0.0
                offset = p.y - p.box.y
                next unless offset <= 5.0 # content the rule DECLINES to place; a held label is not this
                if first = baseline[p.text]?
                    if (offset - first).abs > 1.5
                        offenders << "#{p.text} sits #{offset.round(1)}px into its box at height #{h}, " \
                                     "but #{first.round(1)}px at the start"
                    end
                else
                    baseline[p.text] = offset
                end
            end
        end
        offenders.should be_empty, "content moved inside its cell on RESIZE:\n  #{offenders.first(6).join("\n  ")}"
    end

    # BALANCE is NOT tested here, deliberately, and it is worth saying why so nobody adds it back.
    #
    # Whether a row's labels sit on one line is the axis these invariants are blind to — I1/I3/I5
    # each track ONE label over time — and it is what #87/#88/#91 were. But this harness cannot
    # judge it: `measure_text` returns 0x0 in core specs, so auto-size never grows a row to fit a
    # block and the TALL ROW of the reported shape never forms. Instrumented with
    # CRYMBLE_HOLD_LOG=1, the only regions present are 20px cells and an 89px compound span, never
    # the 137px row the running app has, and one cell reports content=0.0.
    #
    # A balance test written here therefore fires on a case that is CORRECT: a pinned compound
    # beside row-mates that are properly scrolling away, since an ordinary 20px row absorbs about
    # 3px of push before its box runs out and it clips (UC-5). Measured: the compound reports
    # `visible_lo=0, seen=3` while its neighbours report `visible_lo=135, seen=135` clamped to 6.
    #
    # Balance is tested in crymbleui instead — placement_boxes_spec B2/B4/B5 — which has real font
    # metrics and can build the tall row.

    it "I3: content is never displaced outside its own box" do
        renderer, app, vm = reported_shape
        offenders = [] of String
        (0..80).each do |i|
            vm.scroll_offset = CrymbleUI::Vec2.new(0.0, i.to_f64)
            renderer.settle_rendering(app)
            placed(vm).each do |p|
                next if p.box.height <= 0.0
                if p.y < p.box.y - 1.0 || p.y > p.box.y + p.box.height + 1.0
                    offenders << "#{p.text} at #{i}: y=#{p.y.round(1)} outside " \
                                 "#{p.box.y.round(1)}..#{(p.box.y + p.box.height).round(1)}"
                end
            end
        end
        offenders.should be_empty, "content displaced out of its cell:\n  #{offenders.first(6).join("\n  ")}"
    end
end
