require "./support/embrace_ui"

# GUARDS ON EMBRACE'S LOGICAL WIDGET IDS (GUI::Ids, doc/modules/07-app.md): every widget a user acts
# on carries one, no two share one (find_by_id takes the FIRST match, so a duplicate is a silent
# wrong target), they stay handles (never in user-visible text), and the old names are gone.
# Each count is pinned to the fixture's exact number, so a fixture that stops producing a kind fails
# instead of passing on nothing.

private TABLES = <<-EOT
    Cities
    City | Country
    Rome | Italy

    People
    Name | Home_City | Age
    Al | Rome | 3
    Bo | Rome | 4
    EOT

# A Shape on People with Home expanded, Name in Rows, Age in Columns (so sort boxes exist), the rest
# aggregates - and a second Shape, so ids from two Shapes meet.
private def shaped_ui : {EmbraceUI, ShapeState}
    ui = EmbraceUI.tables(TABLES, open: "People")
    shape = ui.shape("People")
    ui.expand(shape, "People", "Home")
    ui.drag ui.fieldlist_field(shape, "People", "Name"), onto: ui.rows_zone(shape)
    ui.drag ui.fieldlist_field(shape, "People", "Age"), onto: ui.columns_zone(shape)
    ui.shape_menu(shape, :duplicate)
    {ui, shape}
end

# Every widget in the tree and the window's overlays; a closed menu's items included.
private def all_widgets(ui : EmbraceUI) : Array(CrymbleUI::Widget)
    root = ui.app.root.not_nil!
    roots = [root] + (root.as?(CrymbleUI::Window).try(&.overlays) || [] of CrymbleUI::Widget)
    found = [] of CrymbleUI::Widget
    stack = roots.dup
    while w = stack.pop?
        found << w
        stack.concat(w.children)
        stack.concat(w.items) if w.is_a?(CrymbleUI::Menu) # a closed menu keeps its items there
    end
    found
end

private def ids(ui) : Array(String)
    all_widgets(ui).compact_map(&.id)
end

private ACTIONABLE = {CrymbleUI::Checkbox, CrymbleUI::DraggableBox, CrymbleUI::DropZoneBox,
                      CrymbleUI::Button, CrymbleUI::MenuItem}

describe "embrace's logical widget ids" do
    it "gives every widget a user acts on in a Shape's configurator, fieldlist and menus an id" do
        ui, shape = shaped_ui
        surfaces = ["vhtree_#{shape.id}", "fieldlist_#{shape.id}"].map { |id| ui.find(id) }
        widgets = surfaces.flat_map { |s| s.find_all { |w| ACTIONABLE.any? { |k| w.class <= k } } }
        widgets += all_widgets(ui).select(CrymbleUI::MenuItem)
        missing = widgets.reject(&.id)
        missing.map { |w| "#{w.class} #{w.parent.try(&.id)}" }.should eq([] of String) # the counts below pin that there are some
    end

    it "counts each kind of id exactly (a kind that stops being produced fails)" do
        ui, shape = shaped_ui
        counts = Hash(String, Int32).new(0)
        ids(ui).each do |id|
            next unless id.ends_with?(shape.id) || id.includes?("_#{shape.id}_")
            counts[id.split("_#{shape.id}").first] += 1
        end
        counts.select { |k, _| k.starts_with?("cfg_") || k.starts_with?("fl_") || k.starts_with?("mi_") }
            .to_a.sort.should eq(EXPECTED_COUNTS)
    end

    it "never gives two widgets one id - across two Shapes too" do
        ui, _shape = shaped_ui
        dups = ids(ui).tally.select { |id, n| n > 1 && (id.starts_with?("cfg_") || id.starts_with?("fl_") || id.starts_with?("mi_")) }
        dups.should be_empty
    end

    it "keeps each context menu's keys unique, in every menu embrace opens" do
        ui, shape = shaped_ui
        menus = 0
        check = ->{
            keys = ui.find("context_menu").find_all { |w| w.id.try(&.starts_with?("ctx_")) || false }.compact_map(&.id)
            keys.uniq.size.should eq(keys.size)
            keys.size.should be > 0
            menus += 1
            ui.close_menu
        }
        ui.right_click ui.configurator_table(shape, "People")
        check.call
        ui.right_click ui.configurator_field(shape, "People", "Age")
        ui.find("ctx_rename_field") # the FIELD menu opened, not the table's again
        check.call
        ui.right_click "tablepick_#{shape.id}"
        check.call
        ui.drag ui.configurator_drag(shape, "People", "Name"), onto: ui.configurator_drop(shape, "People", "Age")
        check.call
        grid = ui.find("matrix_grid_#{shape.id}").viewport_bounds # a cell's menu: the grid picks its cell by position
        ui.app.handle_mouse_down(CrymbleUI::Vec2.new(grid.x + grid.width / 2, grid.y + grid.height / 2), CrymbleUI::MouseButton::Right)
        ui.ui.settle
        check.call
        menus.should eq(5)
    end

    it "retires the old ids" do
        ui, shape = shaped_ui
        {"new_shape" => "mi_view_new_shape", "shape_config_one_page" => "mi_view_one_page",
         "shape_copy_tsv_#{shape.id}" => "mi_copy_tsv_#{shape.id}",
         "shape_paste_new_table_#{shape.id}" => "mi_paste_new_table_#{shape.id}",
         "auto_size_cells_#{shape.id}" => "mi_auto_size_#{shape.id}"}.each do |old, replacement|
            ui.present?(old).should be_false
            ui.present?(replacement).should be_true
        end
    end

    it "keeps ids out of everything a user reads" do
        ui, shape = shaped_ui
        ui.right_click ui.configurator_field(shape, "People", "Age")
        ui.context_menu :rename_field
        ui.dialog(:rename) { |d| d.fill :name, "Years"; d.click :ok }
        texts = all_widgets(ui).compact_map(&.hover_text) + [ui.status]
        texts += all_widgets(ui).select(CrymbleUI::Text).map(&.as(CrymbleUI::Text).text)
        leaks = texts.select { |t| t =~ /\b(cfg|fl|ctx|mi)_[a-z]+_|shape_\d{6,}|\b\d+\.\d+\.\d+\b/ }
        leaks.should eq([] of String)
    end
end

# Measured on the fixture: 8 configurator rows (People, ShowAll, Rank, Name, Home, Cities via Home and
# its three), 4 fieldlist fields (Rank, Name, Home, Age) - sort boxes on the 3 in Rows / Columns,
# none on the aggregate - in 3 sections (columns_1, rows_1, aggregates_1) with 7 drop zones, the
# field list's own buttons, and the Shape menu.
private EXPECTED_COUNTS = [
    {"cfg_drag", 3}, {"cfg_dz", 8}, {"cfg_exp", 1}, {"cfg_links", 3}, {"cfg_name", 8}, {"cfg_sel", 8},
    {"cfg_spc", 1}, {"fl_drag", 4}, {"fl_empty", 1}, {"fl_field", 4}, {"fl_miragg", 1}, {"fl_mird", 1},
    {"fl_mirh", 1}, {"fl_mirv", 1}, {"fl_norm", 1}, {"fl_section", 3}, {"fl_sort", 3}, {"fl_zone", 7},
    {"mi_add_record", 1}, {"mi_auto_size", 1}, {"mi_close", 1}, {"mi_commit", 1}, {"mi_copy_tsv", 1},
    {"mi_duplicate", 1}, {"mi_import_xlsx", 1}, {"mi_maximize", 1}, {"mi_paste_new_table", 1},
]
