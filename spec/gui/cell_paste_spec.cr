require "./support/embrace_ui"

# PASTING INTO AN OPEN CELL EDITOR. A spreadsheet puts one copied cell on the clipboard in its TSV encoding -
# a value holding a line break, a tab or a quote arrives quoted - so the editor pastes the value that encoding
# stands for; any other payload pastes as text. A cell that is not being edited leaves Ctrl+V to the grid.
#
# The clipboard is a process-global shared by every gui spec in one binary: each example installs its own.

private PEOPLE = <<-EOT
    People
    Name | Group
    Al | A
    Bo | A
    Cy | B
    EOT

private def paste_into_editor(ui : EmbraceUI, shape : ShapeState, payload : String) : Nil
    CrymbleUI::Widget.clipboard.text = payload
    ui.press_in_grid(shape, "Enter")  # the editor opens on the value
    ui.press_in_grid(shape, "Ctrl+A") # the paste replaces it
    ui.press_in_grid(shape, "Ctrl+V")
    ui.press_in_grid(shape, "Enter")
end

describe "pasting into an open cell editor" do
    # Mutation: no paste transform in cell_paint - the quotes arrive.
    it "pastes one spreadsheet cell as its value, line break included" do
        CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.focus_cell(shape, 1, "Name")
        paste_into_editor(ui, shape, %("Al\nAlbert"\n)) # as a spreadsheet writes it: quoted, terminated
        ui.cell_text(shape, 1, "Name").should eq("Al\nAlbert")
    end

    # Mutation: no paste transform in cell_paint.
    it "unquotes an inner quote too" do
        CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.focus_cell(shape, 2, "Name")
        paste_into_editor(ui, shape, %("Bo ""the"" Bold"\r\n))
        ui.cell_text(shape, 2, "Name").should eq(%(Bo "the" Bold))
    end

    # Mutation: single_field without the round trip - the tolerant decoder would drop these quotes.
    it "pastes text that is not one cell's encoding as it is" do
        CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.focus_cell(shape, 1, "Name")
        paste_into_editor(ui, shape, %("Al" she said))
        ui.cell_text(shape, 1, "Name").should eq(%("Al" she said))
    end

    # Mutation: single_field without the round trip - the first cell alone would paste.
    it "pastes several cells as text, their tab a space" do
        CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.focus_cell(shape, 1, "Name")
        paste_into_editor(ui, shape, "Al\tA\n")
        ui.cell_text(shape, 1, "Name").should eq("Al A")
    end

    # A header's editor too: renaming the group to the cell's value, line break included. (Every cell editor
    # takes breaks; a single-line input flattens the value - crymble-ui's paste specs.) Mutation: no paste
    # transform in cell_paint.
    it "pastes one cell into a group header's editor as its value" do
        CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        Fixtures.pivot(shape, {"Group" => 0, "Name" => 1}, aggregates: [] of String)
        Fixtures.refresh(ui.app, ui.renderer, shape)
        ui.focus_header_part(shape, "B", 0)
        paste_into_editor(ui, shape, %("Be\nta"\n))
        ui.focus_header_part(shape, "Be\nta", 0) # raises unless the header now reads so
    end

    # The editor declines the clipboard keys until it is editing: Ctrl+V stays the grid's (the cut's paste).
    # Green before this change - it pins the rule doc/08 states, not the transform.
    it "leaves Ctrl+V on a cell not being edited to the grid" do
        CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
        CrymbleUI::Widget.clipboard.text = %("Al\nAlbert"\n)
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.press_on_cell(shape, 1, "Name", "Ctrl+V")
        ui.status.should contain(EmbraceApp::NOTHING_TO_PASTE)
        ui.cell_text(shape, 1, "Name").should eq("Al")
    end
end
