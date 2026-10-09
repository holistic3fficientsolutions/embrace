require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"
require "./support/fixtures"

include Persistency

describe SimpleMatrixAdapter do
  describe "CrymbleUI MatrixAdapter conformance" do
    it "answers VirtualMatrix through the MatrixAdapter interface" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      # Typed as the interface: this compiles only if the adapter conforms.
      adapter : CrymbleUI::Widgets::VirtualMatrix::MatrixAdapter = shape.matrix_adapter.not_nil!
      adapter.get_scrollorder.should eq({[0, 1], [1, 2, 0]}) # the rank column is the sticky tail
      adapter.cell_read(0, 1).should eq "Arizona" # the (row, col) bridge VirtualMatrix polls
    end

    it "cell_paint shows every data cell's value" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      adapter = shape.matrix_adapter.not_nil!
      shown = [{0, 1}, {0, 2}, {1, 1}, {1, 2}].map do |(r, c)|
        adapter.cell_get_header_info({r, c}).should be_nil
        adapter.cell_paint(r, c).as(CrymbleUI::TextInput).value
      end
      shown.should eq ["Arizona", "USA", "Boston", "USA"]
    end

    it "cell_paint returns TextInput for data cells with correct value" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
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

    it "cell_paint shows a header cell's value (the rank)" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      adapter = shape.matrix_adapter.not_nil!
      adapter.cell_get_header_info({0, 0}).should_not be_nil # the rank column
      # Headers are rendered as TextInput with ruler_label color
      adapter.cell_paint(0, 0).as(CrymbleUI::TextInput).value.should eq "1"
      adapter.cell_paint(1, 0).as(CrymbleUI::TextInput).value.should eq "2"
    end

    it "cell_get_bounding_box returns cell itself (no merging for Milestone 1)" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      r, c = rows[0], cols[0]
      bb = adapter.cell_get_bounding_box(r, c)
      bb.should eq({ {r, c}, {r, c} })
    end

    it "bridge method cell_get_header_info(row, col) works" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      adapter = shape.matrix_adapter.not_nil!
      adapter.cell_get_header_info(0, 0).should_not be_nil # the rank column
      adapter.cell_get_header_info(0, 1).should be_nil     # City, a data cell
    end

    it "bridge method cell_has_content?(row, col) works" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      adapter = shape.matrix_adapter.not_nil!
      adapter.cell_has_content?(0, 1).should be_true # "Arizona"
    end

    it "bridge method cell_get_name(row, col) works" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      adapter = shape.matrix_adapter.not_nil!
      adapter.cell_get_name(0, 0).should eq "Rank"
      adapter.cell_get_name(0, 1).should eq "City"
    end

    it "bridge method cell_move(r1,c1,r2,c2) works" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
      adapter = shape.matrix_adapter.not_nil!
      rows, cols = adapter.get_scrollorder
      # A self-move (same source/dest) is a no-op and must return the SAME coordinates — asserting the
      # value catches a wrong-coord return that the old is_a?(Tuple) type-check (always true) could not.
      r, c = rows[0], cols[0]
      adapter.cell_move(r, c, r, c).should eq({r, c})
    end

    it "get_scrollorder returns headers at tail (sticky-compatible)" do
      persistency = Fixtures.cities_persons
      shape = ShapeState.new("Shape", persistency, persistency.context.clone)
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
