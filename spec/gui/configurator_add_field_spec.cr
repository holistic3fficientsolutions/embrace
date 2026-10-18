require "./support/embrace_ui"

# A field can be added where a field is acted on - the configurator: its table menu (on a table row, or on the table
# picker) has "Add field...", the same dialog as the Perspective's "...". The field is added to THAT table, selected,
# and so shown in the Shape.

private PEOPLE_AND_TOWNS = <<-EOT
    Towns
    Town
    Graz
    Linz

    People
    Name | Home_Town
    Anna | Graz
    Bert | Linz
    EOT

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    EOT

describe "Add field... in a table's menu" do
    it "on the Shape's table: the field is added, selected and shown in the grid" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_table(shape, "People")
        ui.context_menu :add_field
        ui.dialog(:add_field) { |d| d.fill :name, "Age"; d.press :name, "Enter" }
        ui.configurator_selected?(shape, "People", "Age").should be_true
        ui.type_into_cell(shape, 1, "Age", "41")
        ui.cell_text(shape, 1, "Age").should eq("41")
    end

    it "on the table picker: the same menu, the same field" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click "tablepick_#{shape.id}"
        ui.context_menu :add_field
        ui.dialog(:add_field) { |d| d.fill :name, "Age"; d.click :ok }
        ui.configurator_selected?(shape, "People", "Age").should be_true
    end

    it "on a table reached through a reference: the field goes to that table, not the Shape's" do
        ui = EmbraceUI.tables(PEOPLE_AND_TOWNS, open: "People")
        shape = ui.shape("People")
        ui.expand(shape, "People", "Home")
        ui.right_click ui.configurator_table(shape, "People", "Home", "Towns")
        ui.context_menu :add_field
        ui.dialog(:add_field) { |d| d.fill :name, "Country"; d.press :name, "Enter" }
        ui.configurator_selected?(shape, "People", "Home", "Towns", "Country").should be_true
        towns = ui.app.persistency.get_table(MetaFieldLIDs::TableLastTable).find { |row| ui.app.persistency.display_name(row[0].as(Persistency::TableLID)) == "Towns" }.not_nil![0].as(Persistency::TableLID)
        ui.app.persistency.get_field_lids(towns).map { |f| ui.app.persistency.display_name(f) }.should contain("Country")
    end

    it "can make the field a reference, like the Perspective's \"...\"" do
        ui = EmbraceUI.tables(PEOPLE_AND_TOWNS, open: "People")
        shape = ui.shape("People")
        ui.right_click ui.configurator_table(shape, "People")
        ui.context_menu :add_field
        ui.dialog(:add_field) do |d|
            d.fill :name, "Born"
            d.type :reftable, "Towns" # the list opens, filtered to it
            ui.ui.press("Enter")
            d.click :ok
        end
        ui.expand(shape, "People", "Born") # a reference: it leads on to Towns
        ui.configurator_table(shape, "People", "Born", "Towns")
    end

    it "Escape adds nothing" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_table(shape, "People")
        ui.context_menu :add_field
        ui.dialog(:add_field) { |d| d.fill :name, "Gone"; d.press :name, "Escape" }
        expect_raises(ArgumentError, /no configurator row People > Gone/) { ui.configurator_field(shape, "People", "Gone") }
    end

    it "a Shape switched to another table while the dialog is open: nothing is added, and the status bar says why" do
        ui = EmbraceUI.tables(PEOPLE_AND_TOWNS, open: "People")
        shape = ui.shape("People")
        ui.right_click ui.configurator_table(shape, "People")
        ui.context_menu :add_field
        ui.ui.type("tablepick_#{shape.id}", "Towns") # the dialog is not modal
        ui.ui.press("Enter")
        ui.shape("Towns").should be(shape)
        ui.dialog(:add_field) { |d| d.fill :name, "Lost"; d.click :ok }
        ui.status.should contain("no longer in that Shape")
        persistency = ui.app.persistency
        tables = persistency.get_table(MetaFieldLIDs::TableLastTable).map(&.[0].as(Persistency::TableLID))
        tables.flat_map { |t| persistency.get_field_lids(t) }.map { |f| persistency.display_name(f) }.should_not contain("Lost")
    end
end
