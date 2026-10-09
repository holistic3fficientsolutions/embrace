require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# Copying a Shape to the clipboard as TSV.
#
# The clipboard is a PROCESS-GLOBAL that the test renderer installs once
# (`unless Widget.clipboard?`), and CI compiles every gui spec into one binary —
# so without a per-example replacement an "empty clipboard" assertion inherits
# whatever an earlier example copied. Never hold the instance across an example.
private def fresh_clipboard!
  CrymbleUI::Widget.clipboard = CrymbleUI::Testing::TestClipboard.new
end

private def make_app : EmbraceApp
  Fixtures.app(<<-EOT)[0]
      People
      Name | City
      Alice | Boston
      Bob | Munich
  EOT
end

# Menu items are addressable without opening the menu (Menu#find_by_id descends
# @menu_items), which is what lets a spec drive the real user path instead of
# calling the app method directly.
private def click_menu(app : EmbraceApp, id : String)
  app.find(id).not_nil!.as(CrymbleUI::MenuItem).trigger_click
end

private def make_flags_app : EmbraceApp
  Fixtures.app(<<-EOT)[0]
      Flags
      Name | Active
      Alpha | 'true
      Beta | 'false
  EOT
end

private def adapter_of(app : EmbraceApp) : SimpleMatrixAdapter(Cell, BaseCell, FieldlistCell)
  app.shapes.first.matrix_adapter.not_nil!
end

describe "Shape → TSV" do
  it "exports the whole rendered rectangle" do
    fresh_clipboard!
    app = make_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)

    tsv = adapter_of(app).to_tsv
    # Hand-derived, NOT pasted from a run: the detail Shape is [Rank | Name | City]
    # with one row per record, and the Rank column is a row-label header that the
    # full-rectangle rule keeps.
    tsv.should eq("1\tAlice\tBoston\n2\tBob\tMunich")
  end

  # The export must not disturb the change-highlight bookkeeping: copying is a read,
  # and a copy that marks every cell "seen" would suppress the next real edit's
  # highlight. `cell_read` writes @current_values for EVERY cell it touches, so this
  # goes red against a cell_read-based walk and green against a direct read.
  it "does not mutate the adapter's change-tracking state" do
    fresh_clipboard!
    app = make_app
    adapter = adapter_of(app)

    # Deliberately NEVER rendered. Once a frame has run, @current_values already
    # holds every visible cell and a cell_read-based walk would rewrite the SAME
    # strings — the comparison then passes against the very implementation this
    # guards, which is how four earlier versions of this check were worthless.
    # On a virgin adapter the difference is empty-vs-populated and cannot hide.
    adapter.@current_values.should be_empty # instrument check: the premise holds
    adapter.to_tsv
    adapter.@current_values.should be_empty
  end
end

# The two display_string arms the product owner explicitly decided, and which had
# no coverage at all: a Bool must survive a round trip (hence the apostrophe
# literal, which CellHelper.convert parses back), and a reference cell flattens to
# the value it points at.
describe "Shape → TSV fidelity" do
  it "writes a Bool as the 'true literal, so it can come back as a Bool" do
    fresh_clipboard!
    app = make_flags_app
    CrymbleUI::Testing::TestRenderer.new(1200, 800).settle_rendering(app)

    adapter_of(app).to_tsv.should eq("1\tAlpha\t'true\n2\tBeta\t'false")
  end

  it "round-trips a Bool back into persistency as a Bool, not the string \"true\"" do
    fresh_clipboard!
    app = make_flags_app
    CrymbleUI::Testing::TestRenderer.new(1200, 800).settle_rendering(app)

    click_menu(app, "mi_copy_tsv_#{app.shapes.first.id}")
    click_menu(app, "mi_paste_new_table_#{app.shapes.first.id}")

    pasted = app.shapes.last.table_lid.not_nil!
    fields = app.persistency.get_field_lids(pasted)
    record = app.persistency.get_record_lids(pasted).first
    app.persistency.get_value(fields[2], record).should eq(true) # Bool, not "true"
  end

  it "flattens a reference cell to the value it points at — the relation is lost" do
    fresh_clipboard!
    app = Fixtures.app(<<-EOT, open: "People")[0]
        Cities
        City
        Boston

        People
        Name | City_City
        Alice | Boston
    EOT
    Fixtures.renderer(app)

    adapter_of(app).to_tsv.should eq("1\tAlice\tBoston") # the referenced VALUE, not a rank or an object
  end
end

describe "Shape clipboard, driven through the menus" do
  it "copies through the Shape menu item" do
    fresh_clipboard!
    app = make_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)

    click_menu(app, "mi_copy_tsv_#{app.shapes.first.id}")
    CrymbleUI::Widget.clipboard.text.should eq("1\tAlice\tBoston\n2\tBob\tMunich")
  end

  # A new table lands on the branch of the Shape it was created from. The paste used to write on
  # the document's base context - the position as of the last load, never moved after it - so once
  # the Shape had committed, that was a closed commit and the write forked a new branch: the table
  # and its Shape sat on the fork, and the Shape you were in never got the table (2026-09-24).
  it "pastes onto the branch of the Shape it came from, even after that Shape committed" do
    fresh_clipboard!
    app = make_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    shape = app.shapes.first
    shape.do_commit # the Shape moves on; the document's base context does not
    app.request_rebuild
    renderer.settle_rendering(app)
    p = app.persistency
    tips = p.get_ordered_commit_leaves.to_a
    tables = ->{ p.contexts.push(shape.context); n = p.get_record_lids(Persistency::MetaFieldLIDs::TableLastTable).size; p.contexts.pop; n }
    tables_before = tables.call

    CrymbleUI::Widget.clipboard.text = "x\ty\nz\tw"
    click_menu(app, "mi_paste_new_table_#{app.shapes.first.id}")

    p.get_ordered_commit_leaves.to_a.should eq(tips)                  # no new branch
    app.shapes.last.context.current_commit.should eq(shape.context.current_commit)
    tables.call.should eq(tables_before + 1)                          # the Shape you were in has it
  end

  # Was "with no Shape open at all", when paste sat on the File menu. A new table is now a Shape
  # act (it lands on that Shape's branch), and "New Shape" is always available - so the property
  # kept is what the paste produces: a new table, and a new Shape showing exactly the clipboard.
  it "pastes into a NEW table and opens a Shape showing exactly the clipboard" do
    fresh_clipboard!
    app = make_app
    CrymbleUI::Widget.clipboard.text = "x\ty\nz\tw"
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)

    click_menu(app, "mi_paste_new_table_#{app.shapes.first.id}")
    app.shapes.size.should eq(2)
    app.shapes.last.matrix_adapter.not_nil!.to_tsv.should eq("1\tx\ty\n2\tz\tw")
  end

  it "round-trips a Shape through copy and paste" do
    fresh_clipboard!
    app = make_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)

    click_menu(app, "mi_copy_tsv_#{app.shapes.first.id}")
    click_menu(app, "mi_paste_new_table_#{app.shapes.first.id}")
    app.shapes.size.should eq(2)
    # The copied Rank column comes back as ordinary data, so the new Shape's own
    # Rank sits in front of it — a known, recorded consequence of copying the whole
    # rendered rectangle rather than "just the data".
    app.shapes.last.matrix_adapter.not_nil!.to_tsv.should eq("1\t1\tAlice\tBoston\n2\t2\tBob\tMunich")
  end

  it "leaves the document untouched when there is nothing on the clipboard" do
    fresh_clipboard!
    app = make_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    before_tables = app.persistency.get_record_lids(Persistency::MetaFieldLIDs::TableLastTable).size
    before_depth = app.persistency.contexts.size

    click_menu(app, "mi_paste_new_table_#{app.shapes.first.id}")
    app.shapes.size.should eq(1) # nothing added
    app.persistency.get_record_lids(Persistency::MetaFieldLIDs::TableLastTable).size.should eq(before_tables)
    app.persistency.contexts.size.should eq(before_depth) # and no leaked context frame
  end

  it "survives a cell holding a tab, a newline and a quote" do
    fresh_clipboard!
    app = make_app
    hostile = %(a\tb\nc"d)
    CrymbleUI::Widget.clipboard.text = TSV.encode([[hostile, "plain"]])
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)

    click_menu(app, "mi_paste_new_table_#{app.shapes.first.id}")
    table_lid = app.shapes.last.table_lid.not_nil!
    fields = app.persistency.get_field_lids(table_lid)
    record = app.persistency.get_record_lids(table_lid).first
    app.persistency.get_value(fields[0], record).should eq(hostile) # ONE cell, not three
  end
end
