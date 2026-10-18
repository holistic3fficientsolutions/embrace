require "./support/embrace_ui"

# Where a dialog opens: every dialog - a question, Factor out, its Add table, the file browser - opens one step
# right and down from the open dialogs, so the title bar of each one behind it shows and a press there brings it
# back. Nothing is modal: a user leaves a dialog open, opens another to look something up, and returns by its title.
# With none open, a dialog opens at the first place. Positions are compared with each other, never with numbers.

private PEOPLE = <<-EOT
    People
    Name | City | Age
    Anna | Graz | 30
    EOT

private CITIES_AND_PEOPLE = <<-EOT
    Cities
    City
    Graz

    People
    Name | City
    Anna | Graz
    EOT

private NINE = <<-EOT
    Letters
    A | B | C | D | E | F | G | H | I
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9
    EOT

private def only(ui : EmbraceUI, prefix : String) : String
    ui.ui.only(prefix).id.not_nil!
end

private def at(panel : CrymbleUI::WindowPanel) : {Float64, Float64}
    {panel.x, panel.y}
end

# File > New asks while there are unsaved changes; Cancel leaves the document as it is.
private def new_asked_and_cancelled(ui : EmbraceUI) : Nil
    ui.menu(:file_new_empty)
    ui.answer("unsaved", :cancel)
end

describe "where a dialog opens" do
    it "a question opened over Factor out leaves its title bar reachable" do
        ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
        factor_out = ui.factor_out(ui.shape("People"), "People", "City", "Cities", "City")
        ui.menu(:file_new_empty) # a fixture app starts unsaved: New asks
        ui.reachable_under(factor_out.id, ui.question("unsaved").id.not_nil!)
    end

    it "Factor out's own Add table leaves Factor out's title bar reachable" do
        ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
        factor_out = ui.factor_out(ui.shape("People"), "People", "City", "Cities", "City")
        ui.click(factor_out.part(:addtable))
        ui.reachable_under(factor_out.id, only(ui, "creator_"))
    end

    it "the file browser opened by File > Load leaves Factor out's title bar reachable" do
        ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
        factor_out = ui.factor_out(ui.shape("People"), "People", "City", "Cities", "City")
        ui.menu(:file_load)
        ui.reachable_under(factor_out.id, only(ui, "dirbrowser_"))
    end

    it "Import's own Browse leaves Import's title bar reachable" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.shape_menu(ui.shape("People"), :import_xlsx)
        import = only(ui, "importtable_")
        ui.click("#{import}_browse")
        ui.reachable_under(import, only(ui, "dirbrowser_"))
    end

    it "the file browser opened by File > Load leaves an open question's title bar reachable" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.menu(:file_new_empty)
        question = ui.question("unsaved").id.not_nil!
        ui.menu(:file_load)
        ui.reachable_under(question, only(ui, "dirbrowser_"))
    end

    it "with nothing open, a question opens where the first one did" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        first = at(ui.question("field 'City'"))
        ui.answer("field 'City'", :cancel)
        ui.questions.should be_empty
        ui.ask_delete_field(shape, "People", "Name") # another text: a panel of its own, nothing carried over
        at(ui.question("field 'Name'")).should eq first
    end

    it "dialogs opened and closed meanwhile do not push a later one onto a dialog left open" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.ask_delete_field(ui.shape("People"), "People", "City") # left open
        7.times { new_asked_and_cancelled(ui) }
        ui.menu(:file_new_empty)
        ui.questions.size.should eq 2 # precondition: the delete question and this one
        ui.reachable_under(ui.question("field 'City'").id.not_nil!, ui.question("unsaved").id.not_nil!)
    end

    # Guards (green before).

    it "the same, with Factor out left open" do
        ui = EmbraceUI.tables(CITIES_AND_PEOPLE, open: "People")
        factor_out = ui.factor_out(ui.shape("People"), "People", "City", "Cities", "City")
        7.times { new_asked_and_cancelled(ui) }
        ui.menu(:file_new_empty)
        ui.reachable_under(factor_out.id, ui.question("unsaved").id.not_nil!)
    end

    it "a question asked again takes no new place: the next one opens one step on" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.ask_delete_field(shape, "People", "City")
        ui.ask_delete_field(shape, "People", "Name")
        ui.ask_delete_field(shape, "People", "City") # comes forward
        ui.ask_delete_field(shape, "People", "Age")
        ui.questions.size.should eq 3 # no twin
        q1, q2, q3 = {"City", "Name", "Age"}.map { |field| at(ui.question("field '#{field}'")) }
        {q3[0] - q2[0], q3[1] - q2[1]}.should eq({q2[0] - q1[0], q2[1] - q1[1]})
    end

    # The stated limit: the steps run out after eight, and the ninth opens at the first place again.
    it "of nine open questions, the eighth opens off the first and the ninth where the first is" do
        ui = EmbraceUI.tables(NINE)
        shape = ui.shape("Letters")
        fields = %w(A B C D E F G H I)
        fields.each { |field| ui.ask_delete_field(shape, "Letters", field) }
        ui.questions.size.should eq 9 # precondition
        first = at(ui.question("field 'A'"))
        at(ui.question("field 'H'")).should_not eq first
        at(ui.question("field 'I'")).should eq first
    end

    # Associate fields had a place of its own, above and left of the others; it opens in the same steps now.
    it "Associate fields' own Add field leaves Associate's title bar reachable" do
        ui = EmbraceUI.tables(PEOPLE)
        ui.right_click ui.configurator_table(ui.shape("People"), "People")
        ui.context_menu :associate_fields
        associate = only(ui, "disassociate_")
        ui.click("#{associate}_add_mux")
        ui.reachable_under(associate, only(ui, "addfield_"))
    end
end
