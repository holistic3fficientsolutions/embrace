require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "./support/fixtures"

include Persistency

# v1 backgrounded a structurally EMPTY cell (a dead pivot intersection where no
# value can be assigned) with a dimmed grey, so the user could see where there is
# nothing; a live/assignable cell stayed flat. The ImGui->CrymbleUI port (70be1d0)
# dropped this — cell_paint only tinted headers/diff cells. This guards the
# restore: the lowlight is keyed on assignability, exactly like v1's matrix
# calc_color (cell_has_content == Directly || Drilldown).

# Sparse on purpose: north has only widget, south has only gadget, so pivoting
# Region x Product leaves north x gadget and south x widget as DEAD intersections.
private def make_sparse_pivot_shape : ShapeState
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10
        south | gadget | 40
    EOT
    table_lid = hash["Sales"].as(TableLID)
    context = persistency.context.clone
    shape = ShapeState.new("Sales", persistency, context, table_lid)
    Fixtures.pivot(shape, ["Region"], columns: ["Product"], aggregates: ["Amount"])
    shape
end

describe "empty-cell lowlight (v1 parity restore)" do
    it "dims a dead (non-assignable) cell with cell.empty, and leaves live cells flat" do
        shape = make_sparse_pivot_shape
        adapter = shape.matrix_adapter.not_nil!
        rc = shape.matrix_userdata_rc.not_nil!
        size = rc.size

        empty_color = CrymbleUI::Theme.current["cell.empty"]

        dead = nil
        live = nil
        (0...size[0]).each do |r|
            (0...size[1]).each do |c|
                next unless adapter.cell_get_header_info({r, c}).nil? # skip header cells
                if adapter.cell_has_content?(r, c)
                    live ||= {r, c}
                else
                    dead ||= {r, c}
                end
            end
        end

        dead.should_not be_nil, "setup: expected at least one dead (non-assignable) pivot cell"
        live.should_not be_nil, "setup: expected at least one live (assignable) cell"

        dr, dc = dead.not_nil!
        dead_widget = adapter.cell_paint(dr, dc)
        dead_widget.should be_a(CrymbleUI::TextInput)
        dead_widget.as(CrymbleUI::TextInput).background_color.should eq(empty_color),
            "dead cell (#{dr},#{dc}) should be lowlit with cell.empty"

        lr, lc = live.not_nil!
        live_widget = adapter.cell_paint(lr, lc)
        if live_widget.is_a?(CrymbleUI::TextInput)
            live_widget.background_color.should_not eq(empty_color),
                "live cell (#{lr},#{lc}) must stay flat, not lowlit"
        end
    end
end
