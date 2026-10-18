require "./support/embrace_ui"

# Questions (delete, overwrite, unsaved changes) are panels like any other - embrace has no modal dialogs: a user
# can leave one open, look something up, and come back. Several can be open at once, each Ok acts on its own
# question, the same question asked again comes forward, and an Ok whose target has gone says so instead of
# failing. Nothing ties a question to the Shape or document that asked it: its Ok acts as things stand.

private MAILS = <<-EOT
    Mails
    receiver | sender | feedback
    Alice | Boss1 |
    Bob | Boss2 |
    Carol | Boss3 |
    EOT

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    EOT

private CITIES_AND_PEOPLE = <<-EOT
    Cities
    City
    Graz

    People
    Name | City
    Anna | Graz
    EOT

private def field?(ui : EmbraceUI, shape : ShapeState, *path : String) : Bool
    ui.configurator_field(shape, *path)
    true
rescue ArgumentError
    false
end

# The field's context menu enables Factor in only for a reference - what a user sees after a factor-out.
private def reference?(ui : EmbraceUI, shape : ShapeState, table : String, field : String) : Bool
    ui.right_click ui.configurator_field(shape, table, field)
    offers = ui.ui.enabled?("ctx_factor_in")
    ui.close_menu
    offers
end

describe "questions" do
    it "two delete questions are both open, and each Ok deletes its own field - the older one answered first" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        ui.ui.press_title shape.id # the question behind the Shape - left open to look something up
        ui.ask_delete_field(shape, "People", "Name")
        ui.questions.size.should eq 2 # before: the second replaced the first
        ui.answer("field 'City'", :ok)
        field?(ui, shape, "People", "City").should be_false
        field?(ui, shape, "People", "Name").should be_true # not the front question's action
        ui.answer("field 'Name'", :ok)
        field?(ui, shape, "People", "Name").should be_false
        ui.renderer.exceptions_caught.should eq 0
    end

    it "New with unsaved changes asks beside an open question, and its Ok makes the new document" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.type_into_cell(shape, 1, "Name", "Bea") # unsaved
        ui.ask_delete_field(shape, "People", "City")
        ui.menu(:file_new_empty)
        ui.questions.size.should eq 2 # before: New only brought the delete question forward - and did nothing
        ui.answer("unsaved", :ok)
        ui.status.should contain("New file (empty)")
    end

    it "an Ok on a field whose table was deleted since says so - nothing deleted, nothing raised" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        ui.ask_delete_table(shape, "People")
        ui.answer("table 'People'", :ok)
        ui.answer("field 'City'", :ok) # before: no such question (replaced); answered late, it raised
        ui.status.should contain("City")
        ui.status.should contain("nothing was deleted")
        ui.renderer.exceptions_caught.should eq 0
    end

    it "the same question asked again comes forward, with the keyboard on its Ok - no twin" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        ui.ask_delete_field(shape, "People", "Name")
        ui.ask_delete_field(shape, "People", "City")
        ui.questions.size.should eq 2 # before: one - each ask replaced the last
        ui.questions.first.should contain("field 'City'")
        ui.ui.focused_id.should eq(ui.question_button("field 'City'", :ok))
    end

    # Guard (green before): the X closes a question for good - asked again, it opens again.
    it "a question closed with its X opens again when asked again, in front with the keyboard" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        ui.ui.close_panel(ui.question("field 'City'").id.not_nil!)
        ui.questions.should be_empty
        ui.ask_delete_field(shape, "People", "City")
        ui.questions.size.should eq 1
        ui.ui.focused_id.should eq(ui.question_button("field 'City'", :ok))
    end

    # RED before at its precondition (two never coexisted); it is what proves the cascade once the others are green.
    # The second question comes from the File menu: one asked from a Shape (its configurator) brings the Shape
    # forward over the first, and that one is then reached by Ctrl+Tab - see the harness's bring_forward.
    it "a second question opens off the first, so the first stays reachable; neither moves when one closes" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        ui.menu(:file_new_empty) # a fixture app starts unsaved: New asks
        back = ui.question("field 'City'")
        at = {back.x, back.y}
        ui.ui.press_title back.id.not_nil! # its title bar shows beside the front question's
        ui.ui.focused_id.should eq(ui.question_button("field 'City'", :ok))
        ui.answer("unsaved", :cancel)
        back = ui.question("field 'City'")
        {back.x, back.y}.should eq(at)
    end

    it "an Ok on a table renamed and deleted since says so, and the other tables stay" do
        ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
        shape = ui.shape("People")
        ui.ask_delete_table(shape, "People")
        ui.right_click ui.configurator_table(shape, "People")
        ui.context_menu :rename_table
        ui.dialog(:rename) { |d| d.fill :name, "Folks"; d.click :ok }
        ui.ask_delete_table(shape, "Folks")
        ui.answer("table 'Folks'", :ok)
        ui.answer("table 'People'", :ok) # before: no such question (replaced)
        ui.status.should contain("People")
        ui.status.should contain("nothing was deleted")
        ui.menu(:view_new_shape)
        picker = ui.app.shapes.last
        ui.ui.find("tablepick_#{picker.id}").as(CrymbleUI::ComboBox).items.should contain("Cities")
        ui.renderer.exceptions_caught.should eq 0
    end

    it "a question left from a document New replaced says so when answered - nothing deleted, nothing raised" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        ui.menu(:file_new_empty)
        ui.answer("unsaved", :ok) # a fixture app starts unsaved; before: New asked nothing beside the open question
        ui.answer("field 'City'", :ok)
        ui.status.should contain("City")
        ui.status.should contain("nothing was deleted")
        ui.renderer.exceptions_caught.should eq 0
    end

    # The regression these guard: the late-Ok check compared the field's table with the configurator row's own key
    # (a field row's key is the field), so every Ok said "no longer there" and nothing was factored out.
    describe "Factor out, answered" do
        it "makes the field a reference into an existing table" do
            ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
            shape = ui.shape("People")
            ui.factor_out(shape, "People", "City", "Cities", "City").click :ok
            ui.status.should_not contain("nothing was factored out")
            reference?(ui, shape, "People", "City").should be_true
        end

        it "makes the field a reference into a table and field made in the dialog" do
            ui = EmbraceUI.tables(PEOPLE)
            shape = ui.shape("People")
            ui.right_click ui.configurator_field(shape, "People", "City")
            ui.context_menu :factor_out
            ui.dialog(:factor_out) do |d|
                d.click :addtable
                ui.dialog(:create) { |c| c.fill :name, "Towns"; c.click :ok }
                d.click :addfield
                ui.dialog(:create) { |c| c.fill :name, "Town"; c.click :ok }
                ui.ui.enabled?(d.part(:ok)).should be_true # precondition: a target is picked
                d.click :ok
            end
            ui.status.should_not contain("nothing was factored out")
            reference?(ui, shape, "People", "City").should be_true
        end
    end

    it "Factor out, as reported: receiver of an unnamed table into a new table staff, field name" do
        ui = EmbraceUI.tables(MAILS)
        shape = ui.shape("Mails")
        ui.right_click ui.configurator_table(shape, "Mails")
        ui.context_menu :rename_table
        ui.dialog(:rename) { |d| d.press :name, "Ctrl+A"; d.press :name, "Backspace"; d.click :ok } # shown as (unnamed)
        ui.right_click ui.configurator_field(shape, "(unnamed)", "receiver")
        ui.context_menu :factor_out
        ui.dialog(:factor_out) do |d|
            d.click :addtable
            ui.dialog(:create) { |c| c.fill :name, "staff"; c.click :ok }
            d.click :addfield
            ui.dialog(:create) { |c| c.fill :name, "name"; c.click :ok }
            d.click :ok
        end
        ui.status.should_not contain("nothing was factored out")
        reference?(ui, shape, "(unnamed)", "receiver").should be_true
        (1..3).map { |rank| ui.cell_text(shape, rank, "receiver") }.should eq(%w(Alice Bob Carol))
        ui.renderer.exceptions_caught.should eq 0
    end

    # Guard: a field reached through a reference belongs to the referenced table - its question names that one.
    it "a delete question on a field reached through a reference names that field's own table" do
        ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
        shape = ui.shape("People")
        ui.factor_out(shape, "People", "City", "Cities", "City").click :ok
        ui.expand(shape, "People", "City")
        ui.ask_delete_field(shape, "People", "City", "Cities", "City")
        ui.questions.first.should contain("'City' of 'Cities'")
    end

    it "a delete question names the field's table" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.ask_delete_field(ui.shape("People"), "People", "City")
        ui.questions.first.should contain("'City' of 'People'")
    end

    describe "Factor out, answered late" do
        it "says so when its field was deleted while it was open" do
            ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
            shape = ui.shape("People")
            dialog = ui.factor_out(shape, "People", "City", "Cities", "City")
            ui.ask_delete_field(shape, "People", "City")
            ui.answer("field 'City'", :ok)
            dialog.click :ok # before: raised
            ui.status.should contain("nothing was factored out")
            ui.renderer.exceptions_caught.should eq 0
        end

        # Guard (green before): a target deleted while the dialog is open cannot be factored into - the dialog's
        # pickers lose it, so its Ok is disabled.
        it "cannot be answered Ok once its target was deleted while it was open" do
            ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
            shape = ui.shape("People")
            dialog = ui.factor_out(shape, "People", "City", "Cities", "City")
            ui.menu(:view_new_shape)
            other = ui.app.shapes.last
            ui.ui.type("tablepick_#{other.id}", "Cities")
            ui.ui.press("Enter")
            ui.ask_delete_table(other, "Cities")
            ui.answer("table 'Cities'", :ok)
            ui.ui.enabled?(dialog.part(:ok)).should be_false
            ui.renderer.exceptions_caught.should eq 0
        end

        it "says so for the second of two on the same field" do
            ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
            shape = ui.shape("People")
            first = ui.factor_out(shape, "People", "City", "Cities", "City")
            second = ui.factor_out(shape, "People", "City", "Cities", "City")
            first.click :ok
            reference?(ui, shape, "People", "City").should be_true # the first one factored out
            second.click :ok # before: raised - the field is a reference now
            ui.status.should contain("nothing was factored out")
            ui.renderer.exceptions_caught.should eq 0
        end
    end

    describe "the keyboard" do
        it "Cancel on one question leaves the other answerable" do
            ui = EmbraceUI.tables(PEOPLE)
            shape = ui.shape("People")
            ui.ask_delete_field(shape, "People", "City")
            ui.ask_delete_field(shape, "People", "Name")
            ui.answer("field 'Name'", :cancel)
            ui.questions.size.should eq 1
            ui.answer("field 'City'", :ok)
            field?(ui, shape, "People", "City").should be_false
            field?(ui, shape, "People", "Name").should be_true
        end

        it "Enter in the older question answers that one only" do
            ui = EmbraceUI.tables(PEOPLE)
            shape = ui.shape("People")
            ui.ask_delete_field(shape, "People", "City")
            ui.ask_delete_field(shape, "People", "Name")
            ui.bring_forward("field 'City'")
            ui.ui.press("Enter")
            field?(ui, shape, "People", "City").should be_false
            field?(ui, shape, "People", "Name").should be_true
            ui.questions.size.should eq 1
        end

        # Guards (green before).
        it "Enter with the keyboard in the Shape answers no question" do
            ui = EmbraceUI.tables(PEOPLE)
            shape = ui.shape("People")
            ui.ask_delete_field(shape, "People", "City")
            ui.ui.press_title shape.id
            ui.ui.press("Enter")
            field?(ui, shape, "People", "City").should be_true
            ui.questions.size.should eq 1
        end

        it "answering the front one of two hands the keyboard back to the Shape's grid" do
            ui = EmbraceUI.tables(PEOPLE)
            shape = ui.shape("People")
            ui.ask_delete_field(shape, "People", "City")
            ui.ui.press_title shape.id # the older question behind the Shape
            ui.ask_delete_field(shape, "People", "Name")
            ui.answer("field 'Name'", :cancel)
            ui.ui.focused_id.should eq(ui.grid(shape))
        end
    end
end
