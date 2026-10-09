require "./support/embrace_ui"
require "crexcel"

# What a user types into a dialog's text field is what the dialog acts on - for every dialog with one: Add table,
# Rename, Add field, Import xlsx. Ok and Enter accept what was typed; Escape closes and changes nothing.

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    EOT

# A real one-sheet workbook under temp/ (gitignored): Region | Amount, one record.
private def workbook(& : String ->) : Nil
    dir = "temp/spec_fixtures/dialog-inputs-#{Random::Secure.hex(4)}"
    Dir.mkdir_p(dir)
    path = File.join(dir, "book.xlsx")
    wb = Crexcel::Workbook.new(path)
    ws = wb.add_worksheet("t")
    ws.write_row(0, ["Region", "Amount"])
    ws.write_row(1, ["north", 10])
    wb.close
    yield path
ensure
    FileUtils.rm_rf(dir) if dir
end

private def table_names(ui : EmbraceUI) : Array(String)
    ui.app.persistency.get_table(MetaFieldLIDs::TableLastTable).map { |row| ui.app.persistency.display_name(row[0].as(Persistency::TableLID)) }
end

describe "a dialog's text field" do
    it "Add table: Ok creates the table under the typed name" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.click("addtable_#{ui.shape("People").id}")
        ui.dialog(:create) { |d| d.fill :name, "Towns"; d.click :ok }
        table_names(ui).should contain("Towns")
    end

    it "Add table: Enter accepts like Ok" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.click("addtable_#{ui.shape("People").id}")
        ui.dialog(:create) { |d| d.fill :name, "Towns"; d.press :name, "Enter" }
        table_names(ui).should contain("Towns")
        expect_raises(ArgumentError, /no single :create dialog/) { ui.dialog(:create) { } } # closed
    end

    it "Add table: Escape closes and adds nothing" do
        ui = EmbraceUI.tables(PEOPLE)
        before = table_names(ui)
        ui.click("addtable_#{ui.shape("People").id}")
        ui.dialog(:create) { |d| d.fill :name, "Towns"; d.press :name, "Escape" }
        table_names(ui).should eq(before)
        expect_raises(ArgumentError, /no single :create dialog/) { ui.dialog(:create) { } }
    end

    it "Rename: Ok renames to the typed name, and the old name is what it starts with" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_field(shape, "People", "City")
        ui.context_menu :rename_field
        ui.dialog(:rename) do |d|
            ui.ui.text(d.part(:name)).should eq("City") # seeded with the old name
            d.type :name, "s"
            d.click :ok
        end
        ui.configurator_field(shape, "People", "Citys")
    end

    it "Rename: Enter accepts, Escape changes nothing" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_field(shape, "People", "City")
        ui.context_menu :rename_field
        ui.dialog(:rename) { |d| d.fill :name, "Town"; d.press :name, "Escape" }
        ui.configurator_field(shape, "People", "City") # unchanged
        ui.right_click ui.configurator_field(shape, "People", "City")
        ui.context_menu :rename_field
        ui.dialog(:rename) { |d| d.fill :name, "Town"; d.press :name, "Enter" }
        ui.configurator_field(shape, "People", "Town")
    end

    it "Add field: Ok adds a field under the typed name; Enter too; Escape adds none" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) { |d| d.fill :name, "Age"; d.click :ok }
        ui.configurator_field(shape, "People", "Age")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) { |d| d.fill :name, "Born"; d.press :name, "Enter" }
        ui.configurator_field(shape, "People", "Born")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) { |d| d.fill :name, "Gone"; d.press :name, "Escape" }
        expect_raises(ArgumentError, /no single :add_field dialog/) { ui.dialog(:add_field) { } } # closed
        expect_raises(ArgumentError, /no configurator row People > Gone/) { ui.configurator_field(shape, "People", "Gone") }
    end

    it "Import: Ok imports the typed file under the typed table name" do
        workbook do |path|
            ui = EmbraceUI.tables(PEOPLE)
            ui.shape_menu(ui.shape("People"), :import_xlsx)
            ui.dialog(:import) do |d|
                ui.ui.text(d.part(:table)).should eq("(new table)") # the name it starts with
                d.fill :file, path
                d.fill :table, "Sales"
                d.click :ok
            end
            ui.shape("Sales") # imported, and opened on
            ui.status.should contain("Imported \"Sales\"")
        end
    end

    it "Import: Enter in either field accepts; Escape imports nothing" do
        workbook do |path|
            ui = EmbraceUI.tables(PEOPLE)
            ui.shape_menu(ui.shape("People"), :import_xlsx)
            ui.dialog(:import) { |d| d.fill :file, path; d.fill :table, "Gone"; d.press :table, "Escape" }
            table_names(ui).should_not contain("Gone")
            ui.shape_menu(ui.shape("People"), :import_xlsx)
            ui.dialog(:import) { |d| d.fill :file, path; d.fill :table, "Sales"; d.press :table, "Enter" }
            ui.shape("Sales")
            ui.shape_menu(ui.shape("People"), :import_xlsx)
            ui.dialog(:import) { |d| d.fill :table, "Again"; d.fill :file, path; d.press :file, "Enter" }
            ui.shape("Again") # Enter in the file name accepts too
        end
    end

    it "Rename: Ok without typing keeps the name" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_field(shape, "People", "City")
        ui.context_menu :rename_field
        ui.dialog(:rename) { |d| d.click :ok }
        ui.configurator_field(shape, "People", "City")
    end

    it "Add field: what was typed survives the dialog rebuilding (a reference table picked)" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) do |d|
            d.fill :name, "Friend"
            d.press :reftable, "Enter" # the list opens
            ui.ui.press("Down")
            ui.ui.press("Enter")       # a table picked: the dialog rebuilds, with a field picker now
            ui.ui.present?(d.part(:reffield)).should be_true
            d.click :ok
        end
        ui.configurator_field(shape, "People", "Friend")
    end

    it "Import: the table name typed before Browse is the one used; untouched, it is \"(new table)\"" do
        workbook do |path|
            {"Picked", nil}.each do |typed|
                ui = EmbraceUI.tables(PEOPLE)
                ui.shape_menu(ui.shape("People"), :import_xlsx)
                import_id = ui.ui.only("importtable_").id.not_nil!
                ui.dialog(:import) { |d| d.fill :table, typed } if typed
                ui.ui.click("#{import_id}_browse")
                browse = ui.ui.only("dirbrowser_").id.not_nil!
                ui.ui.select_file("#{browse}_files", "temp")
                ui.ui.select_file("#{browse}_files", "temp") # into temp/
                ui.ui.open_file("#{browse}_files", path.lchop("temp/"))
                ui.dialog(:import) { |d| d.click :ok }
                ui.shape(typed || "(new table)")
                ui.status.should contain("book.xlsx") # the picked file
            end
        end
    end

    # Dialogs are not modal: a click on a Shape panel brings it to the front and can leave the keyboard in the
    # dialog's field. Escape then reaches the field, not the dialog window's shortcut - and still closes it.
    {create: {"addtable_", :name}, rename: {nil, :name}, add_field: {"mx_addf_dlg_", :name},
     import: {"mi_import_xlsx_", :file}, import_table: {"mi_import_xlsx_", :table}}.each do |kind, (opener, part)|
        it "#{kind}: Escape in its field closes it while another panel is in front" do
            ui = EmbraceUI.tables(PEOPLE)
            shape = ui.shape("People")
            if opener
                opener.starts_with?("mi_") ? ui.shape_menu(shape, :import_xlsx) : ui.click("#{opener}#{shape.id}")
            else
                ui.right_click ui.configurator_field(shape, "People", "City")
                ui.context_menu :rename_field
            end
            dialog_kind = kind == :import_table ? :import : kind
            ui.dialog(dialog_kind) do |d|
                d.type part, "x" # the keyboard is in the field
                ui.ui.find(shape.id).as(CrymbleUI::WindowPanel).bring_to_front
                ui.ui.focused_id.should eq(d.part(part)) # control: still there, with the Shape panel in front
                ui.ui.press("Escape")
            end
            expect_raises(ArgumentError, /no single :#{dialog_kind} dialog/) { ui.dialog(dialog_kind) { } }
        end
    end
end
