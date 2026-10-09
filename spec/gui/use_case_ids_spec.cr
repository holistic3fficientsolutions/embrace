require "./support/embrace_ui"

# THE FLOWS A USER DOES, WRITTEN AS THE USER WOULD SAY THEM - through embrace's logical widget ids
# (GUI::Ids, doc/modules/07-app.md) and crymble-ui's test Driver, via spec/gui/support/embrace_ui.cr.

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    Bert | Linz
    EOT

describe "use cases through logical ids" do
    it "loads a file through File > Load and the dialog" do
        Fixtures.document_file("people", PEOPLE) do |path|
            ui = EmbraceUI.start
            ui.menu(:file_load)
            ui.dialog(:load) { |d| d.open_file path }
            ui.shape("People") # the loaded document opens a Shape on its table
            ui.status.should contain("Loaded")
        end
    end

    it "renames a field through the configurator's context menu" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_field(shape, "People", "City")
        ui.context_menu :rename_field
        ui.dialog(:rename) { |d| d.fill :name, "Town"; d.click :ok }
        ui.text(ui.configurator_field(shape, "People", "Town")).strip.should eq("Town") # the row's label
        expect_raises(ArgumentError, /no configurator row People > City/) { ui.configurator_field(shape, "People", "City") }
    end

    it "drags a field into Rows" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.fieldlist_section(shape, "People", "City").should eq({:aggregates, 1}) # control
        ui.drag ui.fieldlist_field(shape, "People", "City"), onto: ui.rows_zone(shape)
        ui.fieldlist_section(shape, "People", "City").should eq({:rows, 1})
        shape.detail_layout?.should be_false # the grid now groups by City:
        ui.ui.cell_text("matrix_grid_#{shape.id}", 0, 1).should eq("Graz") # Rank | City | Name, City a row header
    end

    it "commits through the Shape menu" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.shape_menu(shape, :commit)
        ui.status.should contain("Committed")
    end

    # ACCEPTANCE: no production id is missing for this one - it shows the cell helpers work end to end,
    # and that the typed value reached the data (read again after the grid is redrawn from it).
    it "types a value into a cell and reads it back from the grid" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cell_text(shape, rank: 2, field: "City").should eq("Linz")
        ui.type_into_cell(shape, rank: 2, field: "City", text: "Wels")
        ui.cell_text(shape, rank: 2, field: "City").should eq("Wels")
        ui.shape_menu(shape, :commit) # the grid is drawn again from what was stored
        ui.cell_text(shape, rank: 2, field: "City").should eq("Wels")
    end
end
