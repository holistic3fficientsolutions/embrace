require "./support/embrace_ui"

# GUARDS ON THE SPEC SUPPORT ITSELF (spec/gui/support/embrace_ui.cr): a helper that resolves a name to
# the wrong widget makes every use-case spec on it pass on the wrong thing, and one that fails
# without saying what is there leaves its author guessing.

private PEOPLE = <<-EOT
    People
    Name | City
    Anna | Graz
    Bert | Linz
    Cleo | Wels
    Dora | Enns
    EOT

# People is reached from Visits twice (inward, through Mother and Father).
private FAMILY = <<-EOT
    People
    Name | Age
    Al | 3

    Visits
    Mother_Name | Father_Name | Day
    Al | Al | Mon
    EOT

describe Fixtures do
    it "reads a configurator row's selection from its box" do
        ui = EmbraceUI.tables("People\nName | Age\nAl | 3\n", open: "People")
        shape = ui.shape("People")
        ui.configurator_selected?(shape, "People", "Age").should be_true
        ui.select_field(shape, "People", "Age")
        ui.configurator_selected?(shape, "People", "Age").should be_false
    end

    it "removes a fixture file once its block is done - also when the block raises" do
        kept = nil.as(String?)
        Fixtures.document_file("people", PEOPLE) { |path| kept = path; File.exists?(path).should be_true }
        File.exists?(kept.not_nil!).should be_false
        expect_raises(Exception, "in the block") do
            Fixtures.document_file("people", PEOPLE) { |path| kept = path; raise "in the block" }
        end
        File.exists?(kept.not_nil!).should be_false
    end

    it "names the fixture's tables when the Shape's table is not among them" do
        expect_raises(ArgumentError, /no table 'Towns' in the fixture; names: .*People/) { Fixtures.app(PEOPLE, open: "Towns") }
    end

    it "arranges a pivot only from fields the field list has, and names them otherwise" do
        shape = Fixtures.app(PEOPLE)[0].shapes.first
        expect_raises(ArgumentError, /no fieldlist fields 'Town'; fields: .*City/) { Fixtures.pivot(shape, ["Town"]) }
    end

    it "refuses a Persons Shape where the picker's second table is not Persons" do
        persistency = Persistency::Default.new
        Fixtures.read_tables(persistency, "Alpha\nA\nx\n\nBeta\nB\ny")
        expect_raises(ArgumentError, /picked 'Beta', not Persons; the picker offers: Alpha, Beta/) { Fixtures.persons_shape(persistency) }
    end

    it "says what a cell finder looked for when the grid has none" do
        persistency, lid = Fixtures.sales
        shape = ShapeState.new("S", persistency, persistency.context.clone, lid)
        shape.update(true)
        expect_raises(ArgumentError, /found no reference data cell among \d+ x \d+ cells/) do
            Fixtures.first_reference_cell(shape.matrix_adapter.not_nil!)
        end
    end

    it "opens the Shape's field list" do
        app = Fixtures.app(PEOPLE)[0]
        renderer = Fixtures.renderer(app)
        list = ->{ app.find("fieldlist_#{app.shapes.first.id}").not_nil!.as(CrymbleUI::TreeNode) }
        list.call.expanded.should be_false # control: it starts collapsed
        Fixtures.open_fieldlist(app, renderer)
        list.call.expanded.should be_true
    end
end

describe EmbraceUI do
    it "refuses a grid cell once a field is in Rows - the grid no longer shows one record per row" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.cell_text(shape, rank: 1, field: "Name").should eq("Anna") # control
        ui.drag ui.fieldlist_field(shape, "People", "City"), onto: ui.rows_zone(shape)
        expect_raises(ArgumentError, /not in the detail layout/) { ui.cell_text(shape, rank: 1, field: "Name") }
    end

    it "refuses a grid cell once a field is in Columns" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.drag ui.fieldlist_field(shape, "People", "City"), onto: ui.columns_zone(shape)
        expect_raises(ArgumentError, /not in the detail layout/) { ui.cell_text(shape, rank: 1, field: "Name") }
    end

    # An even count, so no record sits in the middle where rank and position coincide either way.
    it "finds a record by its Rank, not by its position, when Rank sorts descending" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.click "fl_sort_#{shape.id}_Rank"
        ui.checked?("fl_sort_#{shape.id}_Rank").should be_false # precondition: descending
        ui.cell_text(shape, rank: 1, field: "Name").should eq("Anna")
        ui.cell_text(shape, rank: 4, field: "Name").should eq("Dora")
    end

    it "opens a new Rows level through the zone below the used ones" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.drag ui.fieldlist_field(shape, "People", "City"), onto: ui.new_rows_level(shape)
        ui.fieldlist_section(shape, "People", "City").should eq({:rows, 2})
        ui.fieldlist_section(shape, "People", "Rank").should eq({:rows, 1}) # control
    end

    # One level base for every fieldlist id: the one a user reads in the zone's hover text.
    it "counts zone levels from 1, as the hover text does" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.drag ui.fieldlist_field(shape, "People", "City"), onto: ui.new_rows_level(shape)
        {1, 2}.each { |level| ui.find(ui.rows_zone(shape, level)).hover_text.to_s.should end_with("level #{level}") }
    end

    it "says what the open context menu offers when the asked-for entry is not in it" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.right_click ui.configurator_field(shape, "People", "City")
        expect_raises(ArgumentError, /has no :rename_table; it offers: .*rename_field/) { ui.context_menu :rename_table }
        ui.close_menu
        expect_raises(ArgumentError, /no context menu is open/) { ui.context_menu :rename_field }
    end

    it "names an inward hop by the referencing field - the one the screen draws with ◄" do
        ui = EmbraceUI.tables(FAMILY)
        shape = ui.shape("People")
        ui.expand(shape, "People", "Name")
        %w(Mother Father).each { |via| ui.expand(shape, "People", "Name", inward("Visits", via: via)) }
        %w(Mother Father).each do |via|
            ui.text(ui.configurator_arrow(shape, "People", "Name", inward("Visits", via: via), via)).should eq("◄")
        end
        ui.present?(ui.configurator_arrow(shape, "People", "Name", inward("Visits", via: "Mother"), "Father")).should be_false
    end

    it "lists the valid name paths, inward hops written as a spec writes them, when a path names no row" do
        ui = EmbraceUI.tables(FAMILY)
        shape = ui.shape("People")
        ui.expand(shape, "People", "Name")
        %w(Mother Father).each { |via| ui.expand(shape, "People", "Name", inward("Visits", via: via)) }
        expect_raises(ArgumentError, /no configurator row People > Nme.*\n.*People, Name, inward\("Visits", via: "Mother"\), Day/m) do
            ui.configurator_field(shape, "People", "Nme")
        end
    end

    # Mutation: drop the candidates from the error.
    it "names a pivot cell by the headers along its row and column, and lists the cells for one that does not resolve" do
        ui = EmbraceUI.tables("People\nName | Group | Age\nAl | A | 1\nBo | A | 2\nCy | B | 3")
        shape = ui.shape("People")
        Fixtures.pivot(shape, {"Group" => 0, "Name" => 1}, aggregates: ["Age"])
        Fixtures.refresh(ui.app, ui.renderer, shape)
        ui.pivot_text(shape, rows: ["A", "Bo"], cols: [] of String).should eq("2")
        expect_raises(ArgumentError, /no cell rows: \["A", "Zed"\].*\n.*rows: \["A", "Al"\]/m) do
            ui.pivot_text(shape, rows: ["A", "Zed"], cols: [] of String)
        end
    end

    # Mutation: swap the two buttons.
    it "steps a Shape's history back and forward" do
        ui = EmbraceUI.tables(PEOPLE)
        shape = ui.shape("People")
        ui.shape_menu(shape, :commit)
        tip = shape.current_commit_index
        ui.history shape, :back
        shape.current_commit_index.should eq(tip - 1)
        ui.history shape, :forward
        shape.current_commit_index.should eq(tip)
        expect_raises(ArgumentError, /:back or :forward/) { ui.history shape, :up }
    end
end
