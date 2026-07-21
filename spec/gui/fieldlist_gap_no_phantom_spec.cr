require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Tester bug (Issue #3): a Field-list move can leave an aggregate field at level 1 with level 0 EMPTY
# (the field that held aggregate level 0 was moved out to a row header). The pivot then materialized the
# empty level as a phantom NilDeadArea band, so every record spanned TWO rows -- the moved field's old
# sub-row went empty, healed only by a 2x diagonal transpose (which repacks levels). This is real pivot
# DATA (the row count literally doubled), not a stale buffer: fixed in Table::Lazy::Pivot::Hierarchic
# #parse_fieldlist by collapsing empty aggregate levels. Asserted end-to-end via the SHAPE's pivot row
# count -- a symptom (rows), matching a clean reference shape, NOT a mechanism counter.

# Enum members can't be reached via `::` on a local inside a method, so bind them at file scope.
private CI_NAME    = GUI::Widget::FieldlistConstants::ColumnIndices::Name
private CI_CLASS   = GUI::Widget::FieldlistConstants::ColumnIndices::Class
private CI_LEVEL   = GUI::Widget::FieldlistConstants::ColumnIndices::Level
private RC_COLUMN  = GUI::Widget::FieldlistConstants::RowClass::ColumnHeader
private RC_ROW     = GUI::Widget::FieldlistConstants::RowClass::RowHeader
private RC_AGG     = GUI::Widget::FieldlistConstants::RowClass::Aggregate

private def make_alloc_app : {EmbraceApp, Hash(String, FieldLID | TableLID | RecordLID)}
  app = EmbraceApp.new
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash)
  help << <<-EOT
      Persons
      Person
      Alan
      Denny

      Projects
      Project
      Law
      Peace

      Times
      Time
      Former
      Present

      Allocations
      Person_Person | Time_Time | Project_Project | Allocation
      Alan | Present | Law | 100
      Denny | Former | Peace | 100
  EOT
  {app, hash}
end

private def fl_ri(fla, name : String) : Int32
  (0...fla.size).find { |i| fla.cell_read({i, CI_NAME}) == name }.not_nil!
end

# Set a field's pivot class + nesting level (mirrors what a Field-list drag does, without the rank churn).
private def fl_set(fla, name : String, cls, level : Int64)
  ri = fl_ri(fla, name)
  fla.cell_assign({ri, CI_CLASS}, cls)
  fla.cell_assign({ri, CI_LEVEL}, level)
end

private def pivot_rows(app, hash, &) : Int32
  app.shapes.clear
  shape = ShapeState.new("Shape", app.persistency, app.persistency.context.clone, hash["Allocations"].as(TableLID))
  app.shapes << shape
  app.request_rebuild
  renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
  renderer.settle_rendering(app)
  yield shape.fieldlist_adapter.not_nil!
  shape.update(true)
  shape.matrix_userdata_rc.not_nil!.size[0]
end

describe "Field-list aggregate level gap" do
  it "adds no phantom rows to the Perspective (matches a compact-level shape)" do
    app, hash = make_alloc_app

    # GAPPED: the tester's shape -- Time a column header, Person/Project row headers, Allocation the sole
    # aggregate but pushed to level 1 (level 0 vacated) -> the phantom band without the fix.
    gapped = pivot_rows(app, hash) do |fla|
      fl_set(fla, "Time", RC_COLUMN, 0i64)
      fl_set(fla, "Project", RC_ROW, 1i64)
      fl_set(fla, "Person", RC_ROW, 2i64)
      fl_set(fla, "Allocation", RC_AGG, 1i64) # strand the sole aggregate at level 1, level 0 vacated
      # The fieldlist enforces "no left gaps": reading back, the stranded aggregate is densified to level 0
      # (Fieldlist#update). This asserting the FIX end-to-end -- and it can't false-green, since a missing
      # densify would leave it at level 1 (and double the pivot rows below).
      aggs = (0...fla.size).select { |i| fla.cell_read({i, CI_CLASS}) == RC_AGG }
      aggs.map { |i| fla.cell_read({i, CI_LEVEL}).as(Int64) }.should eq([0i64])
    end

    # CLEAN: identical layout, but the aggregate sits compactly at level 0 (what a transpose produces).
    clean = pivot_rows(app, hash) do |fla|
      fl_set(fla, "Time", RC_COLUMN, 0i64)
      fl_set(fla, "Project", RC_ROW, 1i64)
      fl_set(fla, "Person", RC_ROW, 2i64)
      fl_set(fla, "Allocation", RC_AGG, 0i64)
    end

    gapped.should eq(clean) # no doubled/empty sub-rows
  end
end
