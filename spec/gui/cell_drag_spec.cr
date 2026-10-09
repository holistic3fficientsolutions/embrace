require "./support/embrace_ui"

# DRAGGING A GRID CELL (a perspective's cell move): the record takes the clusters of the cell it is
# dropped on - it regroups in a pivot, it reorders in the detail layout. Driven as a user drags,
# through crymble-ui's Driver#drag_cell; read as the grid shows it.

private PEOPLE = <<-EOT
    People
    Name | Group | Age
    Al | A | 1
    Bo | A | 2
    Cy | B | 3
    EOT

# Rows Group, columns Name, the aggregate Age: A x Al shows 1, A x Bo 2, B x Cy 3.
private def pivot_ui(shapes : Int32 = 1) : {EmbraceUI, ShapeState}
    ui = EmbraceUI.new(Fixtures.app(PEOPLE, shapes: shapes)[0])
    shape = ui.app.shapes.first
    Fixtures.pivot(shape, ["Group"], columns: ["Name"], aggregates: ["Age"])
    Fixtures.refresh(ui.app, ui.renderer, shape)
    {ui, shape}
end

describe "dragging a grid cell" do
    # Mutation: on_drop leaves the cursor on the source cell (no set_cursor_from_cell).
    it "moves a record into another group of a pivot, the cursor following it" do
        ui, shape = pivot_ui
        ui.drag_cell shape, rows: ["A"], cols: ["Al"], onto_rows: ["B"], onto_cols: ["Al"]
        ui.cursor_cell(shape).should eq(EmbraceUI::PivotCell.new(["B"], ["Al"]))
        ui.pivot_text(shape, rows: ["B"], cols: ["Al"]).should eq("1")
        ui.pivot_text(shape, rows: ["A"], cols: ["Al"]).should eq("")
    end

    # The same mutation: the cursor would stay on Rank 1, which now shows Bo.
    it "reorders the records in the detail layout" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.drag_cell shape, 1, "Name", onto_rank: 3
        ui.cursor_cell(shape).should eq({3, "Name"})
        {1 => "Bo", 2 => "Cy", 3 => "Al"}.each { |rank, name| ui.cell_text(shape, rank, "Name").should eq(name) }
    end

    # Dropped on an occupied cell, the record takes that cell's column values too (the target's
    # clusters win, doc/07): Al becomes a second Cy in group B. Mutation: the source's clusters win
    # (Hierarchic#hyperplane_move) - Al keeps his name.
    it "gives a record dropped on an occupied cell that cell's column values" do
        ui, shape = pivot_ui
        ui.drag_cell shape, rows: ["A"], cols: ["Al"], onto_rows: ["B"], onto_cols: ["Cy"]
        ui.pivot_text(shape, rows: ["B"], cols: ["Cy"]).should eq("#2/Σ4") # two records, their Ages summed
        expect_raises(ArgumentError, /no cell rows: \["A"\], cols: \["Al"\]/) do
            ui.pivot_text(shape, rows: ["A"], cols: ["Al"])
        end
    end

    # A group's header is a target too: the record takes that header's value and keeps its others.
    # Mutation: on_drop skips the move - nothing moves.
    it "moves a record into the group whose header it is dropped on" do
        ui, shape = pivot_ui
        ui.drag_cell shape, rows: ["A"], cols: ["Al"], onto_header: "B"
        ui.cursor_cell(shape).should eq(EmbraceUI::PivotCell.new(["B"], ["Al"]))
        ui.pivot_text(shape, rows: ["B"], cols: ["Al"]).should eq("1")
        ui.pivot_text(shape, rows: ["A"], cols: ["Al"]).should eq("")
        ui.pivot_text(shape, rows: ["B"], cols: ["Cy"]).should eq("3")
    end

    # And back: dropped on its old group's header, the record returns. Mutation: the header's
    # clusters lose to the source's - Al stays in B.
    it "moves a record back through its old group's header" do
        ui, shape = pivot_ui
        ui.drag_cell shape, rows: ["A"], cols: ["Al"], onto_header: "B"
        ui.drag_cell shape, rows: ["B"], cols: ["Al"], onto_header: "A"
        ui.pivot_text(shape, rows: ["A"], cols: ["Al"]).should eq("1")
        ui.pivot_text(shape, rows: ["B"], cols: ["Al"]).should eq("")
    end

    # Mutation: count a header spanning two rows twice - "A" becomes ambiguous.
    it "moves a record onto a group header that spans several rows" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        Fixtures.pivot(shape, {"Group" => 0, "Name" => 1}, aggregates: ["Age"])
        Fixtures.refresh(ui.app, ui.renderer, shape)
        ui.drag_cell shape, rows: ["B", "Cy"], cols: [] of String, onto_header: "A"
        ui.pivot_text(shape, rows: ["A", "Cy"], cols: [] of String).should eq("3")
    end

    # A move changes data (doc/08): another Shape on the same open commit shows it. Mutation: on_drop
    # skips the move.
    it "shows the move in another Shape on the same commit" do
        ui = EmbraceUI.new(Fixtures.app(PEOPLE, shapes: 2)[0])
        first, second = ui.app.shapes
        ui.drag_cell first, 1, "Name", onto_rank: 3
        ui.cell_text(second, 3, "Name").should eq("Al")
    end

    # History steps between commits (doc/09) - navigation, not undo: after a commit, one step back
    # shows the grid without the move, one forward shows it again. Mutation: the move outside the
    # Shape's context (ShapeState#cell_move without with_shape_context).
    it "is not in the commit before it, and is in the open one" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.shape_menu(shape, :commit)
        ui.drag_cell shape, 1, "Name", onto_rank: 3
        ui.history shape, :back
        ui.cell_text(shape, 1, "Name").should eq("Al")
        ui.history shape, :forward
        ui.cell_text(shape, 3, "Name").should eq("Al")
    end
end
