require "./support/embrace_ui"

# Ctrl+. in a Shape's grid types today's date as "YYYYMMDD " - exactly as if typed: at the caret while a cell is
# being edited, starting an edit on a cell the cursor is on. Nowhere else (a Shape's other fields take no date).

private PEOPLE = <<-EOT
    People
    Name | Note
    Anna | x
    EOT

private TWO_ANNAS = <<-EOT
    People
    Name | Note
    Anna | x
    Anna | y
    EOT

# Today as typed - both sides of a midnight the spec might run across.
private def dated(&) : Array(String)
    before = Time.local.to_s("%Y%m%d")
    yield
    [before, Time.local.to_s("%Y%m%d")].uniq
end

describe "Ctrl+. types today's date in a Shape's grid" do
    it "at the caret while a cell is being edited" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        dates = dated do
            ui.type_in_cell(shape, 1, "Note", "abc")
            ui.ui.press("Ctrl+Period") # to the editor holding the keyboard
            ui.ui.type("meeting")
            ui.ui.press("Enter")
        end
        dates.map { |d| "abc#{d} meeting" }.should contain(ui.cell_text(shape, 1, "Note"))
    end

    it "starting an edit on the cell the cursor is on" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        dates = dated do
            ui.focus_cell(shape, 1, "Note")
            ui.ui.press("Ctrl+Period")
            ui.ui.type("meeting")
            ui.ui.press("Enter")
        end
        dates.map { |d| "#{d} meeting" }.should contain(ui.cell_text(shape, 1, "Note"))
    end

    # A cell holding only the date reads as a number - as if the digits were typed (the space is not kept).
    it "a cell given only the date holds it as a number" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        dates = dated do
            ui.focus_cell(shape, 1, "Note")
            ui.ui.press("Ctrl+Period")
            ui.ui.press("Enter")
        end
        dates.should contain(ui.cell_text(shape, 1, "Note"))
    end

    # The Shape's other text fields take no date: typed into the table picker it would open its list, filtered.
    it "types nothing into the Shape's table picker" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        picker = "tablepick_#{shape.id}"
        ui.ui.press("Ctrl+Period", on: picker)
        ui.ui.focused_id.should eq(picker)
        ui.app.root.not_nil!.as(CrymbleUI::Window).overlays.should be_empty # no list opened
        ui.cell_text(shape, 1, "Note").should eq("x")
    end

    # On a drill-down cell typing drills, and the rest of the typing waits for the drilled Shape: the date drills
    # once - not once per character.
    it "on a drill-down cell drills once" do
        ui = EmbraceUI.tables(TWO_ANNAS)
        shape = ui.shape("People")
        Fixtures.open_fieldlist(ui.app, ui.renderer)
        ui.drag ui.fieldlist_field(shape, "People", "Rank"), onto: ui.unused_zone(shape)
        ui.drag ui.fieldlist_field(shape, "People", "Name"), onto: ui.rows_zone(shape)
        ui.pivot_text(shape, ["Anna"], field: "Note").should eq("#2") # precondition: a drill-down cell
        ui.click_pivot_cell(shape, ["Anna"], "Note")
        ui.ui.press("Ctrl+Period")
        ui.app.shapes.size.should eq 2
    end
end
