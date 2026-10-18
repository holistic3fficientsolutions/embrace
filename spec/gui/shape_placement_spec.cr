require "./support/embrace_ui"

# Where a Shape opens: one step (20 px right and down) past the newest open Shape, as far as the window has room
# when it opens - an axis without room keeps its first place; past the room it starts over at the first spot. The
# window fits a panel inside it (crymbleui), so a step past the room would pile Shapes on one spot. Shapes are named
# by index (index 0 is the Shape the app opens with, the rest come from View > New Shape); positions are compared
# with each other, never with numbers.

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    EOT

private def app_in(width : Int32, height : Int32, shapes : Int32 = 1) : EmbraceUI
    EmbraceUI.new(Fixtures.app(PEOPLE, shapes: shapes)[0], width, height)
end

private def new_shapes(ui : EmbraceUI, count : Int32) : Nil
    count.times { ui.menu(:view_new_shape) }
end

private def at(ui : EmbraceUI, index : Int32) : {Float64, Float64}
    panel = ui.panel(ui.app.shapes[index].id)
    {panel.x, panel.y}
end

private def resize(ui : EmbraceUI, width : Int32, height : Int32) : Nil
    ui.renderer.resize(width, height)
    ui.renderer.settle_rendering(ui.app)
end

private def covered?(ui : EmbraceUI, index : Int32) : Bool
    ui.ui.press_title(ui.app.shapes[index].id)
    false
rescue ArgumentError
    true
end

describe "where a Shape opens" do
    it "past the room of a 1200x900 window, the sixth starts over on the first's spot" do
        ui = app_in(1200, 900)
        new_shapes(ui, 5)
        at(ui, 5).should eq(at(ui, 0))
    end

    it "past the room of a 1200x800 window - down has none - the sixth starts over on the first's spot" do
        ui = app_in(1200, 800)
        new_shapes(ui, 5)
        at(ui, 5).should eq(at(ui, 0))
    end

    it "with no room across (1130 wide), it steps down only, and the sixth starts over on the first's spot" do
        ui = app_in(1130, 900)
        new_shapes(ui, 5)
        at(ui, 1)[0].should eq(at(ui, 0)[0])
        at(ui, 5).should eq(at(ui, 0))
    end

    it "after a Shape is closed, a new one opens one step past the newest - on neither the closed one's nor another's spot" do
        ui = app_in(1200, 900)
        new_shapes(ui, 3)
        second, fourth = at(ui, 1), at(ui, 3)
        ui.ui.close_panel(ui.app.shapes[1].id)
        ui.app.shapes.size.should eq 3 # precondition: closed
        ui.menu(:view_new_shape)
        newest = at(ui, 3)
        newest.should_not eq(fourth)
        newest.should_not eq(second)
    end

    # The stated limit: starting over, the new Shape lies on the first and covers the next ones' title bars but a
    # strip at their right end - past the title bar's buttons only for the later ones (the usable bar ends some 48 px
    # before the right edge at the default font). Checked newest-but-one down, so a press never changes what covers
    # the next one checked.
    it "after starting over, the fourth and fifth are reached by the right end of their bar, the second and third are not" do
        ui = app_in(1200, 900)
        new_shapes(ui, 5)
        covered?(ui, 1).should be_true
        covered?(ui, 2).should be_true
        ui.reachable_under(ui.app.shapes[4].id, ui.app.shapes[5].id)
        ui.ui.press_title(ui.app.shapes[3].id)
        ui.front.should eq(ui.app.shapes[3].id)
    end

    it "a Shape opened after the window shrank counts the room the window has now" do
        ui = app_in(1400, 1000)
        new_shapes(ui, 2)
        resize(ui, 1200, 900)
        new_shapes(ui, 3)
        at(ui, 5).should eq(at(ui, 0))
    end

    it "after the window shrank, the next Shape is not on the newest's spot" do
        ui = app_in(1400, 1000)
        new_shapes(ui, 5)
        resize(ui, 1200, 900)
        ui.menu(:view_new_shape)
        at(ui, 6).should_not eq(at(ui, 5))
    end

    it "after the window shrank to a room of exactly five steps, the next Shape is not on the newest's spot" do
        ui = app_in(1400, 1000)
        new_shapes(ui, 8)
        resize(ui, 1200, 894)
        ui.menu(:view_new_shape)
        at(ui, 9).should_not eq(at(ui, 8))
    end

    # Guards (green before).

    # The stated limit: the room changing axis between two openings (across gains it, down loses all) fits both
    # Shapes to the same edge.
    it "after the window's room changed axis, the next Shape lies on the newest's spot" do
        ui = app_in(1130, 1000)
        new_shapes(ui, 4)
        resize(ui, 1200, 800)
        ui.menu(:view_new_shape)
        at(ui, 5).should eq(at(ui, 4))
    end

    it "Shapes the app opens with lie on distinct spots" do
        ui = app_in(1200, 900, shapes: 3)
        [at(ui, 0), at(ui, 1), at(ui, 2)].uniq.size.should eq 3
    end

    it "a 1400x1000 window has room for ten distinct spots" do
        ui = app_in(1400, 1000)
        new_shapes(ui, 9)
        (0..9).map { |i| at(ui, i) }.uniq.size.should eq 10
    end

    it "in a 1200x800 window five Shapes step across only, each older one reached by the left end of its bar" do
        ui = app_in(1200, 800)
        new_shapes(ui, 4)
        spots = (0..4).map { |i| at(ui, i) }
        spots.map(&.[0]).uniq.size.should eq 5
        spots.map(&.[1]).uniq.size.should eq 1
        3.downto(0) { |i| ui.reachable_under(ui.app.shapes[i].id, ui.app.shapes[i + 1].id) }
    end

    it "File > New starts over at the first spot" do
        ui = app_in(1200, 900)
        first = at(ui, 0)
        new_shapes(ui, 2)
        ui.menu(:file_new_empty)
        ui.answer("unsaved", :ok) # a fixture app starts unsaved
        ui.app.shapes.size.should eq 1
        at(ui, 0).should eq(first)
    end
end
