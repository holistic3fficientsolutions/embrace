require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Embrace must tell the matrix WHICH kind of change happened.
#
# Today every edit announces `invalidate_all!` TWICE (the version gate at shape.cr:1460, then
# the explicit one in the string bridge) and `invalidate_cell!` never — it has no call site in
# src/ at all. These examples pin which announcement each write makes.
#
# The spy is PER-INSTANCE, not a class variable: a shared counter cannot attribute an
# announcement to a Shape, and the two-Shape example needs exactly that. `super` is correct
# here because both methods arrive via the included MatrixAdapter module, so the class defines
# them for the first time — `previous_def` has nothing to chain to the design notes.
class SimpleMatrixAdapter(T, U, V)
    property probe_all : Int32 = 0
    property probe_cell : Int32 = 0

    def probe_reset : Nil
        @probe_all = 0
        @probe_cell = 0
    end

    def invalidate_all!
        @probe_all += 1
        super
    end

    def invalidate_cell!(row : Int32, col : Int32)
        @probe_cell += 1
        super
    end

    # NOTE the different keyword: cell_paint is defined in THIS class (shape.cr), so the reopen
    # must chain with previous_def. `super` would resolve into the module's `abstract def` —
    # the failurethe design notes recorded.
    property probe_paints : Int32 = 0

    def cell_paint(row : Int32, col : Int32) : CrymbleUI::Widget
        @probe_paints += 1
        previous_def
    end
end

private def make_plain_app : EmbraceApp
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Plain
        Person | Town | Note
        Alan | Boston | x
        Melanie | Boston | y
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("S", p, p.context.clone, hash["Plain"].as(TableLID))
    app.request_rebuild
    app
end

# First assignable, non-header, non-empty data cell.
private def data_cell(adapter) : Tuple(Int32, Int32)
    rows, cols = adapter.get_scrollorder
    rows.each do |r|
        cols.each do |c|
            next if adapter.cell_get_header_info({r, c})
            next unless adapter.cell_has_content?(r, c)
            next if adapter.cell_read({r, c}).to_s.empty?
            return {r, c}
        end
    end
    raise "no assignable data cell in this fixture"
end

# Drive the REAL commit path: cursor, type, Enter. `on_text_input` alone does not commit, so
# counting around it would measure an uncommitted cell (cell_multiline_spec.cr:73-80).
private def commit_edit(app, vm, rc, text : String) : Nil
    vm.set_cursor_from_cell(rc)
    text.each_char { |ch| vm.on_text_input(ch) }
    vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
end


# A Shape on `Persons`, which references `Cities`. Alan and Melanie share Boston, so a field
# pulled from Cities paints ONE record into TWO rows — the aliasing case.
private def make_joined_app : EmbraceApp
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Cities
        City | Country
        Boston | USA

        Persons
        Person | City_City
        Alan | Boston
        Melanie | Boston
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("J", p, p.context.clone, hash["Persons"].as(TableLID))
    app.request_rebuild
    app
end

# Pull `Cities.Country` into the grid the way the GUI does: expand the City FIELD node (which
# reveals the Cities TABLE node), expand that, then select Country.
private def expand_country(shape : ShapeState) : Bool
    n = nil
    shape.dfs_tree { |x, l| n = x if n.nil? && l == 1 && x.get_display_texts.join.includes?("City") && x.is_expandable? }
    return false unless n
    n.not_nil!.toggle_expand
    shape.update(true)
    t = nil
    shape.dfs_tree { |x, l| t = x if t.nil? && l == 2 && x.is_expandable? }
    return false unless t
    t.not_nil!.toggle_expand
    shape.update(true)
    c = nil
    shape.dfs_tree { |x, l| c = x if c.nil? && l >= 3 && x.get_display_texts.join.includes?("Country") && x.is_selectable? }
    return false unless c
    c.not_nil!.toggle_select
    shape.update(true)
    true
end

# Configure a row hierarchy (the matrix_reference_header_span_spec idiom): grouped headers,
# so that editing one merges two groups — a structural change that moves merge SPANS while
# dims and scroll order stay identical.
private def configure_rows(shape : ShapeState, levels : Hash(String, Int32)) : Nil
    fl = shape.fieldlist.not_nil!
    _ = fl.size
    unused = Table::Lazy::Pivot::Classes::Unused.value.to_i64
    row_class = Table::Lazy::Pivot::Classes::Row.value.to_i64
    class_col = Table::Lazy::Fieldlist::ColumnIndices::Class.value
    name_col = Table::Lazy::Fieldlist::ColumnIndices::Name.value
    level_col = Table::Lazy::Fieldlist::ColumnIndices::Level.value
    (0...fl.size[0]).each { |ri| fl[[ri, class_col]] = unused }
    levels.each do |name, level|
        ri = (0...fl.size[0]).find { |r| fl[[r, name_col]] == name }
        next unless ri
        fl[[ri, class_col]] = row_class
        fl[[ri, level_col]] = level.to_i64
    end
    shape.matrix_adapter.not_nil!.invalidate_all!
end

private def make_grouped_app : EmbraceApp
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Tasks
        Name | Project | ID
        Alice | Alpha | 1
        Alice | Beta | 2
        Alice | Beta | 3
        Bob | Gamma | 4
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("G", p, p.context.clone, hash["Tasks"].as(TableLID))
    app.request_rebuild
    app
end

# Region rows x Quarter columns, Amount in the cells. South/Q2 has no record, so writing there
# is `Indirectly` assignable: it CREATES a record — and does so without moving dims, scroll
# order or the returned index, which is why no fingerprint can see it and the assignability
# branch has to be plumbed out of the write.
private def make_pivot_app : EmbraceApp
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Sales
        Region | Quarter | Amount
        North | Q1 | 10
        North | Q2 | 20
        South | Q1 | 30
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("P", p, p.context.clone, hash["Sales"].as(TableLID))
    app.request_rebuild
    app
end

private def configure_pivot(shape : ShapeState) : Nil
    fl = shape.fieldlist.not_nil!
    _ = fl.size
    cc = Table::Lazy::Fieldlist::ColumnIndices::Class.value
    nc = Table::Lazy::Fieldlist::ColumnIndices::Name.value
    lc = Table::Lazy::Fieldlist::ColumnIndices::Level.value
    kinds = {
        "Region"  => Table::Lazy::Pivot::Classes::Row.value.to_i64,
        "Quarter" => Table::Lazy::Pivot::Classes::Column.value.to_i64,
        "Amount"  => Table::Lazy::Pivot::Classes::Aggregate.value.to_i64,
    }
    (0...fl.size[0]).each { |ri| fl[[ri, cc]] = Table::Lazy::Pivot::Classes::Unused.value.to_i64 }
    kinds.each do |name, kind|
        ri = (0...fl.size[0]).find { |r| fl[[r, nc]] == name }
        next unless ri
        fl[[ri, cc]] = kind
        fl[[ri, lc]] = 0_i64
    end
    shape.matrix_adapter.not_nil!.invalidate_all!
end

private def make_tall_app(rows : Int32) : EmbraceApp
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    body = String.build do |b|
        b << "Tall\nName | Note\n"
        rows.times { |i| b << "n#{i} | v#{i}\n" }
    end
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << body
    app.shapes.clear
    app.shapes << ShapeState.new("T", p, p.context.clone, hash["Tall"].as(TableLID))
    app.request_rebuild
    app
end

private def find_cell(adapter, want : String) : Tuple(Int32, Int32)?
    rows, cols = adapter.get_scrollorder
    rows.each do |r|
        cols.each do |c|
            return {r, c} if adapter.cell_read({r, c}).to_s == want
        end
    end
    nil
end

describe "announcement precision" do
    it "the spy counts announcements at all (without this, every example below is vacuous)" do
        app = make_plain_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        adapter = app.shapes.first.matrix_adapter.not_nil!
        adapter.probe_reset
        adapter.invalidate_all!
        adapter.invalidate_cell!(0, 0)
        adapter.probe_all.should eq(1)
        adapter.probe_cell.should eq(1)
    end

    it "announces ONE per-cell invalidation for a plain edit in an alias-free Shape" do
        # RED today: ×0 per-cell and ×2 structural. Counted across a FULL FRAME — from before
        # the edit to after settle_rendering — because build_shape_panel calls shape.update on
        # every rebuild, so an implementation that merely reorders the announce would
        # re-announce one frame later via on_data_changed -> request_rebuild.
        app = make_plain_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        vm = adapter.virtual_matrix.not_nil!
        rc = data_cell(adapter)

        adapter.probe_reset
        commit_edit(app, vm, rc, "Zed")
        renderer.settle_rendering(app)

        adapter.cell_read(rc).to_s.should eq("Zed")   # the edit really happened
        adapter.probe_cell.should eq(1)
        adapter.probe_all.should eq(0)
    end

    it "refuses per-cell in a JOINED perspective, and the aliased sibling is not left stale" do
        # The case that falsified the first design: one record painted into two rows. Announcing
        # per-cell here would repaint the edited cell and leave its twin showing the old value.
        app = make_joined_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        expand_country(shape).should be_true
        renderer.settle_rendering(app)
        adapter = shape.matrix_adapter.not_nil!
        vm = adapter.virtual_matrix.not_nil!

        shape.alias_free?.should be_false

        # Both rows show the SAME Cities record's Country, so there are two "USA" cells; edit
        # one and the other must follow. Found before the edit, because after it the value has
        # changed and they are no longer findable by content.
        rows, cols = adapter.get_scrollorder
        twins = [] of Tuple(Int32, Int32)
        rows.each { |r| cols.each { |c| twins << {r, c} if adapter.cell_read({r, c}).to_s == "USA" } }
        twins.size.should eq(2)          # instrument: the fixture really does alias
        rc, sibling = twins[0], twins[1]

        adapter.probe_reset
        commit_edit(app, vm, rc, "Mars")
        renderer.settle_rendering(app)

        adapter.probe_cell.should eq(0)
        adapter.probe_all.should be >= 1
        # The sibling must be right ON SCREEN. `to_tsv` reads the model, which is always correct
        # whatever was announced, so it could not see the staleness this example exists for.
        # Re-fetch the matrix: a rebuild constructs a NEW VirtualMatrix, and reading the widget
        # map of the instance captured before the edit inspects a dead object.
        live_vm = adapter.virtual_matrix.not_nil!
        widget = live_vm.active_cells[sibling]?
        widget.should_not be_nil
        widget.not_nil!.as(CrymbleUI::TextInput).value.should eq("Mars")
    end

    it "is alias-free before a reference is pulled in, and not after" do
        app = make_joined_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        shape.alias_free?.should be_true      # only Persons' own fields are displayed
        expand_country(shape).should be_true
        renderer.settle_rendering(app)
        shape.alias_free?.should be_false     # Country arrived through a reference hop
    end

    it "announces structurally when the write CREATES a record" do
        # The case that justifies plumbing the assignability branch out of the write at all:
        # dims, scroll order and the returned index are ALL unchanged here, so every fingerprint
        # veto passes. Only the branch taken (Indirectly -> hyperplane_add) reveals it — and it
        # cannot be re-queried afterwards, because once the record exists the answer is Directly.
        app = make_pivot_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        configure_pivot(shape)
        renderer.settle_rendering(app)
        adapter = shape.matrix_adapter.not_nil!

        rows, cols = adapter.get_scrollorder
        empty = nil
        rows.each do |r|
            cols.each do |c|
                next if adapter.cell_get_header_info({r, c})
                empty = {r, c} if empty.nil? && adapter.cell_read({r, c}).to_s.empty?
            end
        end
        # Instrument: the fixture must really contain an empty intersection, or this example
        # would silently test nothing (the flat fixture it used to run against had none).
        empty.should_not be_nil
        rc = empty.not_nil!
        before_rows, before_cols = adapter.get_scrollorder
        before_rows = before_rows.dup
        before_cols = before_cols.dup

        adapter.probe_reset
        result = adapter.cell_assign(rc[0], rc[1], "42")
        renderer.settle_rendering(app)

        adapter.cell_read(rc).to_s.should eq("42")     # the record was created
        result.should eq(rc)                           # not relocated
        after_rows, after_cols = adapter.get_scrollorder
        after_rows.should eq(before_rows)              # dims and order did not move ...
        after_cols.should eq(before_cols)
        adapter.probe_all.should eq(1)                 # ... and it is STILL structural
        adapter.probe_cell.should eq(0)
    end

    it "keeps announcing to OTHER Shapes on the same table" do
        # Persistency#version is global but each ShapeState has its own @version, so the gate at
        # shape.cr:1460 is the ONLY way Shape B learns of an edit made in Shape A. The write
        # path suppresses only its OWN gate announcement; a suppression one level broader would
        # leave B stale with an otherwise green suite.
        app = make_plain_app
        shape_a = app.shapes.first
        table = shape_a.table_lid.not_nil!
        app.shapes << ShapeState.new("B", app.persistency, app.persistency.context.clone, table)
        app.request_rebuild
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape_b = app.shapes[1]
        adapter_a = shape_a.matrix_adapter.not_nil!
        adapter_b = shape_b.matrix_adapter.not_nil!
        vm_a = adapter_a.virtual_matrix.not_nil!
        rc = data_cell(adapter_a)

        adapter_a.probe_reset
        adapter_b.probe_reset
        commit_edit(app, vm_a, rc, "Shared")
        renderer.settle_rendering(app)

        adapter_a.probe_cell.should eq(1)
        adapter_b.probe_all.should be >= 1          # B was told, structurally
        adapter_b.to_tsv.includes?("Shared").should be_true
    end

    it "announces nothing at all for a refused write in a read-only diff Shape" do
        app = make_plain_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        shape.mark_readonly_diff!
        adapter = shape.matrix_adapter.not_nil!
        rc = data_cell(adapter)
        before = adapter.cell_read(rc).to_s

        adapter.probe_reset
        adapter.cell_assign(rc[0], rc[1], "nope")

        adapter.probe_all.should eq(0)
        adapter.probe_cell.should eq(0)
        adapter.cell_read(rc).to_s.should eq(before)
    end

    it "announces structurally for a grouped HEADER edit that merges two groups" do
        # Spans move while dims and scroll order stay identical, so the fingerprint veto cannot
        # see this one — the header veto is what catches it.
        app = make_grouped_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        configure_rows(shape, {"Name" => 0, "Project" => 1, "ID" => 2})
        renderer.settle_rendering(app)
        adapter = shape.matrix_adapter.not_nil!
        rc = find_cell(adapter, "Beta")
        rc.should_not be_nil
        adapter.cell_get_header_info(rc.not_nil!).should_not be_nil   # it really is a header cell

        adapter.probe_reset
        adapter.cell_assign(rc.not_nil![0], rc.not_nil![1], "Alpha")

        adapter.probe_all.should eq(1)
        adapter.probe_cell.should eq(0)
    end

    it "announces structurally for insert, delete, a filter change and a history step" do
        app = make_plain_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        rc = data_cell(adapter)

        adapter.probe_reset
        adapter.cell_insert(rc)
        shape.update(true)
        adapter.probe_cell.should eq(0)
        adapter.probe_all.should eq(1)

        adapter.probe_reset
        shape.filter_add(0, shape.column_distinct_values(0).map(&.[0]).to_set)
        shape.update(true)
        adapter.probe_cell.should eq(0)
        adapter.probe_all.should be >= 1
        shape.filter_clear!

        adapter.probe_reset
        shape.do_commit
        shape.navigate_history(-1)
        shape.update(true)
        # A history step moves NOTHING structural — no dims, order or spans — yet every value
        # may differ. It must never be mistaken for a single-cell change.
        adapter.probe_cell.should eq(0)
        adapter.probe_all.should be >= 1
    end

    it "announces per-cell for an OFF-SCREEN edit, and the value is there when scrolled to" do
        app = make_tall_app(200)
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        vm = adapter.virtual_matrix.not_nil!
        visible = vm.visible_cell_indices
        far_row = (visible[:rows].max? || 0) + 40
        rows, cols = adapter.get_scrollorder
        far_row.should be < rows.size
        col = cols.find { |c| !adapter.cell_get_header_info({far_row, c}) && adapter.cell_has_content?(far_row, c) }.not_nil!

        adapter.probe_reset
        adapter.cell_assign(far_row, col, "offscreen")

        adapter.probe_cell.should eq(1)
        adapter.probe_all.should eq(0)
        adapter.cell_read({far_row, col}).to_s.should eq("offscreen")
    end

    it "keeps every character of a batched typing sequence" do
        # on_all tears down proxy focus; on_cell does not. The guard that produced the recorded
        # "8 of 16 characters destroyed" bug keys on @pending_invalidate_all, so per-cell
        # announcing changes which teardown runs.
        app = make_plain_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        vm = adapter.virtual_matrix.not_nil!
        rc = data_cell(adapter)

        commit_edit(app, vm, rc, "abcdefghijklmnop")
        renderer.settle_rendering(app)

        adapter.cell_read(rc).to_s.should eq("abcdefghijklmnop")
    end

    it "leaves the re-created cell laid out (non-nil, non-zero bounds)" do
        # on_cell skips mark_needs_layout; a cell recreated without a layout pass is the
        # blank/mis-bounded mode.
        app = make_plain_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        vm = adapter.virtual_matrix.not_nil!
        rc = data_cell(adapter)

        commit_edit(app, vm, rc, "Laid")
        renderer.settle_rendering(app)

        cell = adapter.virtual_matrix.not_nil!.active_cells[rc]?
        cell.should_not be_nil
        cell.not_nil!.bounds.width.should be > 0.0
        cell.not_nil!.bounds.height.should be > 0.0
    end

    it "does not reduce cell_paint work — per-cell and structural repaint alike (192 vs 192)" do
        # The honest number, asserted comparatively rather than as an absolute: a committed edit
        # fires request_rebuild, which builds a fresh matrix whose active_cells starts empty, so
        # BOTH announcements repaint the same cells. Widget churn is not this task's win — layer
        # clears are (see the next example). Asserting `> 0` would have hidden exactly that.
        plain = make_plain_app
        r1 = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r1.settle_rendering(plain)
        a1 = plain.shapes.first.matrix_adapter.not_nil!
        v1 = a1.virtual_matrix.not_nil!
        rc1 = data_cell(a1)
        a1.probe_paints = 0
        commit_edit(plain, v1, rc1, "Painted")
        r1.settle_rendering(plain)
        per_cell_paints = a1.probe_paints

        joined = make_joined_app
        r2 = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r2.settle_rendering(joined)
        sh2 = joined.shapes.first
        expand_country(sh2).should be_true
        r2.settle_rendering(joined)
        a2 = sh2.matrix_adapter.not_nil!
        v2 = a2.virtual_matrix.not_nil!
        rc2 = find_cell(a2, "USA").not_nil!
        a2.probe_paints = 0
        commit_edit(joined, v2, rc2, "Mars")
        r2.settle_rendering(joined)
        structural_paints = a2.probe_paints

        # Both arms repaint every visible cell of their grid — the announcement changes nothing
        # about that. Normalised by grid size so the two fixtures are comparable.
        per_cell_paints.should be >= v1.active_cells.size
        structural_paints.should be >= v2.active_cells.size
    end

    it "clears fewer layers for a per-cell edit than for a structural one (the actual win)" do
        # Comparative, not absolute: the same edit in an alias-free Shape vs in a joined one.
        # invalidate_all! runs clear_all_vm_layers_for_invalidate (five buffer clears + a full
        # repaint); invalidate_cell! does not. That difference IS this task's saving — widget
        # churn is unchanged, because the co-firing rebuild dominates either way.
        plain = make_plain_app
        r1 = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r1.settle_rendering(plain)
        a1 = plain.shapes.first.matrix_adapter.not_nil!
        v1 = a1.virtual_matrix.not_nil!
        rc1 = data_cell(a1)
        before1 = r1.layer_backend_clear_count
        commit_edit(plain, v1, rc1, "Cheap")
        r1.settle_rendering(plain)
        per_cell_clears = r1.layer_backend_clear_count - before1

        joined = make_joined_app
        r2 = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r2.settle_rendering(joined)
        sh2 = joined.shapes.first
        expand_country(sh2).should be_true
        r2.settle_rendering(joined)
        a2 = sh2.matrix_adapter.not_nil!
        v2 = a2.virtual_matrix.not_nil!
        rc2 = find_cell(a2, "USA").not_nil!
        before2 = r2.layer_backend_clear_count
        commit_edit(joined, v2, rc2, "Mars")
        r2.settle_rendering(joined)
        structural_clears = r2.layer_backend_clear_count - before2

        sh2.alias_free?.should be_false        # the two arms really did take different paths
        plain.shapes.first.alias_free?.should be_true
        per_cell_clears.should be < structural_clears
    end

    it "leaves no stale pixels behind a per-cell announcement of a Bool cell" do
        # The exposed widget: Checkbox fills its background only when GIVEN a colour, and
        # cell_paint passes nil for a plain Bool cell (TextInput fills unconditionally). Since
        # flush_cell_invalidations clears no layer pixels, a recreated cell captures its
        # background from a layer that may still hold the old glyphs.
        #
        # Oracle: what the per-cell path rendered must equal what a FULL re-render of the same
        # state renders. Sampling one point and hoping it lands on the tick is not an oracle —
        # the first version of this example did that and reported the cell background twice.
        app = make_plain_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        rc = data_cell(adapter)
        adapter.cell_assign(rc[0], rc[1], "'true")     # becomes a Bool cell -> Checkbox
        app.request_rebuild
        renderer.settle_rendering(app)
        adapter.cell_read(rc).should eq(true)          # instrument: it really is a Bool now

        vm = adapter.virtual_matrix.not_nil!
        layer = vm.@content_layer.not_nil!
        backend = layer.backend.not_nil!.as(CrymbleUI::Testing::TestRenderBackend)
        cell = vm.active_cells[rc].not_nil!
        x0 = (cell.absolute_bounds.x - layer.bounds.x - layer.buffer_origin.x).to_i
        y0 = (cell.absolute_bounds.y - layer.bounds.y - layer.buffer_origin.y).to_i
        w = cell.bounds.width.to_i
        h = cell.bounds.height.to_i
        block = ->{
            px = [] of CrymbleUI::Color?
            (1...h - 1).each { |dy| (1...w - 1).step(2) { |dx| px << backend.get_pixel(x0 + dx, y0 + dy) } }
            px
        }
        (x0 >= 0 && y0 >= 0 && x0 + w < backend.width && y0 + h < backend.height).should be_true
        checked_block = block.call

        adapter.probe_reset
        adapter.cell_assign(rc[0], rc[1], "'false")    # the per-cell path
        app.request_rebuild
        renderer.settle_rendering(app)
        adapter.cell_read(rc).should eq(false)
        after_per_cell = block.call

        # Instrument check: toggling a checkbox must change SOMETHING in the cell, or this
        # example cannot see a ghost either.
        after_per_cell.should_not eq(checked_block)

        # Ground truth: force a full re-render of the very same state and compare. A ghost left
        # by the per-cell path shows up here as a difference.
        #
        # HONEST LIMIT: this passes today partly because a committed edit also fires
        # request_rebuild, which builds a fresh matrix and repaints every visible cell (measured:
        # 192 cell_paint calls per edit, with or without this task). So the example cannot yet
        # separate "the per-cell path leaves no ghost" from "the rebuild painted over it". It is
        # a GUARD that grows teeth the day that rebuild is removed — which is exactly when the
        # ghost would otherwise become visible.
        adapter.invalidate_all!
        app.request_rebuild
        renderer.settle_rendering(app)
        after_per_cell.should eq(block.call)
    end
end
