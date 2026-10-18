require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "./support/fixtures"

include Persistency

# v1 backgrounded a structurally EMPTY cell (a dead pivot intersection where no
# value can be assigned) with a dimmed grey, so the user could see where there is
# nothing; a live/assignable cell did not. The ImGui->CrymbleUI port (70be1d0)
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
    it "dims a dead (non-assignable) cell with cell.empty, and not a live one" do
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
                "live cell (#{lr},#{lc}) must not be lowlit"
        end
    end
end

# A live cell - one a value is in or can be typed into - reads in cell.live: a neutral grey (no hue - the
# Aggregates brown it had for a while was "ugly, never in v1"), a step apart from a dead cell's cell.empty (in the
# dark theme the plain input background, #2D2D2D, was only one step from cell.empty, #242424).
describe "live-cell colour" do
    {% for theme in ["dark", "light"] %}
        it "in the {{theme.id}} theme, a live cell (a text and a reference) is in cell.live, a neutral grey, a dead one is not" do
            CrymbleUI::Theme.set({{theme.id.symbolize}})
            shape = make_sparse_pivot_shape
            adapter = shape.matrix_adapter.not_nil!
            size = shape.matrix_userdata_rc.not_nil!.size
            live = [] of CrymbleUI::Color?
            dead = [] of CrymbleUI::Color?
            (0...size[0]).each do |r|
                (0...size[1]).each do |c|
                    next unless adapter.cell_get_header_info({r, c}).nil?
                    bg = adapter.cell_paint(r, c).as(CrymbleUI::TextInput).background_color
                    adapter.cell_has_content?(r, c) ? live << bg : dead << bg
                end
            end
            live.size.should be >= 2 # north x widget, south x gadget at least
            dead.size.should be >= 2 # north x gadget, south x widget
            live_color = CrymbleUI::Theme.current["cell.live"]
            live.uniq.should eq([live_color])
            dead.uniq.should eq([CrymbleUI::Theme.current["cell.empty"]])
            {live_color.g, live_color.b}.should eq({live_color.r, live_color.r}) # no hue
            (live_color.r.to_i - CrymbleUI::Theme.current["cell.empty"].r.to_i).abs.should be >= 16 # a step apart

            persons = Fixtures.persons_shape(Fixtures.cities_persons)
            pa = persons.matrix_adapter.not_nil!
            ref = (0...persons.matrix_userdata_rc.not_nil!.size[1]).map { |c| pa.cell_paint(0, c) }.find(&.is_a?(CrymbleUI::ComboBox))
            ref.should_not be_nil, "setup: a reference cell in Persons' first record"
            ref.not_nil!.as(CrymbleUI::ComboBox).background_color.should eq(live_color)
        ensure
            CrymbleUI::Theme.set(:light) # crymbleui's own default (theme.cr)
        end
    {% end %}
end
