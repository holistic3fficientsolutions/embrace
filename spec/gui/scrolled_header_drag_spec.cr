require "./support/embrace_ui"

# DROPPING ON A HEADER OF A SCROLLED PIVOT: a pivot's group headers are sticky - the grid holds them still
# while the data scrolls under them - and a drop onto one lands where the header is painted, however far the
# grid has scrolled either way. Driven as a user drags (crymble-ui's Driver#drag_cell aims at where a cell is
# painted); read as the grid shows it.

# Forty groups down, sixty names across: a pivot that scrolls on both axes in the default window.
private WIDE = String.build do |io|
    io << "People\nName | Group | Age\n"
    60.times { |i| io << "N#{i.to_s.rjust(2, '0')} | G#{(i % 40).to_s.rjust(2, '0')} | #{i}\n" }
end

private def scrolled_pivot : {EmbraceUI, ShapeState, CrymbleUI::VirtualMatrix}
    ui = EmbraceUI.new(Fixtures.app(WIDE)[0])
    shape = ui.app.shapes.first
    Fixtures.pivot(shape, ["Group"], columns: ["Name"], aggregates: ["Age"])
    Fixtures.refresh(ui.app, ui.renderer, shape)
    grid = ui.find("matrix_grid_#{shape.id}").as(CrymbleUI::VirtualMatrix)
    grid.scroll_offset = CrymbleUI::Vec2.new(300.6, 150.7)
    ui.renderer.settle_rendering(ui.app)
    {ui, shape, grid}
end

describe "dropping on a header of a scrolled pivot" do
    # Red before: the press aimed at the header's viewport_bounds, a scroll away from where it is painted, and
    # the drop was refused (under another header, or none). Mutation: the Driver aims in the matrix's space.
    it "moves a record into the group whose (sticky) row header it is dropped on" do
        ui, shape, grid = scrolled_pivot
        ui.drag_cell shape, rows: ["G12"], cols: ["N12"], onto_header: "G11"
        (grid.scroll_offset.x > 0.0 && grid.scroll_offset.y > 0.0).should be_true # instrument: scrolled both ways at the drop
        ui.pivot_text(shape, rows: ["G11"], cols: ["N12"]).should eq("12")
    end

    it "moves a record onto the name whose (sticky) column header it is dropped on" do
        ui, shape, grid = scrolled_pivot
        ui.drag_cell shape, rows: ["G12"], cols: ["N12"], onto_header: "N11"
        (grid.scroll_offset.x > 0.0 && grid.scroll_offset.y > 0.0).should be_true # instrument: scrolled both ways at the drop
        ui.pivot_text(shape, rows: ["G12"], cols: ["N11"]).should eq("12") # the record, now named N11 (N11's own is in G11)
    end
end
