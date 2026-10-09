require "./support/embrace_ui"

# Every cell of a pivot answers what column it shows - its name and its column's logical key - and a DEAD cell (an
# empty corner, an empty intersection, a padded sub-header's extra cell, a group with nothing under it) answers "" and
# nil. Pinned literally for the
# shapes a pivot takes, so a dead cell is told apart by asking, never by catching what the routing raises.

private SALES = "Sales\nRegion | Quarter | Amount\nnorth | Q1 | 10\nnorth | Q2 | 5\nsouth | Q2 | 20\n"
private PAD = "Sales\nRegion | Kind | Quarter | Amount\nnorth | A | Q1 | 10\nnorth | A | Q2 | 5\nnorth | B | Q1 | 7\nsouth | B | Q2 | 20\n"
private REF = "Cities\nCity\nGraz\nLinz\nWien\n\nPeople\nName | Home_City\nAl | Graz\nBo | Linz\nCy | Graz\n"

# What every cell answers, row by row: "name/key", a dead cell "/".
private def answers(app : EmbraceApp, shape : ShapeState) : Array(String)
    Fixtures.renderer(app).settle_rendering(app)
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.size
    (0...rows).map { |r| (0...cols).map { |c| "#{adapter.cell_get_name(r, c)}/#{shape.cell_key(r, c)}" }.join(" | ") }
end

private def sales(& : ShapeState ->) : {EmbraceApp, ShapeState}
    app = Fixtures.app(SALES)[0]
    shape = app.shapes.first
    yield shape
    {app, shape}
end

# People's Home refers to Cities, all of whose records are shown: Wien, where nobody lives, is a group of its own
# with nothing in it - a header table with no rows, dead.
private def all_cities(rows, columns, aggregates, filter = false) : {EmbraceApp, ShapeState}
    ui = EmbraceUI.new(Fixtures.app(REF, open: "People")[0])
    shape = ui.shape("People")
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    all = {"People", "Home", "Cities", "(Show all records?)"}
    ui.select_field(shape, *all) unless ui.configurator_selected?(shape, *all)
    Fixtures.pivot(shape, rows, columns, aggregates)
    shape.filter_add(1, Set{"Al".as(Cell)}) if filter
    {ui.app, shape}
end

describe "every cell of a pivot, dead ones included" do
    it "rows, columns and an aggregate" do
        app, shape = sales { |s| Fixtures.pivot(s, ["Region"], ["Quarter"], ["Amount"]) }
        answers(app, shape).should eq(["/ | Quarter/7 | Quarter/7",
                                       "Region/6 | Amount/8 | Amount/8",
                                       "Region/6 | / | Amount/8"]) # south has nothing in Q1
    end

    it "rows and columns, no aggregate: every intersection is dead" do
        app, shape = sales { |s| Fixtures.pivot(s, ["Region"], ["Quarter"]) }
        answers(app, shape).should eq(["/ | Quarter/7 | Quarter/7",
                                       "Region/6 | / | /",
                                       "Region/6 | / | /"])
    end

    it "two row levels, uneven (south has one quarter, north two)" do
        app, shape = sales { |s| Fixtures.pivot(s, ["Region", "Quarter"], [] of String, ["Amount"]) }
        answers(app, shape).should eq(["Region/6 | Quarter/7 | Amount/8"] * 3)
    end

    it "filtered to one region" do
        app, shape = sales do |s|
            Fixtures.pivot(s, ["Region"], ["Quarter"], ["Amount"])
            s.filter_add(1, Set{"north".as(Cell)})
        end
        answers(app, shape).should eq(["/ | Quarter/7 | Quarter/7",
                                       "Region/6 | Amount/8 | Amount/8"])
    end

    it "row levels under a column: a sub-header with fewer rows is padded, and its padding is dead" do
        {["Amount"], [] of String}.each_with_index do |aggregates, i|
            app = Fixtures.app(PAD)[0]
            shape = app.shapes.first
            Fixtures.pivot(shape, {"Region" => 0, "Quarter" => 1}, ["Kind"], aggregates)
            answers(app, shape).should eq(i == 0 ?
                ["/ | Kind/7 | Kind/7 | Kind/7 | Kind/7",
                 "Region/6 | Quarter/8 | Amount/9 | Quarter/8 | Amount/9",
                 "Region/6 | Quarter/8 | Amount/9 | / | /",
                 "Region/6 | / | / | Quarter/8 | Amount/9"] :
                ["/ | Kind/7 | Kind/7 | Kind/7 | Kind/7",
                 "Region/6 | Quarter/8 | / | Quarter/8 | /",
                 "Region/6 | Quarter/8 | / | / | /",
                 "Region/6 | / | / | Quarter/8 | /"])
        end
    end

    it "grouped by a reference whose every record is shown: the empty group's header is dead" do
        app, shape = all_cities(["Home"], [] of String, ["Name"])
        answers(app, shape).should eq(["Home/12 | Name/11", "Home/12 | Name/11", "/ | /"])
    end

    it "the same reference as columns" do
        app, shape = all_cities(["Name"], ["Home"], [] of String)
        answers(app, shape).should eq(["/ | Home/12 | Home/12 | /", "Name/11 | / | / | /", "Name/11 | / | / | /",
                                       "Name/11 | / | / | /"])
    end

    it "the reference over a second row level" do
        app, shape = all_cities(["Home", "Name"], [] of String, [] of String)
        answers(app, shape).should eq(["Name/11 | Home/12 | /", "Name/11 | / | /", "Name/11 | / | /", "Name/11 | / | /",
                                       "Name/11 | Home/12 | /", "Name/11 | / | /", "Name/11 | Home/12 | /",
                                       "Name/11 | / | /", "Name/11 | / | /"])
    end

    it "the reference, filtered to one person" do
        app, shape = all_cities(["Home"], [] of String, ["Name"], filter: true)
        answers(app, shape).should eq(["Home/12 | Name/11", "/ | /", "/ | /"])
    end

    it "the referenced table's joined column with all its records shown (Wien a row of its own, its record undefined)" do
        ui = EmbraceUI.new(Fixtures.app(REF, open: "People")[0])
        shape = ui.shape("People")
        ui.expand(shape, "People", "Home")
        ui.expand(shape, "People", "Home", "Cities")
        city = {"People", "Home", "Cities", "City"}
        ui.select_field(shape, *city) unless ui.configurator_selected?(shape, *city)
        all = {"People", "Home", "Cities", "(Show all records?)"}
        ui.select_field(shape, *all) unless ui.configurator_selected?(shape, *all)
        Fixtures.pivot(shape, ["Home ► Cities:City"], [] of String, ["Name"])
        answers(ui.app, shape).should eq(["Home ► Cities:City/12.6.6 | Name/11"] * 3)
    end
end
