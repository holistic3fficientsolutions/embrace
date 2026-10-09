require "./support/embrace_ui"

# A CELL DROPPED ON ANOTHER SHAPE. A cell's place is a place in its own Shape's grid; applied to another
# Shape it would move THAT Shape's cell at the same grid coordinates - another record, or another table's.
# So it is refused: nothing moves, in either Shape. The panels cascade over each other, so each case first moves
# the target Shape's panel below the source's (a real drag of its title bar); the press brings the source's
# panel to front.

private PEOPLE_AND_ANIMALS = <<-EOT
    People
    Name | Age
    Al | 1
    Bo | 2
    Cy | 3

    Zoo
    Animal | Legs
    Ant | 6
    Bee | 6
    Cat | 4
    EOT

# Why the act was refused, or nil - read AFTER the data, so a run that was not refused shows what moved.
private def refusal(&) : String?
    yield
    nil
rescue ex : CrymbleUI::Testing::Driver::Refusal
    ex.message
end

private def column(ui : EmbraceUI, shape : ShapeState, field : String) : Array(String)
    (1..3).map { |rank| ui.cell_text(shape, rank, field) }
end

# Two Shapes, the second switched to `table` through its table picker (as Fixtures does), its panel moved
# clear of the first.
private def two_shapes(table : String) : {EmbraceUI, ShapeState, ShapeState}
    ui = EmbraceUI.new(Fixtures.app(PEOPLE_AND_ANIMALS, shapes: 2)[0])
    a, b = ui.app.shapes[0], ui.app.shapes[1]
    unless table == "People"
        picker = b.widget_table_picker
        picker.select_index(picker.names.index(table) || raise ArgumentError.new("no table #{table}"))
        b.update(true)
        ui.app.request_rebuild
        ui.renderer.settle_rendering(ui.app)
    end
    ui.move_panel(b, 0.0, 600.0)
    {ui, a, b}
end

describe "a cell dragged onto another Shape" do
    # Were the drop taken, B would move its own cell at A's coordinates - Ant's row to Bee's place.
    it "is refused, and moves nothing in a Shape of another table" do
        ui, a, b = two_shapes("Zoo")
        why = refusal { ui.drag_cell(a, 1, "Name", onto: b, onto_rank: 2, onto_field: "Animal") }
        column(ui, a, "Name").should eq(["Al", "Bo", "Cy"])
        column(ui, b, "Animal").should eq(["Ant", "Bee", "Cat"])
        why.should match(/does not accept/)
    end

    # The reported case: two Shapes of ONE table - the coordinates look meaningful there, and the wrong move
    # reorders the very records the user sees in both.
    it "is refused, and moves nothing in another Shape of the same table" do
        ui, a, b = two_shapes("People")
        why = refusal { ui.drag_cell(a, 1, "Name", onto: b, onto_rank: 3, onto_field: "Name") }
        column(ui, a, "Name").should eq(["Al", "Bo", "Cy"])
        column(ui, b, "Name").should eq(["Al", "Bo", "Cy"])
        why.should match(/does not accept/)
    end

    # Only a drag that moves a cell ends a pending cut (doc/08); a refused one moves nothing.
    it "leaves a pending cut in the source Shape" do
        ui, a, b = two_shapes("Zoo")
        ui.cut_cell(a, 2, "Name")
        why = refusal { ui.drag_cell(a, 1, "Name", onto: b, onto_rank: 2, onto_field: "Animal") }
        ui.cut_marked(a).should eq({2, "Name"})
        why.should match(/does not accept/)
    end
end
