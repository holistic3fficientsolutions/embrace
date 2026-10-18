require "./support/embrace_ui"

# A field just added is where the keyboard goes next: its cell in the first record, with the grid's cursor on it
# and the keyboard in the grid - whichever way it was added (Add field, or "..." with a name or a reference). And a
# dialog's field takes the keyboard once, when the dialog opens: a dialog that rebuilds (a pick in one of its own
# lists) leaves the keyboard where the user put it.

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    Bert | Linz
    EOT

private PEOPLE_AND_TOWNS = <<-EOT
    People
    Name | City
    Anna | Graz
    Bert | Linz

    Towns
    Town
    Graz
    Linz
    EOT

private def grid_focused?(ui : EmbraceUI, shape : ShapeState) : Bool
    focused = CrymbleUI::Widget.focus_manager.focused_widget
    while focused
        return true if focused.id == "matrix_grid_#{shape.id}"
        focused = focused.parent
    end
    false
end

describe "a field just added" do
    it "Add field: the cursor is on the new field in the first record, the keyboard in the grid" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.focus_cell(shape, 2, "City") # the cursor somewhere else first
        ui.click("mx_addf_#{shape.id}")
        ui.cursor_cell(shape).should eq({1, "(unnamed)"})
        grid_focused?(ui, shape).should be_true
    end

    it "\"...\" with a name: the cursor is on that field in the first record, the keyboard in the grid" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.focus_cell(shape, 2, "City")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) { |d| d.fill :name, "Age"; d.press :name, "Enter" }
        ui.cursor_cell(shape).should eq({1, "Age"})
        grid_focused?(ui, shape).should be_true
    end

    it "\"...\" with a reference: the cursor is on the new reference field in the first record" do
        ui = EmbraceUI.tables(PEOPLE_AND_TOWNS)
        shape = ui.shape("People")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) do |d|
            d.fill :name, "Home"
            d.type :reftable, "Towns" # the list opens, filtered to it
            ui.ui.press("Enter")
            d.click :ok
        end
        ui.cursor_cell(shape).should eq({1, "Home"})
        grid_focused?(ui, shape).should be_true
        ui.expand(shape, "People", "Home") # a click: it takes the keyboard, as a press does
        ui.configurator_table(shape, "People", "Home", "Towns") # it is the reference picked
    end

    it "the typed text then goes into the new field" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) { |d| d.fill :name, "Age"; d.press :name, "Enter" }
        ui.ui.type(CrymbleUI::Widget.focus_manager.focused_widget.not_nil!.id.not_nil!, "41")
        ui.ui.press("Enter")
        ui.cell_text(shape, 1, "Age").should eq("41")
    end
end

describe "a dialog's field takes the keyboard once" do
    it "Add field: after a reference table is picked, the keyboard stays on that list" do
        ui = EmbraceUI.tables(PEOPLE_AND_TOWNS)
        shape = ui.shape("People")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) do |d|
            ui.ui.focused_id.should eq(d.part(:name)) # on opening
            d.press :reftable, "Enter"
            ui.ui.press("Down")
            ui.ui.press("Enter") # a table picked: the dialog rebuilds
            ui.ui.focused_id.should eq(d.part(:reftable))
        end
    end

    {create: {"addtable_", :create}, add_field: {"mx_addf_dlg_", :add_field}}.each do |name, (opener, kind)|
        it "#{name}: a rebuild while the keyboard is on Ok leaves it there" do
            ui = EmbraceUI.tables(PEOPLE)
            shape = ui.shape("People")
            ui.click("#{opener}#{shape.id}")
            ui.dialog(kind) do |d|
                ui.ui.focused_id.should eq(d.part(:name)) # on opening
                ui.ui.find(d.part(:ok)).request_focus
                ui.app.request_rebuild
                ui.ui.settle
                ui.ui.focused_id.should eq(d.part(:ok))
            end
        end
    end

    it "rename: a rebuild while the keyboard is on Ok leaves it there" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_field(shape, "People", "City")
        ui.context_menu :rename_field
        ui.dialog(:rename) do |d|
            ui.ui.focused_id.should eq(d.part(:name))
            ui.ui.find(d.part(:ok)).request_focus
            ui.app.request_rebuild
            ui.ui.settle
            ui.ui.focused_id.should eq(d.part(:ok))
        end
    end
end
