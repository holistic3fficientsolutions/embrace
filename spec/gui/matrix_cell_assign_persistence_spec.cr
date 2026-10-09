require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"
require "./support/fixtures"

include Persistency

describe "SimpleMatrixAdapter cell_assign persistence" do
  it "cell_read returns new value after cell_assign" do
    persistency = Fixtures.cities_persons
    shape = ShapeState.new("Shape", persistency, persistency.context.clone)
    adapter = shape.matrix_adapter.not_nil!
    data_row, data_col = Fixtures.first_data_cell(adapter)

    adapter.cell_assign(data_row, data_col, "ZZZ")

    adapter.cell_read({data_row, data_col}).should eq("ZZZ")
  end

  it "cell_paint returns widget with new value after cell_assign" do
    persistency = Fixtures.cities_persons
    shape = ShapeState.new("Shape", persistency, persistency.context.clone)
    adapter = shape.matrix_adapter.not_nil!
    data_row, data_col = Fixtures.first_data_cell(adapter)

    adapter.cell_assign(data_row, data_col, "NEW")

    widget = adapter.cell_paint(data_row, data_col)
    widget.as(CrymbleUI::TextInput).value.should eq("NEW")
  end

  it "second shape sees value after first shape edits" do
    persistency = Fixtures.cities_persons
    shape1 = ShapeState.new("Shape", persistency, persistency.context.clone)
    shape2 = ShapeState.new("Shape", persistency, persistency.context.clone)

    adapter1 = shape1.matrix_adapter.not_nil!
    adapter2 = shape2.matrix_adapter.not_nil!
    data_row, data_col = Fixtures.first_data_cell(adapter1)

    # Shape1 edits
    adapter1.cell_assign(data_row, data_col, "CROSS")

    # Shape2 detects change and reads new value
    shape2.update
    adapter2.cell_read({data_row, data_col}).should eq("CROSS")
  end

  it "cell_paint returns ComboBox for ReferenceCell" do
    persistency = Fixtures.cities_persons
    shape = Fixtures.persons_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    data_row, data_col = Fixtures.first_reference_cell(adapter)
    widget = adapter.cell_paint(data_row, data_col)
    widget.should be_a(CrymbleUI::ComboBox)
  end

  it "cell_assign_reference changes ReferenceCell rank" do
    persistency = Fixtures.cities_persons
    shape = Fixtures.persons_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    data_row, data_col = Fixtures.first_reference_cell(adapter)
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
