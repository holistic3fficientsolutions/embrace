require "./support/embrace_ui"

# MOVING A CELL WITH Ctrl+X / Ctrl+V. The cut marks a cell; a paste moves it - the same move as a drag.
# The cut is valid only while nothing changed that could move cells: any change of the data or of the
# Shape's perspective ends it, and so do the first thing typed or pasted into another cell (its editor, or
# a reference cell's list), Escape (when nothing else takes it), closing its Shape, and the paste. Each
# case names the mutation that turns it red.

private K = CrymbleUI::Testing::Keys

private PEOPLE = <<-EOT
    People
    Name | Age
    Al | 1
    Bo | 2
    Cy | 3
    EOT

# The same, with a field for real checkboxes (the reader keeps 'true as text: Ctrl+T makes a Bool).
private FLAGGED = <<-EOT
    People
    Name | Age | Ok
    Al | 1 |
    Bo | 2 |
    Cy | 3 |
    EOT

# People beside a table reached through a reference field (its cells are combos).
private WITH_REFERENCE = <<-EOT
    Cities
    City
    Graz
    Linz

    People
    Name | Home_City
    Al | Graz
    Bo | Linz
    Cy | Graz
    EOT

private def names(ui, shape, count = 3) : Array(String)
    (1..count).map { |rank| ui.cell_text(shape, rank, "Name") }
end

# Every record's Name, in Rank order - however many there are.
private def all_names(ui, shape) : Array(String)
    names = [] of String
    rank = 1
    loop do
        names << ui.cell_text(shape, rank, "Name")
        rank += 1
    rescue ArgumentError # no record with that Rank: the last one was read
        break
    end
    names
end

private def two_shapes(text = PEOPLE) : {EmbraceUI, ShapeState, ShapeState}
    ui = EmbraceUI.new(Fixtures.app(text, shapes: 2)[0])
    {ui, ui.app.shapes[0], ui.app.shapes[1]}
end

# The perspective back to one record per row (Rank the only Rows field) - to read the mark after a change
# that left it.
private def detail_again(ui, shape) : Nil
    Fixtures.pivot(shape, ["Rank"], aggregates: ["Name", "Age"])
    Fixtures.refresh(ui.app, ui.renderer, shape)
end

describe "moving a cell with Ctrl+X / Ctrl+V" do
    # The data-safety case: the cut pointed at a grid position, so after an insert the paste moved another
    # record's cell. Red before the fix. Mutation: drop the version from the cut's stamp.
    it "moves nothing after a record was inserted since the cut" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.insert_record(shape, 1, "Name")
        before = names(ui, shape, 4)
        ui.paste_cell(shape, 3, "Name")
        names(ui, shape, 4).should eq(before)
        ui.cut_marked(shape).should be_nil
    end

    # Mutations: cancel on navigation; crymble-ui's click restoring no committed source.
    it "survives moving around - an arrow key and a click on another cell - and the paste then moves it" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.press_in_grid(shape, "Down")
        ui.click_cell(shape, 2, "Age")
        ui.cut_marked(shape).should eq({1, "Name"})
        ui.paste_cell(shape, 3, "Name")
        ui.cut_marked(shape).should be_nil # the paste consumed the cut
        names(ui, shape).should eq(["Bo", "Cy", "Al"])
    end

    it "is marked at once when cut from the context menu, and a second cut moves the mark" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.context_menu_on(shape, 2, "Name")
        ui.context_menu :cut_cell
        ui.cut_marked(shape).should eq({2, "Name"})
        ui.cut_cell(shape, 3, "Age")
        ui.cut_marked(shape).should eq({3, "Age"})
    end

    it "says there is nothing to paste when no cell was cut" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.paste_cell(shape, 3, "Name")
        ui.status.should contain(EmbraceApp::NOTHING_TO_PASTE)
    end
end

describe "a pending cell cut and editing" do
    # Mutation: no Change source on the text cell (on_cell_edit never fired) - the mark stays until the
    # commit. The mid-edit read is what tells the two apart.
    it "ends with the first character typed into another cell - before anything is saved" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.cut_marked(shape).should eq({1, "Name"})
        ui.type_in_cell(shape, 2, "Age", "5")
        ui.cut_marked(shape).should be_nil
    end

    # Mutation: cancel_cut requesting a rebuild - the first character would be committed alone.
    it "lets the whole value typed into another cell be saved" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.type_into_cell(shape, 2, "Age", "42")
        ui.cell_text(shape, 2, "Age").should eq("42")
    end

    # Mutation: end the cut on an edit of its own cell too.
    it "survives typing into the cut cell itself, until the new value is saved" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.type_in_cell(shape, 1, "Name", "Z")
        ui.cut_marked(shape).should eq({1, "Name"})
    end

    # Mutation: compare the cell without the Shape - the same position in another Shape would keep it.
    it "ends with typing into the same position of another Shape" do
        ui, a, b = two_shapes
        ui.cut_cell(a, 1, "Name")
        ui.type_in_cell(b, 1, "Name", "Z")
        ui.cut_marked(a).should be_nil
    end
end

describe "a pending cell cut and a reference cell's list" do
    # Typing into another cell ends the cut whatever the cell: a reference cell's list filter is typed into
    # as a text cell's editor is. Mutation: the reference cell's box without on_filter.
    it "ends with the character that opens another reference cell's list" do
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.type_in_cell(shape, 2, "Home", "L")
        ui.cut_marked(shape).should be_nil
    end

    it "survives opening another reference cell's list, and ends with the first character typed into it" do
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.press_on_cell(shape, 2, "Home", "Enter") # the list opens
        ui.cut_marked(shape).should eq({1, "Name"})
        ui.keys(K.typed("L"))
        ui.cut_marked(shape).should be_nil
    end

    # A paste into the open list's filter is its first change, as a paste into a text cell's open editor.
    it "ends with a paste into another reference cell's open list" do
        CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
        CrymbleUI::Widget.clipboard.text = "Li"
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.press_on_cell(shape, 2, "Home", "Enter")
        ui.press("Ctrl+V")
        ui.cut_marked(shape).should be_nil
    end

    # Mutation: end the cut on any filter typing, its own cell's included.
    it "survives typing into the cut reference cell's own list" do
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Home")
        ui.type_in_cell(shape, 1, "Home", "L")
        ui.cut_marked(shape).should eq({1, "Home"})
    end
end

describe "a pending cell cut ends on any change of the data or the Shape's perspective" do
    # For each: cut Rank 1's Name, make the change, the mark is gone, and a paste at Rank 2 moves nothing.
    # Mutations: drop the version from the stamp (all but the filter); drop the pivot
    # identity (the filter - a new pivot, no version moved).
    {
        "a deleted record"              => ->(ui : EmbraceUI, s : ShapeState) { ui.delete_record(s, 2, "Age") },
        "Ctrl+T on another cell"        => ->(ui : EmbraceUI, s : ShapeState) { ui.press_on_cell(s, 2, "Ok", "Ctrl+T") },
        "Ctrl+U on another cell"        => ->(ui : EmbraceUI, s : ShapeState) { ui.press_on_cell(s, 2, "Age", "Ctrl+U") },
        "a cell dragged to another row" => ->(ui : EmbraceUI, s : ShapeState) { ui.drag_cell(s, 2, "Age", onto_rank: 3) },
        "a commit"                      => ->(ui : EmbraceUI, s : ShapeState) { ui.shape_menu(s, :commit) },
        # (No EmbraceUI act drives the filter panel yet; the filter specs set it the same way.)
        "a filter hiding a record" => ->(ui : EmbraceUI, s : ShapeState) {
            s.filter_add(0, s.column_distinct_values(0).map(&.[0]).reject { |v| v == "Bo" }.to_set)
            s.update(true)
            ui.app.request_rebuild
            ui.renderer.settle_rendering(ui.app)
        },
        "the Rank order flipped" => ->(ui : EmbraceUI, s : ShapeState) {
            fl = s.fieldlist.not_nil!
            name_col = Table::Lazy::Fieldlist::ColumnIndices::Name.value
            sort_col = Table::Lazy::Fieldlist::ColumnIndices::SortAscending.value
            rank = (0...fl.size[0]).find! { |ri| fl[[ri, name_col]] == "Rank" }
            fl[[rank, sort_col]] = !fl[[rank, sort_col]].as(Bool)
            Fixtures.refresh(ui.app, ui.renderer, s)
        },
        "a regroup (and back)" => ->(ui : EmbraceUI, s : ShapeState) {
            Fixtures.pivot(s, ["Age"], aggregates: ["Name"])
            Fixtures.refresh(ui.app, ui.renderer, s)
            detail_again(ui, s)
        },
        "a level change (and back)" => ->(ui : EmbraceUI, s : ShapeState) {
            Fixtures.pivot(s, {"Rank" => 0, "Age" => 1}, aggregates: ["Name"])
            Fixtures.refresh(ui.app, ui.renderer, s)
            detail_again(ui, s)
        },
    }.each do |change, apply|
        it "ends on #{change}" do
            ui = EmbraceUI.tables(FLAGGED)
            shape = ui.shape("People")
            ui.cut_cell(shape, 1, "Name")
            apply.call(ui, shape)
            ui.cut_marked(shape).should be_nil
            before = all_names(ui, shape)
            ui.paste_cell(shape, 2, "Name")
            all_names(ui, shape).should eq(before)
            ui.status.should contain(EmbraceApp::NOTHING_TO_PASTE)
        end
    end

    # The switch moves the version too: no single mutation of the stamp turns this red.
    it "ends on a switch of the Shape's table (and back)" do
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        picker = shape.widget_table_picker
        people = picker.lid
        picker.select_index(0) # Cities, alphabetically first
        Fixtures.refresh(ui.app, ui.renderer, shape)
        picker.lid = people
        Fixtures.refresh(ui.app, ui.renderer, shape)
        ui.cut_marked(shape).should be_nil
    end

    it "ends on a step back in history" do
        ui = EmbraceUI.tables(FLAGGED)
        shape = ui.shape("People")
        ui.shape_menu(shape, :commit)
        ui.type_into_cell(shape, 2, "Age", "7")
        ui.cut_cell(shape, 1, "Name")
        ui.history shape, :back
        ui.cut_marked(shape).should be_nil
    end

    # Not typed (typing ends a cut on its first character already): a cell set in the other Shape.
    it "ends on a change made in another Shape of the same table" do
        ui, a, b = two_shapes(FLAGGED)
        ui.cut_cell(a, 1, "Name")
        ui.press_on_cell(b, 2, "Ok", "Ctrl+T")
        ui.cut_marked(a).should be_nil
    end
end

describe "a pending cell cut and its Shape" do
    # Mutation: drop the Shape guard in paste_cut - the other Shape's grid would move the cut's position.
    it "pastes nothing in another Shape, and says where the cut is" do
        ui, a, b = two_shapes
        ui.cut_cell(a, 1, "Name")
        ui.paste_cell(b, 3, "Name")
        ui.status.should contain("is in \"#{a.display_title}\"")
        names(ui, b).should eq(["Al", "Bo", "Cy"])
        ui.context_menu_on(b, 3, "Name")
        ui.enabled?("ctx_paste_cell").should be_false
    end

    # The build after the insert ends the cut already; the paste's own check of the other Shape's cut covers
    # a paste in the same batch as the change, which no act here reaches (no mutation turns this red).
    it "says there is nothing to paste in another Shape once the cut has ended in its own" do
        ui, a, b = two_shapes
        ui.cut_cell(a, 1, "Name")
        ui.insert_record(a, 3, "Name")
        ui.paste_cell(b, 3, "Name")
        ui.status.should contain(EmbraceApp::NOTHING_TO_PASTE)
    end

    # Both closes reach close_shape, which ends the cut; and a paste elsewhere names only an open Shape whose
    # cut still holds. Either alone keeps these green.
    {"its title bar", "the Shape menu"}.each do |how|
        it "ends when its Shape closes through #{how}" do
            ui, a, b = two_shapes
            ui.cut_cell(a, 1, "Name")
            if how == "its title bar"
                ui.find(a.id).as(CrymbleUI::WindowPanel).close
                ui.renderer.settle_rendering(ui.app)
            else
                ui.shape_menu(a, :close)
            end
            ui.paste_cell(b, 3, "Name")
            ui.status.should contain(EmbraceApp::NOTHING_TO_PASTE)
        end
    end
end

describe "Escape and a pending cell cut" do
    # Mutation: Escape always ends the cut (no consumes_escape? check).
    it "leaves the cut while Escape backs out of an editor, and ends it with the next Escape" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.press_on_cell(shape, 2, "Age", "Enter") # the editor opens, nothing typed
        ui.cut_marked(shape).should eq({1, "Name"})
        ui.press_in_grid(shape, "Escape")
        ui.cut_marked(shape).should eq({1, "Name"})
        ui.press_in_grid(shape, "Escape")
        ui.cut_marked(shape).should be_nil
        ui.paste_cell(shape, 3, "Name")
        ui.status.should contain(EmbraceApp::NOTHING_TO_PASTE)
    end

    # Mutation: end the cut before closing the context menu.
    it "leaves the cut while Escape closes a context menu, and ends it with the next Escape" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.context_menu_on(shape, 2, "Age")
        ui.close_menu
        ui.cut_marked(shape).should eq({1, "Name"})
        ui.press_in_grid(shape, "Escape")
        ui.cut_marked(shape).should be_nil
    end

    # A text field outside the grid - a filter's search - takes Escape itself. Mutation: Escape always
    # ends the cut.
    it "leaves the cut while a filter's search field has the focus" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        shape.filter_add(0, shape.column_distinct_values(0).map(&.[0]).to_set) # before the cut: it is a change
        shape.update(true)
        ui.app.request_rebuild
        ui.renderer.settle_rendering(ui.app)
        ui.cut_cell(shape, 1, "Name")
        ui.ui.press("Escape", on: "filter_search_0_#{shape.id}")
        ui.cut_marked(shape).should eq({1, "Name"})
    end

    # A combo cell: its list open, Escape closes the list and keeps the cut; a pick is a change and ends it.
    # Mutation: Escape always ends the cut.
    it "leaves the cut while Escape closes a combo's list, and a pick ends it" do
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.press_on_cell(shape, 2, "Home", "Enter") # the list opens
        ui.press("Escape")
        ui.cut_marked(shape).should eq({1, "Name"})
        ui.press_on_cell(shape, 1, "Home", "Enter")
        ui.press("Down")
        ui.press("Enter") # a pick: Graz -> Linz
        ui.cell_text(shape, 1, "Home").should eq("Linz")
        ui.cut_marked(shape).should be_nil
    end
end

describe "a pending cell cut and one batch of input" do
    # A checkbox write rebuilds WITHOUT holding the input back, so a Ctrl+V in the same batch runs before
    # that rebuild: the paste must check the cut itself. The control batch (no toggle) does move the
    # record - the target is valid and the batch reaches the paste. Mutation: paste_cut reading the cut
    # without checking it.
    it "moves nothing when a checkbox was toggled earlier in the same batch" do
        {true, false}.each do |toggle|
            ui = EmbraceUI.tables(FLAGGED)
            shape = ui.shape("People")
            ui.press_on_cell(shape, 3, "Ok", "Ctrl+T") # a real checkbox
            ui.cut_cell(shape, 1, "Name")
            ui.focus_cell(shape, 3, "Ok") # two Lefts from here reach Rank 3's Name
            events = [] of LibCSFML::Event
            events.concat([K.pressed(SF::Keyboard::Key::Space), K.text(' ')]) if toggle
            events.concat(K.tap(SF::Keyboard::Key::Left) + K.tap(SF::Keyboard::Key::Left) + K.ctrl(SF::Keyboard::Key::V))
            ui.keys(events)
            moved = names(ui, shape) != ["Al", "Bo", "Cy"]
            moved.should eq(!toggle)
        end
    end

    # Mutation: crymble-ui's restore after a drag that dropped nothing.
    it "survives a drag of another cell that dropped nowhere" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cut_cell(shape, 1, "Name")
        ui.drag_away(shape, 2, "Age")
        ui.cut_marked(shape).should eq({1, "Name"})
    end
end

describe "a pending cut of a merged cell" do
    # Cut through the LOWER part of a group header spanning two rows, then type into it through that part:
    # the edit reports the header's top-left, and the cut is stored as the top-left too - so it is the cut
    # cell's own edit, and the cut stays. Mutation: store the cursor's cell, not the top-left.
    it "is stored by its top-left, so editing it through another part keeps the cut" do
        ui = EmbraceUI.tables("People\nName | Group | Age\nAl | A | 1\nBo | A | 2\nCy | B | 3")
        shape = ui.shape("People")
        Fixtures.pivot(shape, {"Group" => 0, "Name" => 1}, aggregates: ["Age"])
        Fixtures.refresh(ui.app, ui.renderer, shape)
        ui.focus_header_part(shape, "A", 1)
        ui.press_in_grid(shape, "Ctrl+X")
        ui.cut_marked_header(shape).should eq("A")
        ui.focus_header_part(shape, "A", 1)
        ui.type_in_grid(shape, "Z")
        ui.cut_marked_header(shape).should eq("A")
    end
end
