require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Reproduction spec (TEST mode — NO fixes) for the user report:
#
#   "Wenn man die Feldnamen aus der ersten Tabellenzeile übernimmt, werden die
#    Namen in der 'Field List' erst dann aktualisiert, wenn man dort etwas
#    verschiebt."
#
# i.e. after "Take field names from record", the Field List keeps showing the
# OLD field names until the user drags/moves a field within the Field List.
#
# Root cause (see src/fieldlist.cr): the Field List's Name column is computed
# by a Derived table that re-reads @parent.hyperplane_get_name only when the
# fieldlist's OWN memory (@table_internal: Rank/Class/Level) changes. A field
# RENAME writes persistency's Names meta-field — it never touches
# @table_internal — so the derived Name column is not recomputed. A drag writes
# Class/Level/Rank, bumping @table_internal.version, which is why moving a field
# "fixes" the display.

private def make_data_app : EmbraceApp
  app = EmbraceApp.new
  persistency = app.persistency
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Data
      ColA | ColB
      Person | City
      Alan | Boston
  EOT
  data_lid = hash["Data"].as(TableLID)
  app.shapes.clear
  ctx = persistency.context.clone
  app.shapes << ShapeState.new("Data", persistency, ctx, data_lid)
  app.request_rebuild
  app
end

# Names as the Field List displays them (Rank pseudo-field + user fields).
private def fieldlist_names(shape) : Array(String)
  fa = shape.fieldlist_adapter.not_nil!
  (0...fa.size).map do |ri|
    fa.cell_read({ri, GUI::Widget::FieldlistConstants::ColumnIndices::Name}).to_s
  end
end

private def first_data_cell(adapter, rows, cols) : Tuple(Int32, Int32)
  rows.each do |r|
    cols.each do |c|
      next if adapter.cell_get_header_info({r, c})
      v = adapter.cell_read({r, c})
      next if v == "" || v.is_a?(ReferenceCell)
      return {r, c}
    end
  end
  raise "no data cell"
end

describe "Bug report #2: Field List stale after 'take field names from record'" do
  it "Field List shows the new field names immediately after the rename" do
    app = make_data_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    shape = app.shapes.first
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    r, c = first_data_cell(adapter, rows, cols)

    fieldlist_names(shape).should eq(["Rank", "ColA", "ColB"]) # precondition

    # "Take field names from record": ColA->Person, ColB->City (row consumed).
    adapter.cell_transform_to_name({r, c})
    shape.update(true)
    app.request_rebuild
    renderer.settle_rendering(app)

    # The Field List should reflect the renamed fields right away.
    fieldlist_names(shape).should eq(["Rank", "Person", "City"])
  end

  it "a subsequent Field List move keeps the names correct (no regression)" do
    app = make_data_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    shape = app.shapes.first
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    r, c = first_data_cell(adapter, rows, cols)

    adapter.cell_transform_to_name({r, c})
    shape.update(true)
    app.request_rebuild
    renderer.settle_rendering(app)
    fieldlist_names(shape).should eq(["Rank", "Person", "City"])

    # A Field List memory write (what a drag/move does) must not disturb names.
    fa = shape.fieldlist_adapter.not_nil!
    rank0 = fa.cell_read({0, GUI::Widget::FieldlistConstants::ColumnIndices::Rank})
    fa.cell_assign({0, GUI::Widget::FieldlistConstants::ColumnIndices::Rank}, rank0)
    shape.update(true)
    app.request_rebuild
    renderer.settle_rendering(app)
    fieldlist_names(shape).should eq(["Rank", "Person", "City"])
  end
end
