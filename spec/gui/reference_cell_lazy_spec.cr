require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# The reference-cell dropdown is LAZY. Painting a COLLAPSED reference cell shows only the
# referenced value (O(1)); it must NOT enumerate the referenced table — which, across a screenful of
# reference cells, was O(visible_cells * referenced_table_size) every rebuild. The item list, per-item
# constraint colours, selection, and per-item rank payloads are produced by the ComboBox's provider
# only on first expand; the picked item's rank rides reconcile so a pick still assigns correctly.

# Host the cell_paint'd ComboBox in a real window so expand mounts its popup and clicks land (mirrors
# the crymbleui lazy-combo harness). The combo's callbacks still close over the shape's adapter.
private class RefComboHost < CrymbleUI::App
  include CrymbleUI::DSL::BuilderMethods

  def initialize(@combo : CrymbleUI::ComboBox)
    super()
  end

  def build : CrymbleUI::Widget
    window("T", 400, 300) do
      vstack do
        widget(@combo)
      end
    end
  end
end

describe "reference cell lazy dropdown" do
  it "paints the collapsed reference cell WITHOUT enumerating the referenced table" do
    persistency = Fixtures.cities_persons
    shape = Fixtures.persons_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    r, c = Fixtures.first_reference_cell(adapter)
    adapter.cell_read({r, c}).is_a?(ReferenceCell).should be_true # precondition: this cell is a reference

    ReferenceCellStats.materialized = 0
    widget = adapter.cell_paint(r, c)
    ReferenceCellStats.materialized.should eq(0) # collapsed build is O(1): no dropdown enumeration

    combo = widget.as(CrymbleUI::ComboBox)
    combo.selected_value.should eq("Boston") # shows Alan's referenced city, straight from value.value
  end

  it "builds the dropdown only on expand (fulfilling then breaking) and a pick reassigns the reference" do
    persistency = Fixtures.cities_persons
    shape = Fixtures.persons_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    r, c = Fixtures.first_reference_cell(adapter)

    combo = adapter.cell_paint(r, c).as(CrymbleUI::ComboBox)
    app = RefComboHost.new(combo)
    app.build_tree
    renderer = CrymbleUI::Testing::TestRenderer.new(400, 300)
    renderer.settle_rendering(app)

    ReferenceCellStats.materialized = 0
    Fixtures.click_on(app, combo) # expand
    renderer.settle_rendering(app)
    ReferenceCellStats.materialized.should be > 0 # expand DID enumerate the referenced table
    combo.items.should contain("Arizona")         # a selectable city is in the built list

    target = combo.items.index("Arizona").not_nil!
    popup = combo.current_popup.not_nil!
    Fixtures.click_on(app, popup.item_widgets[target]) # user picks Arizona
    renderer.settle_rendering(app)

    # The reference now points to Arizona — the picked item's RANK (payload) flowed through, not its
    # list index, so cell_assign_reference reassigned to the correct record.
    adapter.cell_read({r, c}).as(ReferenceCell).value.to_s.should eq("Arizona")
  end
end
