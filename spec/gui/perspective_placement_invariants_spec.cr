require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/embrace_ui"

include Persistency

# CONTAINMENT on embrace's real pivot: a label is never displaced outside its own box, over a
# scroll sweep of the Perspective from the field report - a group column that SPANS, a rank column
# beside it, and a value many lines tall, with auto-size on.
#
# It catches the defect it was written against. With crymble-ui's `PrimitiveBuilder#confine` a
# no-op it fails on `0,0:a` from scroll 53 (y=425.9 against a box ending at 424.4) - the very label
# `confine` names. Measured 2026-09-26; undoing crymble-ui 130f95c (spans sized minus the gutter)
# alone stays green, because `confine` keeps that label in its box too.
#
# Which is how narrow it is: ink a region holds ends in `confine`, which clamps it to the box, so no
# defect upstream of it (a wrong region, band or span) can turn this red. It guards `confine` being
# reached and working on the real pivot, and the widget's own anchoring for ink no region holds.
#
# What it covers, measured: 54 labels, all in TextInput cells (no ComboBox, so its placement path is
# not exercised); the six spanning labels all sit in column 0, which is sticky, so every compound
# here is PINNED; ruler numbers are not in `active_cells` and are not checked. Placement is live
# headless - a line's height falls back to the font size - but `measure_text` returns 0x0, so
# auto-size never grows a row: the eight-line value gets a 20px box, not ~112.
#
# Two more invariants lived here and were REMOVED, each for a measured reason, so nobody adds them
# back unchanged. crymbleui asserts what each should have been, with real text metrics - jumps in
# placement_sweep_spec (property J), continuity under resize in placement_invariants_spec I5:
#
#   "nothing moves further than the scroll that moved it" - the defects it exists for (a compound
#   losing its region: `ink_region_for` without its compound exemption, or `line_span` answering
#   nil) do move labels here, but as a smooth 0.5px per pixel of scroll, never a jump: a pinned
#   compound's box is clipped by the sticky pass to the visible part of its span, so placing against
#   the box instead differs only smoothly. No realistic defect turned it red.
#
#   "resizing the panel never moves content inside its own box" - its sweep never reached placement
#   (the band is derived in `pre_render_flush`, which it did not run), so it compared unchanged
#   frames. Driven properly it fails on CORRECT behaviour: a compound cut by the bottom edge is
#   centred in the slice you can see, 2px into its box at height 314 - and the defect it was for (a
#   band not re-derived after the resize) left it green. What holds under resize is continuity, not
#   stillness.
#
# Balance is not tested either: whether a row's labels sit on one line needs the tall row, which
# this harness cannot build. crymbleui's placement_boxes_spec B2/B5 test it, and its
# placement_invariants_spec I14 tests a frozen compound's padding.

private record Placed, text : String, y : Float64, box : CrymbleUI::Rect

# The reported Perspective: "ab" and "Rank" in ONE Rows cluster level (so "ab" spans and "Rank"
# labels each record), and a value column whose first record is many lines — the report's c3
# showing A B C D E F G H.
private def reported_shape
    body = String.build do |io|
        io << "Items\nab | Val\n"
        io << "a | " << (0...8).map { |i| ('A' + i).to_s }.join("\\n") << "\n"
        (1...4).each { |i| io << "a | v#{i}\n" }
        (0...8).each { |g| (0...4).each { |i| io << "#{('b' + g)} | w#{g}#{i}\n" } }
    end
    app = Fixtures.app(body)[0]
    ui = EmbraceUI.new(app, 1100, 600)
    renderer = ui.renderer
    shape = app.shapes.first
    Fixtures.open_fieldlist(app, renderer) # after the Driver is built: its renderer
    ui.drag ui.fieldlist_field(shape, "Items", "ab"), onto: ui.rows_zone(shape)
    ui.drag ui.fieldlist_field(shape, "Items", "Rank"), onto: ui.rows_zone(shape)
    vm = app.shapes.first.matrix_adapter.not_nil!.virtual_matrix.not_nil!
    vm.auto_size = true
    app.request_rebuild
    renderer.settle_rendering(app)
    labels = placed(vm)
    labels.size.should be >= 40                                # measured: 54
    labels.count { |p| p.box.height > 20.0 }.should be >= 3    # spanning labels - measured: 6
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
            out << Placed.new("#{key[0]},#{key[1]}:#{p.text}", box.y + p.position.y, box)
        end
    end
    out
end

describe "Perspective placement, on the reported shape" do
    it "never displaces content outside its own box" do
        renderer, app, vm = reported_shape
        offenders = [] of String
        checked = 0
        (0..80).each do |i|
            vm.scroll_offset = CrymbleUI::Vec2.new(0.0, i.to_f64)
            renderer.settle_rendering(app)
            placed(vm).each do |p|
                next if p.box.height <= 0.0
                checked += 1
                if p.y < p.box.y - 1.0 || p.y > p.box.y + p.box.height + 1.0
                    offenders << "#{p.text} at #{i}: y=#{p.y.round(1)} outside " \
                                 "#{p.box.y.round(1)}..#{(p.box.y + p.box.height).round(1)}"
                end
            end
        end
        checked.should be >= 3500 # labels checked across the frames - measured: 4737
        offenders.should be_empty, "content displaced out of its cell:\n  #{offenders.first(6).join("\n  ")}"
    end
end
