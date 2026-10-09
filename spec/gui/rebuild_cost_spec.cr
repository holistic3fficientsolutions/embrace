require "./support/embrace_ui"

# What a rebuild costs below the caches: each cache keys on what it actually reads. A VirtualTable reads its Shape's
# own context - not whatever context is on top of the stack - so a rebuild where nothing changed rebuilds no table and
# reads nothing from the store; the field tree (Configurator) and the table picker read metadata only, so a cell edit
# leaves them alone - while every change they DO read still reaches them.

private ROWS = "T\nA | B | C\na1 | b1 | c1\na2 | b2 | c2\na3 | b3 | c3\n"

# The delta of a counter around a block.
private macro delta(counter, &block)
    %before = {{counter}}
    {{block.body}}
    {{counter}} - %before
end

private def vt_rebuilds : Int64
    Table::VirtualTable::VirtualTable.rebuild_count
end

private def bulk_reads : Int64
    Persistency::Backend::Memory.bulk_reads
end

private def tree_rebuilds : Int64
    Table::VirtualTable::Configurator.rebuild_count
end

private def picker_rebuilds : Int64
    GUI::Widget::TablePicker.rebuild_count
end

describe "a rebuild where nothing changed" do
    it "rebuilds no table and reads nothing from the store (a context menu opened and closed)" do
        ui = EmbraceUI.tables(ROWS)
        shape = ui.shape("T")
        ui.ui.settle
        reads = 0_i64
        builds = 0
        tables = delta(vt_rebuilds) do
            reads = delta(bulk_reads) do
                builds = delta(ui.app.build_count) do
                    ui.right_click ui.configurator_table(shape, "T")
                    ui.close_menu
                end
            end
        end
        builds.should be > 0 # control: the act rebuilds the app
        tables.should eq(0)
        reads.should eq(0)
    end
end

describe "a cell edit, with one Shape open" do
    it "rebuilds its table once and leaves the field tree and the table picker alone" do
        ui = EmbraceUI.tables(ROWS)
        shape = ui.shape("T")
        ui.type_into_cell(shape, 1, "A", "x") # the first edit; its effects settle here
        trees = pickers = 0_i64
        tables = delta(vt_rebuilds) do
            trees = delta(tree_rebuilds) do
                pickers = delta(picker_rebuilds) { ui.type_into_cell(shape, 2, "A", "y") }
            end
        end
        tables.should eq(1)
        trees.should eq(0)
        pickers.should eq(0)
        ui.cell_text(shape, 2, "A").should eq("y") # control: the edit landed
    end
end

describe "every change the metadata caches read still reaches them" do
    it "a table renamed: the table picker shows the new name" do
        ui = EmbraceUI.tables(ROWS)
        shape = ui.shape("T")
        ui.right_click ui.configurator_table(shape, "T")
        ui.context_menu :rename_table
        ui.dialog(:rename) { |d| d.fill :name, "Things"; d.click :ok }
        ui.ui.text("tablepick_#{shape.id}").should eq("Things")
    end

    it "a field added: the field tree shows it" do
        ui = EmbraceUI.tables(ROWS)
        shape = ui.shape("T")
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) { |d| d.fill :name, "D"; d.click :ok }
        ui.configurator_field(shape, "T", "D")
    end

    it "a record added is a metadata write too: the field tree and the picker rebuild" do
        ui = EmbraceUI.tables(ROWS)
        shape = ui.shape("T")
        pickers = 0_i64
        trees = delta(tree_rebuilds) { pickers = delta(picker_rebuilds) { ui.shape_menu(shape, :add_record) } }
        trees.should be > 0
        pickers.should be > 0
    end

    it "a history step across a field added later: the field tree follows the step, both ways" do
        ui = EmbraceUI.tables(ROWS)
        shape = ui.shape("T")
        ui.shape_menu(shape, :commit)
        ui.click("mx_addf_dlg_#{shape.id}")
        ui.dialog(:add_field) { |d| d.fill :name, "D"; d.click :ok }
        ui.shape_menu(shape, :commit)
        ui.configurator_field(shape, "T", "D") # control
        2.times { shape.navigate_history(-1) }
        ui.app.request_rebuild
        expect_raises(ArgumentError, /no configurator row T > D/) { ui.configurator_field(shape, "T", "D") }
        2.times { shape.navigate_history(1) }
        ui.app.request_rebuild
        ui.configurator_field(shape, "T", "D")
    end
end

describe "two Shapes on different commits" do
    it "each shows its own commit; an edit in one rebuilds each table once" do
        ui = EmbraceUI.tables(ROWS)
        a = ui.shape("T")
        ui.type_into_cell(a, 1, "A", "x"); ui.shape_menu(a, :commit)
        ui.type_into_cell(a, 1, "A", "y"); ui.shape_menu(a, :commit)
        ui.shape_menu(a, :duplicate)
        b = ui.app.shapes.last
        2.times { b.navigate_history(-1) } # back to the commit holding "x"
        ui.app.request_rebuild
        ui.cell_text(b, 1, "A").should eq("x")
        ui.cell_text(a, 1, "A").should eq("y")
        tables = delta(vt_rebuilds) { ui.type_into_cell(a, 2, "A", "z") }
        tables.should eq(2) # A's and B's: the edit's version reaches every table (the global term)
        ui.cell_text(b, 1, "A").should eq("x")
    end
end

private WITH_REFERENCE = <<-EOT
    Cities
    City
    Graz
    Linz

    People
    Name | Home_City
    Al | Graz
    Bo | Linz
    EOT

describe "a reference cell's list" do
    it "lists the records of its Shape's own commit, not those of the commit the document was loaded at" do
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.shape_menu(shape, :commit) # the Shape moves on; the document's base context stays at the load
        p = ui.app.persistency
        cities = p.get_table(MetaFieldLIDs::TableLastTable).find! { |row| p.display_name(row[0].as(TableLID)) == "Cities" }[0].as(TableLID)
        p.with_context(shape.context) do # Wien, added in the Shape's commit
            wien = p.add_record(cities)
            p.set_value(p.get_field_lids(cities)[0], wien, "Wien")
        end
        shape.update(true)
        ui.type_in_cell(shape, 1, "Home", "Wien") # the list opens, filtered
        ui.press("Enter")                          # the pick
        ui.cell_text(shape, 1, "Home").should eq("Wien")
        p.with_context(shape.context) do # a pick, not Graz renamed by the typing
            p.get_record_lids(cities).map { |r| p.get_value(p.get_field_lids(cities)[0], r) }.should eq(["Graz", "Linz", "Wien"])
        end
    end
end
