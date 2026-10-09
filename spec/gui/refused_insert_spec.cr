require "./support/embrace_ui"

# An Insert the data refuses leaves the Shape where it was. Here the Shape shows a column reached through a
# reference (People > Home > Cities > City): a new record cannot have a City there, so the Insert is refused - after
# it had already opened a commit from the old one the Shape was looking at. The refusal must take that commit back
# with everything else; it once left the Shape positioned on the erased commit, and every later rebuild failed.

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

private CITY = {"People", "Home", "Cities", "City"}

# The People Shape showing City through Home, two commits made and one step back: an OLD (closed) commit - the one
# holding both edits; a write there opens a new commit.
private def on_an_old_commit : {EmbraceUI, ShapeState}
    ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
    shape = ui.shape("People")
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    ui.select_field(shape, *CITY) unless ui.configurator_selected?(shape, *CITY)
    ui.type_into_cell(shape, 1, "Name", "Ann"); ui.shape_menu(shape, :commit)
    ui.type_into_cell(shape, 2, "Name", "Ben"); ui.shape_menu(shape, :commit)
    shape.navigate_history(-1)
    ui.app.request_rebuild
    {ui, shape}
end

describe "an Insert the data refuses, on an old commit" do
    it "through the Ins key leaves the Shape on its commit, showing it" do
        ui, shape = on_an_old_commit
        commit = shape.context.current_commit
        ui.cell_text(shape, 2, "Name").should eq("Ben") # control: the grid shows that commit
        ui.insert_record(shape, 1, CITY)
        shape.context.current_commit.should eq(commit)
        ui.cell_text(shape, 2, "Name").should eq("Ben") # the grid reads its commit; a rebuild raises nothing
    end

    it "through the context menu says why, and leaves the Shape on its commit" do
        ui, shape = on_an_old_commit
        commit = shape.context.current_commit
        ui.context_menu_on(shape, 1, CITY)
        ui.expect_reported("Cannot assign to a non-existant record") { ui.context_menu :insert_records }
        shape.context.current_commit.should eq(commit)
        ui.cell_text(shape, 2, "Name").should eq("Ben")
    end
end

# After a refusal no cache meets a number it has seen before for other contents: with People's "(Show all
# records?)" on, a record added next shows.
describe "a record added after a refused Insert" do
    it "shows" do
        ui, shape = on_an_old_commit
        ui.select_field(shape, "People", "(Show all records?)")
        ui.ui.settle
        ui.configurator_selected?(shape, "People", "(Show all records?)").should be_true # control
        rows = shape.matrix_adapter.not_nil!.size[0]
        ui.insert_record(shape, 1, CITY)
        shape.matrix_adapter.not_nil!.size[0].should eq(rows) # control: refused, nothing added
        ui.shape_menu(shape, :add_record)
        ui.ui.settle
        shape.matrix_adapter.not_nil!.size[0].should eq(rows + 1)
    end
end
