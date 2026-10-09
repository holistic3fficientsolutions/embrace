require "./support/embrace_ui"
require "crymble-ui/testing/test_font"

# A ROW CUT BY THE GRID'S EDGE IS CUT, NOT SLID: a one-line row whose box the band's edge crosses - the panel's
# bottom as the user shrinks it, the sticky header as the data scrolls under it - keeps its label where it sits in
# the row, and the edge cuts both, as it cuts the cell's background. Its ruler number stays level with it. (The
# old rule centred the label in the part of the row still showing: shrinking the panel walked the last row's label
# up by its padding until it stuck to the box's top and was hidden - "ugly", as reported.) Read as the grid paints
# it: each cell's text against its box, each ruler number against its row.

private ROWS = String.build do |io|
    io << "Allocations\nName | Stage | Theme | Budget\n"
    60.times { |i| io << "N#{i} | Present | Law | 100\n" }
end

private def cut_row_table : {EmbraceUI, CrymbleUI::WindowPanel, CrymbleUI::VirtualMatrix}
    ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
    shape = ui.app.shapes.first
    {ui, ui.find(shape.id).as(CrymbleUI::WindowPanel), ui.find("matrix_grid_#{shape.id}").as(CrymbleUI::VirtualMatrix)}
end

# Where row `row`'s text sits in its cell (column 1) - a cell paints in its own space, from its box's top - and
# its ruler number in its row.
private def text_offset(grid : CrymbleUI::VirtualMatrix, row : Int32) : Float64
    cell = grid.active_cells[{row, 1}]
    cell.to_primitives(cell.bounds).select(CrymbleUI::DrawText).first.position.y
end

private def number_offset(grid : CrymbleUI::VirtualMatrix, row : Int32) : Float64
    ruler = grid.row_ruler_widget.not_nil!
    number = ruler.to_primitives(ruler.bounds).select(CrymbleUI::DrawText).find { |t| t.text == "#{row + 1}" }
    number.not_nil!.position.y - grid.painted_row(row)[0]
end

# The rows the band's edge `edge` (in the grid's space) cuts by at least 2px: the old rule had moved their label.
private def cut_rows(grid : CrymbleUI::VirtualMatrix, edge : Float64) : Array(Int32)
    (grid.sticky_row_count...grid.placed_row_sizes.size).select do |row|
        top, size = grid.painted_row(row)
        top + 2.0 <= edge && edge <= top + size - grid.grid_spacing - 2.0
    end
end

private def fully_shown(grid : CrymbleUI::VirtualMatrix, lo : Float64, hi : Float64) : Int32
    (grid.sticky_row_count...grid.placed_row_sizes.size).find! do |row|
        top, size = grid.painted_row(row)
        top >= lo && top + size <= hi
    end
end

describe "a one-line row cut by the grid's edge" do
    around_each do |example|
        font = CrymbleUI::Widget.font
        CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new # text measures, so a label has a height to centre
        example.run
    ensure
        CrymbleUI::Widget.font = font
    end

    # Red before: the last row's label rode its padding up as the bottom edge cut the row (3 -> 2 -> 1 -> 0px).
    it "keeps its label, and its ruler number, where they sit at rest while the user shrinks the panel" do
        ui, panel, grid = cut_row_table
        start = CrymbleUI::Vec2.new(panel.x + 200.0, panel.y + panel.height - 1.0)
        panel.on_mouse_down(start)
        cuts = 0
        y = start.y
        40.times do # 80px: the edge crosses several rows
            y -= 2.0
            panel.on_mouse_move(CrymbleUI::Vec2.new(start.x, y))
            ui.renderer.render_frame(ui.app)
            edge = grid.bounds.height
            rest = fully_shown(grid, grid.ruler_row_height_pixels + grid.sticky_row_height_pixels, edge)
            cut_rows(grid, edge).each do |row|
                cuts += 1
                text_offset(grid, row).should be_close(text_offset(grid, rest), 0.001)
                number_offset(grid, row).should be_close(number_offset(grid, rest), 0.001)
            end
        end
        panel.on_mouse_up(CrymbleUI::Vec2.new(start.x, y))
        (cuts > 0).should be_true # instrument: the edge cut a row, by enough to have moved its label
    end

    # Red before: under the sticky header the leaving row's label was pushed DOWN into what was left of it.
    it "keeps its label, and its ruler number, where they sit at rest while the row scrolls under the header" do
        ui, _panel, grid = cut_row_table
        edge = grid.ruler_row_height_pixels + grid.sticky_row_height_pixels
        cuts = 0
        24.times do |step| # one row's pitch: every depth of cut
            grid.scroll_offset = CrymbleUI::Vec2.new(0.0, step.to_f64)
            ui.renderer.settle_rendering(ui.app)
            rest = fully_shown(grid, edge, grid.bounds.height)
            cut_rows(grid, edge).each do |row|
                cuts += 1
                text_offset(grid, row).should be_close(text_offset(grid, rest), 0.001)
                number_offset(grid, row).should be_close(number_offset(grid, rest), 0.001)
            end
        end
        (cuts > 0).should be_true # instrument: the header cut a row, by enough to have moved its label
    end
end
