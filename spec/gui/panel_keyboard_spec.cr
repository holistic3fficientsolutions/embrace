require "./support/embrace_ui"

# The panel in front holds the keyboard (crymbleui's rule), as embrace uses it: a Shape's keyboard home is its grid;
# a dialog keeps Tab to itself; a confirm takes the keyboard on its Ok, and Enter acts on the button Tab reached; a
# dialog closing hands the keyboard back to where it was in the Shape; a second confirm comes to the front.

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    EOT

private def field?(ui : EmbraceUI, shape : ShapeState, name : String) : Bool
    ui.configurator_field(shape, "People", name)
    true
rescue ArgumentError
    false
end

private def ask_delete(ui : EmbraceUI, shape : ShapeState, field : String) : Nil
    ui.right_click ui.configurator_field(shape, "People", field)
    ui.context_menu :delete_field
end

private def front_id(ui : EmbraceUI) : String?
    ui.app.root.not_nil!.find_topmost_panel.try(&.id)
end

describe "the keyboard in embrace's panels" do
    it "at launch the Shape holds the keyboard in its grid" do
        ui = EmbraceUI.start
        ui.ui.focused_id.should eq(ui.grid(ui.app.shapes.first)) # before: its first Tab stop, an id-less section header
    end

    it "a new Shape opens with the keyboard in its grid" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.menu(:view_new_shape)
        ui.ui.focused_id.should eq(ui.grid(ui.app.shapes.last)) # before: its first Tab stop, an id-less section header
    end

    it "Tab cycles inside the Add field dialog, never into the Shape behind it" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) do |d|
            ui.ui.focused_id.should eq(d.part(:name))
            seen = [] of String?
            4.times { ui.ui.press("Tab"); seen << ui.ui.focused_id }
            seen.last.should eq(d.part(:name))
            seen.compact.sort.should eq([d.part(:name), d.part(:ok), d.part(:cancel), d.part(:reftable)].sort)
        end
    end

    it "closing a dialog hands the keyboard back to the widget that held it in the Shape" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.click("mx_addf_dlg_#{shape.id}") # the "..." button takes the keyboard, then the dialog
        ui.dialog(:add_field) { |d| d.press :name, "Escape" }
        ui.ui.focused_id.should eq("mx_addf_dlg_#{shape.id}")
    end

    it "a delete confirm opens on Ok; Tab to Cancel and Enter cancels, Space on Ok deletes" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ask_delete(ui, shape, "City")
        ui.ui.focused_id.should eq(ui.question_button("field 'City'", :ok))
        ui.ui.press("Tab")
        ui.ui.focused_id.should eq(ui.question_button("field 'City'", :cancel))
        ui.ui.press("Enter")
        field?(ui, shape, "City").should be_true # before: Enter was the confirm's Ok - deleted
        ask_delete(ui, shape, "City")
        ui.ui.press("Space")
        field?(ui, shape, "City").should be_false
    end

    # Changed meaning (decided: questions coexist): the second no longer replaces the first - both stay, the new one
    # in front with the keyboard. Once it stayed behind the Shape; then it replaced the first.
    it "a second delete confirm, while one waits behind the Shape, comes to the front with the keyboard - both stay" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ask_delete(ui, shape, "City")
        ui.ui.press_title shape.id # the Shape in front, the first confirm behind it
        ask_delete(ui, shape, "Name")
        front_id(ui).should eq(ui.question("field 'Name'").id)
        ui.ui.focused_id.should eq(ui.question_button("field 'Name'", :ok))
        ui.questions.size.should eq 2
    end
end
