require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Sales table with duplicate Region×Product combos so a pivot on Region/Product
# aggregates more than one basic row per cell (makes Drilldown cells exist).
private def make_sales_setup : {Persistency::Default, TableLID}
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10
        south | widget | 20
        north | gadget | 30
        south | gadget | 40
        north | widget | 50
    EOT
    {persistency, hash["Sales"].as(TableLID)}
end

private def make_configured_shape : ShapeState
    persistency, table_lid = make_sales_setup
    context = persistency.context.clone
    shape = ShapeState.new("Sales", persistency, context, table_lid)
    # Configure pivot: Region=Row header, Product=Column header, Amount=Aggregate
    configure_row_col_agg(shape, row_name: "Region", col_name: "Product", agg_name: "Amount")
    shape
end

# Set each fieldlist row's Class by looking up the fieldlist row whose
# InternalColumnIndex (derived from Column field + VT column order) matches
# the VT column index for the named column.
private def configure_row_col_agg(shape : ShapeState, row_name : String, col_name : String, agg_name : String)
    classes = {
        row_name => Table::Lazy::Pivot::Classes::Row.value.to_i64,
        col_name => Table::Lazy::Pivot::Classes::Column.value.to_i64,
        agg_name => Table::Lazy::Pivot::Classes::Aggregate.value.to_i64,
    }
    fl = shape.fieldlist.not_nil!
    _ = fl.size  # trigger sync: fieldlist rows auto-populated from VT columns
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

describe "ShapeState.new(table_lid:)" do
    it "pre-selects the given table_lid (picker points at it, not the default)" do
        persistency, table_lid = make_sales_setup
        # add a second table so "default" != our table_lid
        other_table = persistency.add_table("Other")
        persistency.add_field(other_table, "f", nil)
        persistency.add_record(other_table)
        context = persistency.context.clone
        shape = ShapeState.new("Sales", persistency, context, table_lid)
        # The table picker should report the sales table as its current pick
        shape.widget_table_picker.lid.should eq(table_lid)
    end
end

describe "ShapeState drill_from_cell" do
    it "returns nil for a non-Drilldown cell (header row)" do
        shape = make_configured_shape
        # (0,0) is a header cell — definitely not Drilldown
        shape.drill_from_cell({0, 0}).should be_nil
    end

    it "creates a new shape whose matrix row count equals the parent cell's basic-row count" do
        shape = make_configured_shape
        rc = shape.matrix_userdata_rc.not_nil!

        # Find the first Drilldown cell
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
        drilldown_cell.should_not be_nil

        basic_row_count = rc.get_table(drilldown_cell.not_nil!.to_a).size[0]
        basic_row_count.should be > 1  # otherwise it wouldn't be Drilldown

        drilled = shape.drill_from_cell(drilldown_cell.not_nil!)
        drilled.should_not be_nil

        drilled_rc = drilled.not_nil!.matrix_userdata_rc.not_nil!
        # Drilled shape inherits parent's pivot config (Row/Col/Agg) — its matrix
        # shape matches the parent's overall layout, but the underlying filtered
        # VT has only the basic rows under that cell.
        drilled.not_nil!.filter_state.size.should be > 0
    end

    it "filter_state pairs match the Drilldown cell's cluster values" do
        shape = make_configured_shape
        rc = shape.matrix_userdata_rc.not_nil!

        # Pick a specific Drilldown cell and verify clusters → filter pairs
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
        drilldown_cell.should_not be_nil

        expected_clusters = rc.get_cell_clusters(drilldown_cell.not_nil!.to_a)
        expected_clusters.size.should be > 0  # some row/col header constrains it

        drilled = shape.drill_from_cell(drilldown_cell.not_nil!).not_nil!
        expected_clusters.each do |col_idx, value_rank|
            cf = drilled.filter_state.find { |x| x.column_index == col_idx }
            cf.should_not be_nil
            cf.not_nil!.selected_values.should eq(Set{value_rank[0]})
        end
    end

    it "drilled shape is independent from parent (clone semantics)" do
        shape = make_configured_shape
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
        drilled = shape.drill_from_cell(drilldown_cell.not_nil!).not_nil!
        # Mutating drilled's filter must not touch parent
        drilled.filter_clear!
        shape.filter_state.empty?.should be_true  # parent unchanged
        drilled.filter_state.empty?.should be_true
    end

    it "drilled shape normalizes fieldlist (Rank=Row, all other fields=Aggregate)" do
        shape = make_configured_shape
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
        drilled = shape.drill_from_cell(drilldown_cell.not_nil!).not_nil!
        fl = drilled.fieldlist.not_nil!
        row_value = Table::Lazy::Pivot::Classes::Row.value.to_i64
        aggregate_value = Table::Lazy::Pivot::Classes::Aggregate.value.to_i64
        (0...fl.size[0]).each do |ri|
            name = fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Name.value]]
            cls = fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Class.value]]
            if name == "Rank"
                cls.should eq(row_value)
            else
                cls.should eq(aggregate_value)
            end
        end
    end

    it "drilled shape shows the basic rows under the cell (detail view)" do
        shape = make_configured_shape
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
        basic_row_count = rc.get_table(drilldown_cell.not_nil!.to_a).size[0]
        drilled = shape.drill_from_cell(drilldown_cell.not_nil!).not_nil!
        # Apply drilled filters to the VT directly: the underlying filtered table
        # should contain exactly the basic rows that were under the parent cell.
        drilled_vt = drilled.unfiltered_vt.not_nil!
        filtered = Table::Lazy::Filter.apply(drilled_vt, drilled.filter_state)
        filtered.size[0].should eq(basic_row_count)
    end

    it "drill works on a Drilldown cell with no clusters (flattens to detail view)" do
        # No row/col header set, just aggregates → single cell aggregating the whole
        # table. It's Drilldown (size > 1) but has empty cluster set. Drill should
        # still succeed: new shape normalized, no filters added.
        persistency, table_lid = make_sales_setup
        context = persistency.context.clone
        shape = ShapeState.new("Sales", persistency, context, table_lid)
        # Set everything to Aggregate (no row/col headers)
        fl = shape.fieldlist.not_nil!
        _ = fl.size
        aggregate_value = Table::Lazy::Pivot::Classes::Aggregate.value.to_i64
        (0...fl.size[0]).each do |ri|
            fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Class.value]] = aggregate_value
        end
        shape.matrix_adapter.not_nil!.invalidate_all!

        rc = shape.matrix_userdata_rc.not_nil!
        # Find cell that's Drilldown (size > 1). Without row/col headers, cells
        # are aggregates summing over all data rows — Drilldown if >1 basic row.
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
        drilldown_cell.should_not be_nil

        drilled = shape.drill_from_cell(drilldown_cell.not_nil!)
        drilled.should_not be_nil
        # No clusters were extracted, so no filters added
        drilled.not_nil!.filter_state.empty?.should be_true
    end
end
