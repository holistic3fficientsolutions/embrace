require "./support/embrace_ui"
require "crymble-ui/testing/test_font"

# A PIVOT'S CELLS THAT SCROLLED AWAY ARE LET GO: the grid makes a fresh widget for every cell it shows, and a widget
# that has rendered is subscribed to the global zoom and theme (its pull node read them). A cell the grid let go of
# must leave those subscriptions too, or every cell ever scrolled past stays reachable - measured at about 2000 more
# per scroll down and back through a 400-row pivot, without end. Read on the two Sources' dependent counts, which
# must come back to the same number each time the grid is back at the top.

private ROWS = String.build do |io|
    io << "People\nName | Group | Age\n"
    400.times { |i| io << "N#{i} | G#{i % 9} | #{i}\n" }
end

private def dependents : {Int32, Int32}
    {CrymbleUI::FontSizing.zoom_source_dependent_count, CrymbleUI::Theme.current_source_dependent_count}
end

describe "a pivot's cells that scrolled away" do
    around_each do |example|
        font = CrymbleUI::Widget.font
        CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new # text measures, as on screen
        example.run
    ensure
        CrymbleUI::Widget.font = font
    end

    it "leave the zoom and theme subscriptions: the counts are steady from one scroll cycle to the next" do
        ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
        shape = ui.app.shapes.first
        grid = ui.find("matrix_grid_#{shape.id}").as(CrymbleUI::VirtualMatrix)
        ui.renderer.settle_rendering(ui.app)
        grid.active_cells.values.any?(&.primitives_node).should be_true # instrument: the cells subscribe (they rendered)
        # a content cell of the top rows (a sticky one never leaves)
        first = grid.active_cells.min_by { |(row, col), _| col >= grid.sticky_col_count && row >= grid.sticky_row_count ? row : Int32::MAX }[1]
        at_top = [] of {Int32, Int32}
        3.times do
            (1..20).each { |i| grid.scroll_offset = CrymbleUI::Vec2.new(0.0, i * 300.0); ui.renderer.render_frame(ui.app) }
            (grid.scroll_offset.y > 3000.0).should be_true # instrument: far down...
            first.parent.should be_nil                     # ...where the cells shown at the top have left
            (1..20).each { |i| grid.scroll_offset = CrymbleUI::Vec2.new(0.0, (20 - i) * 300.0); ui.renderer.render_frame(ui.app) }
            at_top << dependents
        end
        at_top[1].should eq(at_top[0])
        at_top[2].should eq(at_top[0])
    end
end
