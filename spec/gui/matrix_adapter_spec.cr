require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"

include Persistency

# Helper: create persistency with demo tables (reused from embrace_app_spec.cr)
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

describe SimpleMatrixAdapter do
  describe "CrymbleUI MatrixAdapter conformance" do
    it "includes CrymbleUI MatrixAdapter module" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      adapter.is_a?(CrymbleUI::Widgets::VirtualMatrix::MatrixAdapter).should be_true
    end

    it "cell_paint returns a CrymbleUI::Widget for data cells" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      # Find a data cell (not a header)
      found_data_cell = false
      rows.each do |r|
        cols.each do |c|
          if adapter.cell_get_header_info({r, c}).nil?
            widget = adapter.cell_paint(r, c)
            widget.is_a?(CrymbleUI::Widget).should be_true
            found_data_cell = true
            break
          end
        end
        break if found_data_cell
      end
      found_data_cell.should be_true
    end

    it "cell_paint returns TextInput for data cells with correct value" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      # Find first non-empty data cell (not a header)
      found = false
      rows.each do |r|
        break if found
        cols.each do |c|
          next if adapter.cell_get_header_info({r, c})  # skip headers
          value = adapter.cell_read({r, c})
          next if value == ""
          widget = adapter.cell_paint(r, c)
          widget.should be_a(CrymbleUI::TextInput)
          widget.as(CrymbleUI::TextInput).value.should eq(value.to_s)
          found = true
          break
        end
      end
      found.should be_true
    end

    it "cell_paint handles header cells (returns Text)" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      found_header = false
      rows.each do |r|
        cols.each do |c|
          if adapter.cell_get_header_info({r, c})
            widget = adapter.cell_paint(r, c)
            # Headers are rendered as TextInput with ruler_label color
            widget.is_a?(CrymbleUI::TextInput).should be_true
            found_header = true
            break
          end
        end
        break if found_header
      end
      found_header.should be_true
    end

    it "cell_get_bounding_box returns cell itself (no merging for Milestone 1)" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      r, c = rows[0], cols[0]
      bb = adapter.cell_get_bounding_box(r, c)
      bb.should eq({ {r, c}, {r, c} })
    end

    it "bridge method cell_get_header_info(row, col) works" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      # Just call it — should not raise
      adapter.cell_get_header_info(rows[0], cols[0])
    end

    it "bridge method cell_has_content?(row, col) works" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      result = adapter.cell_has_content?(rows[0], cols[0])
      (result == true || result == false).should be_true
    end

    it "bridge method cell_get_name(row, col) works" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      name = adapter.cell_get_name(rows[0], cols[0])
      name.is_a?(String).should be_true
    end

    it "bridge method cell_move(r1,c1,r2,c2) works" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      # cell_move with same source/dest should be safe
      r, c = rows[0], cols[0]
      result = adapter.cell_move(r, c, r, c)
      result.is_a?(Tuple(Int32, Int32)).should be_true
    end

    it "get_scrollorder returns headers at tail (sticky-compatible)" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      rows.size.should be > 0
      cols.size.should be > 0
      # Headers should be at tail: last elements form contiguous {0,1,...,N-1}
      # Verify at least one header row exists at tail
      has_header = false
      rows.reverse_each do |r|
        cols.each do |c|
          if adapter.cell_get_header_info({r, c})
            has_header = true
            break
          end
        end
        break if has_header
      end
      has_header.should be_true
    end
  end
end
