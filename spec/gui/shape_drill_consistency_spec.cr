require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Sales table with duplicate Region×Product combos so a pivot on Region×Product
# aggregates more than one basic row per cell (Drilldown cells exist).
# Rows: 5 total. {north,widget}=2, {south,widget}=1, {north,gadget}=1, {south,gadget}=1.
alias LidHash = Hash(String, FieldLID | TableLID | RecordLID)

private def make_sales_setup : {Persistency::Default, TableLID, LidHash}
    # Enough data that MULTIPLE Region×Product combos have >1 rows (for
    # independence tests on two drill cells). 8 rows total.
    persistency = Persistency::Default.new
    hash = LidHash.new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10
        south | widget | 20
        north | gadget | 30
        south | gadget | 40
        north | widget | 50
        south | widget | 60
        north | gadget | 70
        south | gadget | 80
    EOT
    {persistency, hash["Sales"].as(TableLID), hash}
end

private def make_configured_shape : {ShapeState, LidHash}
    persistency, table_lid, hash = make_sales_setup
    context = persistency.context.clone
    shape = ShapeState.new("Sales", persistency, context, table_lid)
    configure_row_col_agg(shape, row_name: "Region", col_name: "Product", agg_name: "Amount")
    {shape, hash}
end

private def configure_row_col_agg(shape : ShapeState, row_name : String, col_name : String, agg_name : String)
    classes = {
        row_name => Table::Lazy::Pivot::Classes::Row.value.to_i64,
        col_name => Table::Lazy::Pivot::Classes::Column.value.to_i64,
        agg_name => Table::Lazy::Pivot::Classes::Aggregate.value.to_i64,
    }
    fl = shape.fieldlist.not_nil!
    _ = fl.size
    unused_value = Table::Lazy::Pivot::Classes::Unused.value.to_i64
    (0...fl.size[0]).each do |ri|
        fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Class.value]] = unused_value
    end
    classes.each do |name, class_value|
        fl_row = (0...fl.size[0]).find do |ri|
            fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Name.value]] == name
        end.not_nil!
        fl[[fl_row, Table::Lazy::Fieldlist::ColumnIndices::Class.value]] = class_value
    end
    shape.matrix_adapter.not_nil!.invalidate_all!
end

# Count rows in the drilled shape's underlying filtered VT (not the pivot — we
# want basic-row count, which is what the user sees in the drill "detail view").
private def drilled_vt_row_count(shape : ShapeState) : Int32
    vt = shape.unfiltered_vt.not_nil!
    Table::Lazy::Filter.apply(vt, shape.filter_state).size[0]
end

# Drill into the first Drilldown cell of a configured shape.
private def drill(primary : ShapeState) : ShapeState
    rc = primary.matrix_userdata_rc.not_nil!
    size = rc.size
    drilldown_cell = nil
    size[0].times do |r|
        size[1].times do |c|
            if rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Drilldown
                drilldown_cell = {r, c}
                break
            end
        end
        break if drilldown_cell
    end
    primary.drill_from_cell(drilldown_cell.not_nil!).not_nil!
end

# Given a drilled Shape and a LidHash (with Region/Product/Amount FieldLIDs),
# infer which filter value is on Region and which is on Product by probing
# against the set of known-possible values {north, south, widget, gadget}.
private def drilled_filters(drilled : ShapeState, hash : LidHash) : {String, String}
    # The filter_state's column_index is a VT column index, not a persistency
    # FieldLID. Disambiguate purely by the value's domain.
    region_val : String = ""
    product_val : String = ""
    drilled.filter_state.each do |cf|
        v = cf.selected_values.first.to_s
        case v
        when "north", "south" then region_val = v
        when "widget", "gadget" then product_val = v
        end
    end
    {region_val, product_val}
end

# ==========================================================================
# Consistency tests: drill-down Shape should react properly to data changes
# from either side (primary or drill), and edits inside the drill shouldn't
# trigger invariant violations.
# ==========================================================================

describe "Drill-down Shape consistency" do
    # --- (a) Primary-side changes reflected in the drill ---

    it "primary adds a record matching the drill's filter → drill includes it" do
        primary, hash = make_configured_shape
        drilled = drill(primary)
        rows_before = drilled_vt_row_count(drilled)
        region_val, product_val = drilled_filters(drilled, hash)
        region_val.should_not be_empty
        product_val.should_not be_empty

        persistency = primary.persistency
        table_lid = hash["Sales"].as(TableLID)
        persistency.contexts.push(primary.context)
        new_rec = persistency.add_record(table_lid)
        persistency.set_value(hash["Region"].as(FieldLID), new_rec, region_val)
        persistency.set_value(hash["Product"].as(FieldLID), new_rec, product_val)
        persistency.contexts.pop
        primary.matrix_adapter.not_nil!.invalidate_all!
        drilled.matrix_adapter.not_nil!.invalidate_all!

        rows_after = drilled_vt_row_count(drilled)
        rows_after.should eq(rows_before + 1)
    end

    it "primary adds a record NOT matching the drill's filter → drill unchanged" do
        primary, hash = make_configured_shape
        drilled = drill(primary)
        rows_before = drilled_vt_row_count(drilled)

        persistency = primary.persistency
        table_lid = hash["Sales"].as(TableLID)
        persistency.contexts.push(primary.context)
        new_rec = persistency.add_record(table_lid)
        persistency.set_value(hash["Region"].as(FieldLID), new_rec, "NEVERMATCH")
        persistency.set_value(hash["Product"].as(FieldLID), new_rec, "NEVERMATCH")
        persistency.contexts.pop
        drilled.matrix_adapter.not_nil!.invalidate_all!

        rows_after = drilled_vt_row_count(drilled)
        rows_after.should eq(rows_before)
    end

    it "primary edits a cell to match the filter → drill gains it" do
        primary, hash = make_configured_shape
        drilled = drill(primary)
        rows_before = drilled_vt_row_count(drilled)
        region_val, product_val = drilled_filters(drilled, hash)

        persistency = primary.persistency
        table_lid = hash["Sales"].as(TableLID)
        region_fl = hash["Region"].as(FieldLID)
        product_fl = hash["Product"].as(FieldLID)
        persistency.contexts.push(primary.context)
        records = persistency.get_ancestors(persistency.get_value(MetaFieldLIDs::TableLastRecord, table_lid).as(FieldLID))
        chosen = records.find { |rec|
            persistency.get_value(product_fl, rec) == product_val && persistency.get_value(region_fl, rec) != region_val
        }
        chosen.should_not be_nil
        persistency.set_value(region_fl, chosen.not_nil!, region_val)
        persistency.contexts.pop
        drilled.matrix_adapter.not_nil!.invalidate_all!

        rows_after = drilled_vt_row_count(drilled)
        rows_after.should eq(rows_before + 1)
    end

    it "primary edits a cell out of the filter → drill loses it" do
        primary, hash = make_configured_shape
        drilled = drill(primary)
        rows_before = drilled_vt_row_count(drilled)
        region_val, product_val = drilled_filters(drilled, hash)

        persistency = primary.persistency
        table_lid = hash["Sales"].as(TableLID)
        region_fl = hash["Region"].as(FieldLID)
        product_fl = hash["Product"].as(FieldLID)
        persistency.contexts.push(primary.context)
        records = persistency.get_ancestors(persistency.get_value(MetaFieldLIDs::TableLastRecord, table_lid).as(FieldLID))
        victim = records.find { |rec|
            persistency.get_value(region_fl, rec) == region_val && persistency.get_value(product_fl, rec) == product_val
        }
        victim.should_not be_nil
        persistency.set_value(region_fl, victim.not_nil!, "elsewhere")
        persistency.contexts.pop
        drilled.matrix_adapter.not_nil!.invalidate_all!

        rows_after = drilled_vt_row_count(drilled)
        rows_after.should eq(rows_before - 1)
    end

    # --- (b) Editing cells IN the drilled shape ---

    it "edit a non-filter cell in drilled shape → no invariant violation" do
        primary, _hash = make_configured_shape
        drilled = drill(primary)
        adapter = drilled.matrix_adapter.not_nil!
        rc = drilled.matrix_userdata_rc.not_nil!
        target : {Int32, Int32}? = nil
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                next unless rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Directly
                next if rc.get_header_info([r, c])
                target = {r, c}
                break
            end
            break if target
        end
        target.should_not be_nil
        begin
            adapter.cell_assign(target.not_nil!, 9999i64)
        rescue ex
            fail "edit in drilled raised: #{ex.class} #{ex.message}\n#{ex.backtrace?.try(&.first(8).join("\n")) || "(no backtrace)"}"
        end
    end

    it "edit a Region cell in drilled shape (filter column) → no invariant violation; row leaves drill" do
        primary, hash = make_configured_shape
        drilled = drill(primary)
        adapter = drilled.matrix_adapter.not_nil!
        rows_before = drilled_vt_row_count(drilled)

        rc = drilled.matrix_userdata_rc.not_nil!
        target : {Int32, Int32}? = nil
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                next unless rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Directly
                next if rc.get_header_info([r, c])
                name = rc.hyperplane_get_name(1, [r, c])
                if name == "Region"
                    target = {r, c}
                    break
                end
            end
            break if target
        end
        pending("couldn't locate a Region cell in drilled matrix") unless target
        begin
            adapter.cell_assign(target.not_nil!, "elsewhere")
        rescue ex
            fail "edit of Region cell in drilled raised: #{ex.class} #{ex.message}"
        end
        drilled.matrix_adapter.not_nil!.invalidate_all!
        rows_after = drilled_vt_row_count(drilled)
        rows_after.should eq(rows_before - 1)
    end

    # --- (c) Adding records IN the drilled shape ---

    it "adding a record in drilled shape auto-populates filter values" do
        # Measure the LIVE @matrix_userdata_rc (not a freshly-built Filter.apply),
        # and route via adapter.cell_insert (the GUI path). This exercises what
        # the user actually sees when they press "Add record" in the drilled
        # Shape panel.
        primary, hash = make_configured_shape
        drilled = drill(primary)
        live_rc = drilled.matrix_userdata_rc.not_nil!
        size_before = live_rc.size[0]

        adapter = drilled.matrix_adapter.not_nil!
        begin
            adapter.cell_insert({0, 0})
        rescue ex
            fail "cell_insert in drilled raised: #{ex.class} #{ex.message}\n#{ex.backtrace?.try(&.join("\n")) || "(no backtrace)"}"
        end

        size_after = live_rc.size[0]
        size_after.should be > size_before,
            "new record added in drilled shape should land in the filter's visible set — live pivot size: before=#{size_before} after=#{size_after}"

        # Verify the filter-column values were actually written in persistency.
        # Find the newly-added record by set-diff against the ancestors snapshot.
        region_val, product_val = drilled_filters(drilled, hash)
        persistency = primary.persistency
        table_lid = hash["Sales"].as(TableLID)
        persistency.contexts.push(primary.context)
        records_after = persistency.get_ancestors(persistency.get_value(MetaFieldLIDs::TableLastRecord, table_lid).as(FieldLID))
        # The new record has matching Region and Product (if filters worked).
        new_rec = records_after.find do |rec|
            persistency.get_value(hash["Region"].as(FieldLID), rec) == region_val &&
            persistency.get_value(hash["Product"].as(FieldLID), rec) == product_val &&
            persistency.get_value(hash["Amount"].as(FieldLID), rec).nil?
        end
        new_rec.should_not be_nil,
            "couldn't find a record matching filter values with no Amount (should be the newly-added one)"
        persistency.contexts.pop
    end

    it "Insert at a reference cell in drilled shape works (Allocations-style demo)" do
        # Mirrors the user's GUI scenario: Allocations pivoted by Project,
        # drill into a Project=Arts cell, place cursor on a reference cell
        # (Person_Person or Project_Project), press Insert.
        persistency = Persistency::Default.new
        hash = LidHash.new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Projects
            Project
            Arts
            Law
            Peace

            Persons
            Person
            Alice
            Bob
            Carol

            Allocations
            Person_Person | Project_Project | Allocation
            Alice | Arts | 100
            Bob   | Arts | 200
            Carol | Law  | 300
            Alice | Law  | 400
            Alice | Arts | 150
            Bob   | Arts | 250
        EOT
        table_lid = hash["Allocations"].as(TableLID)
        context = persistency.context.clone
        shape = ShapeState.new("Allocations", persistency, context, table_lid)
        configure_row_col_agg(shape, row_name: "Project", col_name: "Person", agg_name: "Allocation")
        rc = shape.matrix_userdata_rc.not_nil!

        drilldown_cell = nil
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                if rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Drilldown
                    drilldown_cell = {r, c}
                    break
                end
            end
            break if drilldown_cell
        end
        # If no Drilldown cell (shouldn't happen with Arts × Alice=2 rows), bail.
        drilldown_cell.should_not be_nil

        drilled = shape.drill_from_cell(drilldown_cell.not_nil!).not_nil!
        drc = drilled.matrix_userdata_rc.not_nil!
        size_before = drc.size[0]

        # Find a Directly-assignable, non-header cell in the drilled view
        target : {Int32, Int32}? = nil
        dsize = drc.size
        dsize[0].times do |r|
            dsize[1].times do |c|
                next unless drc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Directly
                next if drc.get_header_info([r, c])
                target = {r, c}
                break
            end
            break if target
        end
        target.should_not be_nil

        adapter = drilled.matrix_adapter.not_nil!
        begin
            adapter.cell_insert(target.not_nil!)
        rescue ex
            fail "cell_insert at ref cell in drilled raised: #{ex.class} #{ex.message}\n#{ex.backtrace?.try(&.first(15).join("\n")) || "(no backtrace)"}"
        end

        size_after = drc.size[0]
        size_after.should be > size_before,
            "Insert should grow drilled view; before=#{size_before} after=#{size_after}"
    end

    it "Insert on a USER-FILTERED shape (not drilled, no fieldlist normalize) works" do
        # User-set filter via filter_add (not through drill_from_cell).
        # Fieldlist keeps its pivot configuration; only the filter narrows rows.
        # Press Insert — must not produce invariant violations.
        primary, hash = make_configured_shape  # Region=Row, Product=Col, Amount=Aggregate
        # Add a filter manually (mimicking Filter UI: user checks Region=north)
        region_col_idx = 1  # heuristic; adjust if make_configured_shape schema changes
        primary.filter_add(region_col_idx, Set{"north".as(Cell)})
        adapter = primary.matrix_adapter.not_nil!
        rc = primary.matrix_userdata_rc.not_nil!
        size_before = rc.size[0]

        # Any assignable, non-header cell (may include Directly headers)
        target : {Int32, Int32}? = nil
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                assign = rc.get_assignability([r, c])
                next if assign.nil?
                next if assign == Table::Lazy::Pivot::Assignability::Not
                target = {r, c}
                break
            end
            break if target
        end
        target.should_not be_nil

        begin
            adapter.cell_insert(target.not_nil!)
        rescue ex
            fail "cell_insert on user-filtered shape raised: #{ex.class} #{ex.message}\n#{ex.backtrace?.try(&.first(15).join("\n")) || "(no backtrace)"}"
        end

        size_after = rc.size[0]
        size_after.should be >= size_before,
            "Insert on user-filtered shape should not shrink; before=#{size_before} after=#{size_after}"
    end

    it "Insert at a Directly-assignable data cell in drilled shape works" do
        # Matches the user's GUI path: cursor on a data row's Region/Product/Amount cell,
        # press Insert. This goes through the Hierarchic.hyperplane_add `Directly` branch
        # (clone the row), not the `Indirectly` one (c1 tested with {0, 0}).
        primary, _hash = make_configured_shape
        drilled = drill(primary)
        adapter = drilled.matrix_adapter.not_nil!
        rc = drilled.matrix_userdata_rc.not_nil!
        size_before = rc.size[0]

        # Find a Directly-assignable, non-header cell (a cell in a data row)
        target : {Int32, Int32}? = nil
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                next unless rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Directly
                next if rc.get_header_info([r, c])
                target = {r, c}
                break
            end
            break if target
        end
        target.should_not be_nil

        begin
            adapter.cell_insert(target.not_nil!)
        rescue ex
            fail "cell_insert at Directly cell in drilled raised: #{ex.class} #{ex.message}\n#{ex.backtrace?.try(&.first(12).join("\n")) || "(no backtrace)"}"
        end

        size_after = rc.size[0]
        size_after.should be > size_before,
            "Insert at Directly cell should grow the drilled view (cloned row lands in filter): before=#{size_before} after=#{size_after}"
    end

    # --- (d) Drill independence ---

    it "two drills on different cells of the same primary are independent" do
        primary, _hash = make_configured_shape
        rc = primary.matrix_userdata_rc.not_nil!
        dcells = [] of {Int32, Int32}
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                if rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Drilldown
                    dcells << {r, c}
                    break if dcells.size == 2
                end
            end
            break if dcells.size == 2
        end
        dcells.size.should eq(2)
        d1 = primary.drill_from_cell(dcells[0]).not_nil!
        d2 = primary.drill_from_cell(dcells[1]).not_nil!
        d1.filter_state.should_not eq(d2.filter_state)
        d1.filter_clear!
        d2.filter_state.empty?.should be_false
    end

    # --- (e) Deletions ---

    # --- (f) User-facing string path: matches the GUI's SimpleMatrixAdapter.cell_assign signature ---

    it "(f1) user-facing string cell_assign in drilled shape on non-filter cell works" do
        primary, _hash = make_configured_shape
        drilled = drill(primary)
        adapter = drilled.matrix_adapter.not_nil!
        rc = drilled.matrix_userdata_rc.not_nil!
        # Find a non-header Amount cell (aggregate column)
        target : {Int32, Int32}? = nil
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                next unless rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Directly
                next if rc.get_header_info([r, c])
                name = rc.hyperplane_get_name(1, [r, c])
                if name == "Amount"
                    target = {r, c}
                    break
                end
            end
            break if target
        end
        target.should_not be_nil
        begin
            adapter.cell_assign(target.not_nil![0], target.not_nil![1], "1234")
        rescue ex
            fail "GUI-path cell_assign in drilled raised: #{ex.class} #{ex.message}"
        end
    end

    it "(f2) user-facing string cell_assign in drilled shape on Region cell works" do
        primary, _hash = make_configured_shape
        drilled = drill(primary)
        adapter = drilled.matrix_adapter.not_nil!
        rc = drilled.matrix_userdata_rc.not_nil!
        target : {Int32, Int32}? = nil
        size = rc.size
        size[0].times do |r|
            size[1].times do |c|
                next unless rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Directly
                next if rc.get_header_info([r, c])
                name = rc.hyperplane_get_name(1, [r, c])
                if name == "Region"
                    target = {r, c}
                    break
                end
            end
            break if target
        end
        target.should_not be_nil
        begin
            adapter.cell_assign(target.not_nil![0], target.not_nil![1], "elsewhere")
        rescue ex
            fail "GUI-path cell_assign on filter-column in drilled raised: #{ex.class} #{ex.message}"
        end
    end

    # --- (g) LIVE reactivity: drilled shape's cached pivot must react ---

    it "(g0) drilled shape's LIVE pivot picks up records added in primary without invalidate" do
        # This is the user-facing bug: after primary adds a matching record,
        # the drilled Shape's UI still shows stale data. The fixture for the add-matching case
        # used a fresh `Filter.apply(vt, state)` which bypasses the live cache;
        # this test measures the LIVE @matrix_userdata_rc instead.
        primary, hash = make_configured_shape
        drilled = drill(primary)
        live_rc = drilled.matrix_userdata_rc.not_nil!
        size_before = live_rc.size[0]

        # Find filter values and add a matching record in primary
        region_val, product_val = drilled_filters(drilled, hash)
        persistency = primary.persistency
        table_lid = hash["Sales"].as(TableLID)
        persistency.contexts.push(primary.context)
        new_rec = persistency.add_record(table_lid)
        persistency.set_value(hash["Region"].as(FieldLID), new_rec, region_val)
        persistency.set_value(hash["Product"].as(FieldLID), new_rec, product_val)
        persistency.contexts.pop

        # Do NOT call invalidate_all! — we want to prove the cache recomputes.
        size_after = live_rc.size[0]
        size_after.should be > size_before,
            "drilled pivot size did not grow after primary added a matching record — filter chain is stale"
    end

    it "(g1) drilled shape version bumps when primary edits a cell" do
        primary, hash = make_configured_shape
        drilled = drill(primary)
        drc = drilled.matrix_userdata_rc.not_nil!
        v_before = drc.version

        # Edit in primary via persistency directly (no adapter invalidation call)
        primary.persistency.contexts.push(primary.context)
        region_fl = hash["Region"].as(FieldLID)
        table_lid = hash["Sales"].as(TableLID)
        records = primary.persistency.get_ancestors(primary.persistency.get_value(MetaFieldLIDs::TableLastRecord, table_lid).as(FieldLID))
        primary.persistency.set_value(region_fl, records.first, "edited")
        primary.persistency.contexts.pop

        v_after = drc.version
        v_after.should_not eq(v_before),
            "drilled pivot version should bump after primary's cell edit (reactivity without explicit invalidate_all!)"
    end

    # --- (h) Cascading: drill of a drill ---

    it "(h1) drilling into a drilled shape narrows further" do
        primary, _hash = make_configured_shape
        d1 = drill(primary)
        d1.filter_state.size.should be >= 1
        rows_d1 = drilled_vt_row_count(d1)

        # Drill into a cell of d1 if any Drilldown cells remain
        rc1 = d1.matrix_userdata_rc.not_nil!
        dcell = nil
        size = rc1.size
        size[0].times do |r|
            size[1].times do |c|
                if rc1.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Drilldown
                    dcell = {r, c}
                    break
                end
            end
            break if dcell
        end
        if dcell
            d2 = d1.drill_from_cell(dcell).not_nil!
            d2.filter_state.size.should be >= d1.filter_state.size
            rows_d2 = drilled_vt_row_count(d2)
            rows_d2.should be <= rows_d1
        end
    end

    it "(e1) primary deletes a record that's in the drill → drill loses it" do
        primary, hash = make_configured_shape
        drilled = drill(primary)
        rows_before = drilled_vt_row_count(drilled)
        rows_before.should be > 0
        region_val, product_val = drilled_filters(drilled, hash)

        persistency = primary.persistency
        table_lid = hash["Sales"].as(TableLID)
        region_fl = hash["Region"].as(FieldLID)
        product_fl = hash["Product"].as(FieldLID)
        persistency.contexts.push(primary.context)
        records = persistency.get_ancestors(persistency.get_value(MetaFieldLIDs::TableLastRecord, table_lid).as(FieldLID))
        victim = records.find { |rec|
            persistency.get_value(region_fl, rec) == region_val && persistency.get_value(product_fl, rec) == product_val
        }.not_nil!
        persistency.remove_record(table_lid, victim)
        persistency.contexts.pop
        drilled.matrix_adapter.not_nil!.invalidate_all!

        rows_after = drilled_vt_row_count(drilled)
        rows_after.should eq(rows_before - 1)
    end
end
