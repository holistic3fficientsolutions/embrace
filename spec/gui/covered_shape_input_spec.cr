require "./support/embrace_ui"

# TYPING INTO A SHAPE THAT IS NOT IN FRONT. With two Shapes open, the back one's grid sits covered by the
# front one; a cell edit there once raised "no proxy target" and lost the keystroke - crymble-ui culled the
# covered grid's paint and with it the flush of its rebuilt cells, while the input barrier came down
# anyway. Reached by a spec typing into the back Shape, and by a user in one batch of real events.

private K = CrymbleUI::Testing::Keys

private PEOPLE = <<-EOT
    People
    Name | Age
    Al | 1
    Bo | 2
    EOT

describe "typing into a Shape behind another" do
  it "stores the value typed into the back Shape" do
    ui = EmbraceUI.new(Fixtures.app(PEOPLE, shapes: 2)[0])
    back = ui.app.shapes.first
    ui.type_into_cell(back, 2, "Age", "5")
    ui.cell_text(back, 2, "Age").should eq("5")
  end

  # The same as a user does it, in one batch: the back Shape's title bar, its cell, the digits, Enter -
  # no frame in between.
  it "stores a click and the typing after it, in one batch of real events" do
    ui = EmbraceUI.new(Fixtures.app(PEOPLE, shapes: 2)[0])
    back = ui.app.shapes.first
    grid = ui.find("matrix_grid_#{back.id}").as(CrymbleUI::VirtualMatrix)
    panel = grid.parent
    while panel && !panel.is_a?(CrymbleUI::WindowPanel)
      panel = panel.parent
    end
    title = panel.not_nil!.viewport_bounds
    ui.cell_text(back, 2, "Age") # brings (Rank 2, Age) into view, the cursor on it: where the click lands
    grid = ui.find("matrix_grid_#{back.id}").as(CrymbleUI::VirtualMatrix)
    cell = grid.active_cells[ui.ui.cursor("matrix_grid_#{back.id}")].viewport_bounds
    ui.renderer.deliver(ui.app, K.click_at(title.x.to_i + 40, title.y.to_i + 8) +
                                K.click_at(cell.x.to_i + 4, cell.y.to_i + 4) +
                                K.typed("7") + K.tap(SF::Keyboard::Key::Enter))
    ui.cell_text(back, 2, "Age").should eq("7")
  end
end
