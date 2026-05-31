require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"

include Persistency

# Helper: create persistency with demo tables (reused from matrix_adapter_spec.cr)
private def make_demo_persistency : Persistency::Default
  persistency = Persistency::Default.new
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Cities
      City | Country
      Arizona | USA
      Boston | USA

      Persons
      Person | City_City
      Alan | Boston
  EOT
  persistency
end

private def create_shape(persistency : Persistency::Default) : ShapeState
  context = persistency.context.clone
  ShapeState.new("Shape", persistency, context)
end

# Create shape selecting Persons table (has City_City ReferenceCell)
private def create_shape_for_persons(persistency : Persistency::Default) : ShapeState
  context = persistency.context.clone
  shape = ShapeState.new("Shape", persistency, context)
  shape.widget_table_picker.select_index(1)  # "Persons" (alphabetically after "Cities")
  shape.update(true)
  shape
end

# Find first writable String data cell (non-header, non-empty, non-ReferenceCell)
private def find_string_data_cell(adapter, rows, cols) : Tuple(Int32, Int32)
  rows.each do |r|
    cols.each do |c|
      next if adapter.cell_get_header_info({r, c}) # skip headers
      value = adapter.cell_read({r, c})
      next if value == "" || value.is_a?(ReferenceCell)
      return {r, c}
    end
  end
  raise "No string data cell found"
end

# Find first ReferenceCell data cell
private def find_reference_data_cell(adapter, rows, cols) : Tuple(Int32, Int32)
  rows.each do |r|
    cols.each do |c|
      next if adapter.cell_get_header_info({r, c})
      value = adapter.cell_read({r, c})
      return {r, c} if value.is_a?(ReferenceCell)
    end
  end
  raise "No reference data cell found"
end

describe "SimpleMatrixAdapter cell_assign persistence" do
  it "cell_read returns new value after cell_assign" do
    persistency = make_demo_persistency
    shape = create_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder

    data_row, data_col = find_string_data_cell(adapter, rows, cols)

    adapter.cell_assign(data_row, data_col, "ZZZ")

    adapter.cell_read({data_row, data_col}).should eq("ZZZ")
  end

  it "cell_paint returns widget with new value after cell_assign" do
    persistency = make_demo_persistency
    shape = create_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder

    data_row, data_col = find_string_data_cell(adapter, rows, cols)

    adapter.cell_assign(data_row, data_col, "NEW")

    widget = adapter.cell_paint(data_row, data_col)
    widget.as(CrymbleUI::TextInput).value.should eq("NEW")
  end

  it "second shape sees value after first shape edits" do
    persistency = make_demo_persistency
    shape1 = create_shape(persistency)
    shape2 = create_shape(persistency)

    adapter1 = shape1.matrix_adapter.not_nil!
    adapter2 = shape2.matrix_adapter.not_nil!
    rows, cols = adapter1.get_scrollorder

    data_row, data_col = find_string_data_cell(adapter1, rows, cols)

    # Shape1 edits
    adapter1.cell_assign(data_row, data_col, "CROSS")

    # Shape2 detects change and reads new value
    shape2.update
    adapter2.cell_read({data_row, data_col}).should eq("CROSS")
  end

  it "cell_paint returns ComboBox for ReferenceCell" do
    persistency = make_demo_persistency
    shape = create_shape_for_persons(persistency)
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder

    data_row, data_col = find_reference_data_cell(adapter, rows, cols)
    widget = adapter.cell_paint(data_row, data_col)
    widget.should be_a(CrymbleUI::ComboBox)
  end

  it "cell_assign_reference changes ReferenceCell rank" do
    persistency = make_demo_persistency
    shape = create_shape_for_persons(persistency)
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder

    data_row, data_col = find_reference_data_cell(adapter, rows, cols)
    original = adapter.cell_read({data_row, data_col}).as(ReferenceCell)
    original_rank = original.rank

    # Pick a different rank from valid options
    new_rank = -1
    original.each_defined_fulfilling do |rc|
      if rc.rank != original_rank
        new_rank = rc.rank
        break
      end
    end
    next if new_rank == -1 # skip if only one option

    adapter.cell_assign_reference(data_row, data_col, new_rank)
    updated = adapter.cell_read({data_row, data_col}).as(ReferenceCell)
    updated.rank.should eq(new_rank)
  end
end
