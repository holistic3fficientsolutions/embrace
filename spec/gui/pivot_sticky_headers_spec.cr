require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# A pivoted perspective groups records under a row-header, and that header must be STICKY: the
# matrix keeps a pinned line's compound disposition up to date every frame (StickyMath.compound_axis),
# so a group label stays readable while its span scrolls past. An ordinary scrolling column gets that
# only at layout time, and the label then freezes or drifts with the content.
#
# crymbleui's own VirtualMatrix demo is right for exactly this reason — its `row_hdr_levels` columns
# sit at the TAIL of the column scroll order, which is how stickiness is expressed. Field report
# 2026-09-03: in embrace the group label sat at a constant height instead.
private CI_NAME = GUI::Widget::FieldlistConstants::ColumnIndices::Name

# One real Field-list drag: the exact proc a GUI drop runs.
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
    zones.empty?.should be_false, "no append drop zone for #{hover.inspect}"
    zones.max_by(&.absolute_bounds.y).on_drop(FieldDragData.new(ri, name), CrymbleUI::Vec2.new(0.0, 0.0))
    renderer.settle_rendering(app)
end

private def grouped_app : {EmbraceApp, CrymbleUI::Testing::TestRenderer}
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Groups
        Grp
        a
        b

        Items
        Grp_Grp | Val
        a | 1
        b | 2
        b | 3
        b | 4
        b | 5
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("Items", p, p.context.clone, hash["Items"].as(TableLID))
    app.request_rebuild
    renderer = CrymbleUI::Testing::TestRenderer.new(1100, 600)
    renderer.settle_rendering(app)
    app.find("fieldlist_#{app.shapes.first.id}").not_nil!.as(CrymbleUI::TreeNode).toggle
    app.request_rebuild
    renderer.settle_rendering(app)
    {app, renderer}
end

# The same Shape, but big enough to scroll: 12 groups of 5. Built through the SAME two drags,
# because the drag path is what the field report used and what a hand-written fieldlist skips.
private def big_grouped_app : {EmbraceApp, CrymbleUI::Testing::TestRenderer}
    app = EmbraceApp.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    body = String.build do |io|
        io << "Groups\nGrp\n"
        (0...12).each { |g| io << "g#{g}\n" }
        io << "\nItems\nGrp_Grp | Val\n"
        (0...12).each { |g| (0...5).each { |i| io << "g#{g} | #{g * 5 + i}\n" } }
    end
    TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash) << body
    app.shapes.clear
    app.shapes << ShapeState.new("Items", app.persistency, app.persistency.context.clone, hash["Items"].as(TableLID))
    app.request_rebuild
    renderer = CrymbleUI::Testing::TestRenderer.new(1100, 600)
    renderer.settle_rendering(app)
    app.find("fieldlist_#{app.shapes.first.id}").not_nil!.as(CrymbleUI::TreeNode).toggle
    app.request_rebuild
    renderer.settle_rendering(app)
    fl_move(app, renderer, "Grp", "Rows cluster block, level 1")
    fl_move(app, renderer, "Rank", "Rows cluster block, level 2")
    {app, renderer}
end

# The field-report configuration (ab.embrace, 2026-09-03): BOTH fields dropped into the SAME Rows
# cluster level — one level with two header columns, not a nested hierarchy. `ab` clusters (its cell
# spans its records), `Rank` labels each record.
private def same_level_app : {EmbraceApp, CrymbleUI::Testing::TestRenderer}
    app = EmbraceApp.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    body = String.build do |io|
        io << "Items\nab | Val\n"
        (0...15).each { |g| (0...4).each { |i| io << "#{('a' + g)} | #{g * 4 + i}\n" } }
    end
    TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash) << body
    app.shapes.clear
    app.shapes << ShapeState.new("Items", app.persistency, app.persistency.context.clone, hash["Items"].as(TableLID))
    app.request_rebuild
    renderer = CrymbleUI::Testing::TestRenderer.new(1100, 600)
    renderer.settle_rendering(app)
    app.find("fieldlist_#{app.shapes.first.id}").not_nil!.as(CrymbleUI::TreeNode).toggle
    app.request_rebuild
    renderer.settle_rendering(app)
    fl_move(app, renderer, "ab", "Rows cluster block, level 1")
    fl_move(app, renderer, "Rank", "Rows cluster block, level 1")
    {app, renderer}
end

private def sticky_tail(cols : Array(Int32)) : Set(Int32)
    # exactly VirtualMatrix#derive_sticky_count: the trailing run that forms {0..N-1}
    sticky = Set(Int32).new
    cols.reverse_each do |idx|
        probe = sticky.dup << idx
        break unless probe == (0...probe.size).to_set
        sticky = probe
    end
    sticky
end

private def pivoted_shape : {ShapeState, EmbraceApp}
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Sheet
        grp | c2
        a | 1
        b | 2
        b | 3
    EOT
    app.shapes.clear
    shape = ShapeState.new("F", p, p.context.clone, hash["Sheet"].as(TableLID))
    app.shapes << shape
    shape.fieldlist_mirror_diagonal! # a row-axis hierarchy: the group field above Rank
    shape.update(true)
    {shape, app}
end

describe "a pivoted perspective's row headers" do
    it "produces row-SPANNING group headers (the instrument for the two below)" do
        shape, _ = pivoted_shape
        adapter = shape.matrix_adapter.not_nil!
        rows, cols = adapter.get_scrollorder
        spans = rows.flat_map do |r|
            cols.compact_map do |c|
                bb = adapter.cell_get_bounding_box({r, c})
                {r, c} if bb[0][0] != bb[1][0]
            end
        end
        spans.should_not be_empty
    end

    it "marks them as HEADER cells, so the matrix can style and pin them" do
        shape, _ = pivoted_shape
        adapter = shape.matrix_adapter.not_nil!
        rows, cols = adapter.get_scrollorder
        headers = rows.flat_map { |r| cols.compact_map { |c| {r, c} if adapter.cell_get_header_info({r, c}) } }
        headers.should_not be_empty
    end

    it "keeps the row-header columns STICKY once a field is grouped into Rows" do
        # THE SEAM between adapter and matrix. Stickiness has no flag: it is the trailing run of the
        # column scroll order that forms {0..N-1}. A row-SPANNING header outside that run reaches the
        # matrix as ordinary scrolling content, whose disposition is computed once at layout instead
        # of every frame — the group label would then freeze in place.
        #
        # TWO drops, not one: a single drop only adds a second FLAT level-0 header column (measured —
        # identical TSV, every bounding box a single cell). The hierarchy needs a second level, and a
        # fixture that skips it tests nothing while looking like it grouped.
        app, renderer = big_grouped_app
        adapter = app.shapes.first.matrix_adapter.not_nil!
        rows, cols = adapter.get_scrollorder

        spanning = rows.flat_map { |r| cols.compact_map { |c|
            bb = adapter.cell_get_bounding_box({r, c})
            {r, c} if bb[0][0] != bb[1][0]
        } }
        spanning.should_not be_empty, "the drags did not pivot: no row-spanning cell in #{cols}"

        tail = sticky_tail(cols)
        spanning.each do |(_, c)|
            tail.includes?(c).should be_true,
                "row-spanning column #{c} is outside the sticky tail #{tail.to_a.sort} of order #{cols}"
        end
    end

    it "pins a group label at the boundary and drifts it as its span scrolls out" do
        # The field report (2026-09-03): the group label sat at a constant height instead of gliding.
        # StickyMath.compound_axis collapses a merged cell to the VISIBLE slice of its span and pins
        # that slice at the boundary, so the centred label moves at roughly HALF the scroll speed
        # while the group straddles the edge — never at zero, and never at full speed.
        app, renderer = big_grouped_app
        adapter = app.shapes.first.matrix_adapter.not_nil!
        rows, cols = adapter.get_scrollorder

        span = rows.flat_map { |r| cols.compact_map { |c|
            bb = adapter.cell_get_bounding_box({r, c})
            bb if bb[1][0] - bb[0][0] == 4 && bb[0][0] >= 25
        } }.first
        anchor = {span[0][0], span[0][1]}
        leaf = {span[0][0] + 1, cols.max}

        vm = adapter.virtual_matrix.not_nil!
        point = vm.absolute_bounds.center
        18.times { adapter.virtual_matrix.not_nil!.on_mouse_wheel(CrymbleUI::Vec2.new(0.0, -1.0), point); renderer.render_frame(app) }

        vp = vm.absolute_bounds
        label_ys = [] of Float64
        leaf_ys = [] of Float64
        on_screen = [] of Bool
        6.times do
            live = adapter.virtual_matrix.not_nil!
            live.on_mouse_wheel(CrymbleUI::Vec2.new(0.0, -1.0), point)
            renderer.render_frame(app)
            w = live.active_cells[anchor]?
            l = live.active_cells[leaf]?
            next unless w && l
            text = w.to_primitives(w.absolute_bounds).find { |pr| pr.is_a?(CrymbleUI::DrawText) }
            next unless text.is_a?(CrymbleUI::DrawText)
            y = w.absolute_bounds.y + text.position.y
            label_ys << y
            leaf_ys << l.absolute_bounds.y
            on_screen << (y >= vp.y && y <= vp.y + vp.height)
        end

        # Instrument: without a moving control, a frozen label is indistinguishable from a frozen grid.
        leaf_steps = leaf_ys.each_cons(2).map { |(a, b)| a - b }.to_a
        leaf_steps.should_not be_empty
        leaf_steps.all? { |d| d > 20.0 }.should be_true, "the grid did not scroll: leaf steps #{leaf_steps}"
        label_steps = label_ys.each_cons(2).map { |(a, b)| a - b }.to_a

        # The discriminating window: a step where the label is on screen at BOTH ends and moves
        # strictly slower than the content but not at all frozen. Parking (the label leaving at the
        # end of its span) also "moves slower", so it must be excluded — otherwise a label frozen in
        # place, which is exactly the reported defect, satisfies the assertion. Measured: this window
        # is empty when StickyMath.compound_axis is made to skip the pin (verified RED).
        drift = (0...label_steps.size).select do |i|
            on_screen[i] && on_screen[i + 1] &&
                label_steps[i] > 0.5 && label_steps[i] < leaf_steps[i] - 1.0
        end
        drift.should_not be_empty,
            "the group label never drifted: label #{label_ys} (on screen #{on_screen}) against leaf #{leaf_ys}"
    end
    it "keeps SAME-LEVEL row headers sticky, so the group label can pin" do
        # Field report 2026-09-03 (ab.embrace), reproduced from the app's own seam log:
        #   [seam] cols=[2, 0, 1] sticky_tail=[] row_spanning_outside_tail=["{0,0}hdr" ... "{7,0}hdr"]
        #
        # Two fields in ONE Rows cluster level give one header BLOCK of two columns. The block was
        # emitted ASCENDING ([0,1]), so the order ended [2,0,1] whose trailing run is {1} — not {0} —
        # and derive_sticky_count stops at zero. With no sticky column the spanning group headers
        # reach the matrix as CONTENT compounds, which by design keep fixed content-space sizes
        # (VIRTUAL_MATRIX_ARCHITECTURE.md, "Visible Portion Computation") and are never pinned: the
        # group label scrolled out with its rows instead of gliding at half speed.
        #
        # The nested two-level arrangement above never caught this: there each header block is a
        # SINGLE column, so ascending and descending are the same array.
        app, _ = same_level_app
        adapter = app.shapes.first.matrix_adapter.not_nil!
        rows, cols = adapter.get_scrollorder

        spanning = rows.flat_map { |r| cols.compact_map { |c|
            bb = adapter.cell_get_bounding_box({r, c})
            c if bb[0][0] != bb[1][0]
        } }.uniq
        spanning.should_not be_empty, "fixture did not cluster: order #{cols}"

        tail = sticky_tail(cols)
        spanning.each do |c|
            tail.includes?(c).should be_true,
                "spanning column #{c} is outside the sticky tail #{tail.to_a.sort} of order #{cols}"
        end
    end
end
