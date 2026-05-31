require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"

include Persistency

private def make_demo_persistency : Persistency::Default
  persistency = Persistency::Default.new
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Cities
      City | Country
      Arizona | USA
      Boston | USA
  EOT
  persistency
end

private def create_shape(persistency : Persistency::Default) : ShapeState
  context = persistency.context.clone
  ShapeState.new("Shape", persistency, context)
end

describe "VirtualMatrix integration with SimpleMatrixAdapter" do
  it "constructs VirtualMatrix from adapter without crash" do
    persistency = make_demo_persistency
    shape = create_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    matrix = CrymbleUI::VirtualMatrix.new(adapter: adapter, id: "test_matrix")
    matrix.rows.should be > 0
    matrix.cols.should be > 0
  end

  it "detects correct grid dimensions from adapter" do
    persistency = make_demo_persistency
    shape = create_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    rows_order, cols_order = adapter.get_scrollorder
    matrix = CrymbleUI::VirtualMatrix.new(adapter: adapter, id: "test_matrix")
    matrix.rows.should eq rows_order.size
    matrix.cols.should eq cols_order.size
  end

  it "has headers in scroll order (at tail for sticky)" do
    persistency = make_demo_persistency
    shape = create_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    rows_order, cols_order = adapter.get_scrollorder
    # Check that at least one header cell exists among the tail rows
    found_header = false
    rows_order.reverse_each do |r|
      cols_order.each do |c|
        if adapter.cell_get_header_info(r, c)
          found_header = true
          break
        end
      end
      break if found_header
    end
    found_header.should be_true
  end

  it "perspective column order stays stable after configurator field move" do
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Allocations
        Person  | Time    | Allocation
        Alan    | Present | 100
        Denny   | Present | 100
        Sauron  | Former  | 200
    EOT

    shape = create_shape(persistency)
    shape.update(true)

    # Get column names BEFORE the move
    adapter = shape.matrix_adapter.not_nil!
    persistency.contexts.push(shape.context)
    _, cols = adapter.get_scrollorder
    names_before = cols.map { |c| adapter.cell_get_name(0, c) }
    persistency.contexts.pop

    # Move Allocation before Time
    persistency.contexts.push(shape.context)
    table_lid = hash["Allocations"].as(TableLID)
    fields = persistency.get_field_lids(table_lid)
    persistency.move_field(table_lid, fields[-1], fields[-2])
    shape.context = persistency.contexts.pop
    shape.update(true)

    # Get column names AFTER the move
    adapter = shape.matrix_adapter.not_nil!
    persistency.contexts.push(shape.context)
    _, cols2 = adapter.get_scrollorder
    names_after = cols2.map { |c| adapter.cell_get_name(0, c) }
    persistency.contexts.pop

    # Column names must be IDENTICAL — field moves in configurator
    # must not change the perspective/fieldlist column order
    names_after.should eq(names_before)
  end
end
