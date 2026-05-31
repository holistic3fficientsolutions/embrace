require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Layer 3a: headless GUI specs for the Filter section in a Shape panel.
# Uses crymble-ui's TestRenderer — no SFML, no X11.

private def make_sales_app : EmbraceApp
    # EmbraceApp's initialize does do_newfile_empty_impl + shape_add, so we
    # start with an empty table. Then we replace its persistency contents.
    app = EmbraceApp.new
    persistency = app.persistency
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
    # Re-create the shape so it picks up the new table; pre-select the Sales table
    sales_lid = hash["Sales"].as(TableLID)
    app.shapes.clear
    ctx = persistency.context.clone
    app.shapes << ShapeState.new("Sales", persistency, ctx, sales_lid)
    app.request_rebuild
    app
end

describe "Filter UI section" do
    it "renders a tree_node titled 'Filter'" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        node = app.find("filter_#{shape.id}")
        node.should_not be_nil
    end

    it "shows the empty state when no filters are active" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        # Search the whole tree for a Text widget with the empty-state copy
        empty_widgets = app.find_all { |w| w.is_a?(CrymbleUI::Text) && w.as(CrymbleUI::Text).text.includes?("no filters") }
        empty_widgets.size.should be > 0
    end

    it "after filter_add the empty-state text disappears and a filter row exists" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        # Sanity: column_names should contain Region after rendering settles
        shape.column_names.should contain("Region")
        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set{"north".as(Cell)})
        app.request_rebuild
        renderer.settle_rendering(app)

        empty_widgets = app.find_all { |w| w.is_a?(CrymbleUI::Text) && w.as(CrymbleUI::Text).text.includes?("no filters") }
        empty_widgets.size.should eq(0)

        filter_row = app.find("filter_row_#{region_idx}_#{shape.id}")
        filter_row.should_not be_nil

        # ✕ remove button is also present
        remove_btn = app.find("filter_remove_#{region_idx}_#{shape.id}")
        remove_btn.should_not be_nil
    end

    it "Clear all button only renders when at least one filter is active" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first

        app.find("filter_clear_#{shape.id}").should be_nil

        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set{"north".as(Cell)})
        app.request_rebuild
        renderer.settle_rendering(app)

        app.find("filter_clear_#{shape.id}").should_not be_nil
    end

    # --- tristate "all" + text search ---

    it "tristate 'all' checkbox exists in each active filter row" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set{"north".as(Cell)})
        app.request_rebuild
        renderer.settle_rendering(app)

        tri = app.find("filter_all_#{region_idx}_#{shape.id}")
        tri.should_not be_nil
    end

    it "tristate toggles between all-selected and none-selected on click" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set{"north".as(Cell), "south".as(Cell)})
        app.request_rebuild
        renderer.settle_rendering(app)

        tri = app.find("filter_all_#{region_idx}_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Checked)

        # Partially select (only "north") → should become Indeterminate on next render
        shape.filter_set_values(region_idx, Set{"north".as(Cell)})
        app.request_rebuild
        renderer.settle_rendering(app)
        tri = app.find("filter_all_#{region_idx}_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Indeterminate)

        # None
        shape.filter_set_values(region_idx, Set(Cell).new)
        app.request_rebuild
        renderer.settle_rendering(app)
        tri = app.find("filter_all_#{region_idx}_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Unchecked)
    end

    it "text search input renders with placeholder 'search…'" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set(Cell).new)
        app.request_rebuild
        renderer.settle_rendering(app)

        search = app.find("filter_search_#{region_idx}_#{shape.id}")
        search.should_not be_nil
        search.not_nil!.as(CrymbleUI::TextInput).placeholder.should eq("search…")
    end

    it "text search narrows the visible value checkboxes" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set(Cell).new)
        app.request_rebuild
        renderer.settle_rendering(app)

        # Without search: both "north" and "south" value-checkboxes exist
        app.find("filter_value_#{region_idx}_#{"north".hash}_#{shape.id}").should_not be_nil
        app.find("filter_value_#{region_idx}_#{"south".hash}_#{shape.id}").should_not be_nil

        # Set search to "nor" → only "north" should remain
        app.commit_filter_search({shape.id, region_idx}, "nor")
        app.request_rebuild
        renderer.settle_rendering(app)

        app.find("filter_value_#{region_idx}_#{"north".hash}_#{shape.id}").should_not be_nil
        app.find("filter_value_#{region_idx}_#{"south".hash}_#{shape.id}").should be_nil
    end

    it "tristate 'all' with active search operates only on visible values" do
        app = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set(Cell).new)
        app.request_rebuild
        renderer.settle_rendering(app)

        # Narrow to "nor" — only "north" visible
        app.commit_filter_search({shape.id, region_idx}, "nor")
        app.request_rebuild
        renderer.settle_rendering(app)

        # Trigger the tristate's click callback directly: expect "north" added,
        # "south" untouched.
        tri = app.find("filter_all_#{region_idx}_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.trigger_click
        app.request_rebuild
        renderer.settle_rendering(app)

        shape.filter_state[0].selected_values.should eq(Set{"north".as(Cell)})
    end
end
