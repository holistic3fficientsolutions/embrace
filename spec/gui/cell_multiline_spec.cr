require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Multi-line cell values, end to end in embrace.
#
# The library half is exercised in crymbleui's own suite. What can only be tested HERE is
# that the lever is actually pulled: that embrace turns the opt-in on for the cells a user
# edits, that a break survives the commit path's type conversion, and that it round-trips
# through save/load. A consumer suite running with a flag on but never pressing the chord
# has tested that nothing else broke, not that the feature works.
#
# The authoring examples drive the real matrix (EmbraceApp + settle_rendering +
# set_cursor_from_cell + vm.on_key_down), because the cheaper idiom — calling
# adapter.cell_assign directly — is green before any of this exists and proves nothing about
# the chord, the opt-in, or the routing that carries `alt` to the cell editor.

private def make_notes_app : EmbraceApp
  app = EmbraceApp.new
  persistency = app.persistency
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Notes
      Name | Body
      Alpha | one
      Beta | two
  EOT
  lid = hash["Notes"].as(TableLID)
  app.shapes.clear
  ctx = persistency.context.clone
  app.shapes << ShapeState.new("Notes", persistency, ctx, lid)
  app.request_rebuild
  app
end

private def data_cell(adapter, rows, cols) : Tuple(Int32, Int32)
  rows.each do |r|
    cols.each do |c|
      next if adapter.cell_get_header_info({r, c})
      v = adapter.cell_read({r, c})
      next if v == "" || v.is_a?(ReferenceCell)
      return {r, c}
    end
  end
  raise "no data cell found"
end

describe "multi-line cell values" do
  # core's spec_helper installs NO font, so measure_text reports width 0 and NOTHING can
  # overflow or wrap — every height, line-count and marker claim below would pass by
  # measuring nothing. Installed for this file only, and restored (nil-capable), because the
  # font is global and other core specs are written against the zero-width measurement.
  original_font = CrymbleUI::Widget.font
  before_each { CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new }
  after_each { CrymbleUI::Widget.font = original_font }

  it "measures a width at all (without this, the examples below are vacuous)" do
    CrymbleUI::Widget.measure_text("Alpha", 14.0).width.should be > 0.0
  end

  it "authors a break with Alt+Enter and commits both lines" do
    app = make_notes_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    adapter = app.shapes.first.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    r, c = data_cell(adapter, rows, cols)
    before = adapter.cell_read({r, c}).to_s

    vm = adapter.virtual_matrix.not_nil!
    vm.set_cursor_from_cell({r, c})
    vm.on_key_down(SF::Keyboard::Key::Enter, false, false, true) # Alt+Enter
    vm.on_text_input('X')
    vm.on_key_down(SF::Keyboard::Key::Enter, false, false)       # commit
    app.request_rebuild
    renderer.settle_rendering(app)

    adapter.cell_read({r, c}).should eq("#{before}\nX")
  end

  it "authors a break in an EMPTY cell — the flow a user actually starts with" do
    # An empty assignable cell is not a String yet, so a gate keyed on the current value's
    # type would leave multiline off here: Alt+Enter would commit line 1, re-arm the cell,
    # and the next character would REPLACE it. The user would end up with line 2 alone, with
    # no error and no marker. This is the headline path, so it is pinned.
    app = make_notes_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    adapter = app.shapes.first.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    r, c = data_cell(adapter, rows, cols)
    adapter.cell_assign(r, c, "")
    app.request_rebuild
    renderer.settle_rendering(app)

    vm = adapter.virtual_matrix.not_nil!
    vm.set_cursor_from_cell({r, c})
    vm.on_text_input('A')
    vm.on_key_down(SF::Keyboard::Key::Enter, false, false, true)
    vm.on_text_input('B')
    vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
    app.request_rebuild
    renderer.settle_rendering(app)

    adapter.cell_read({r, c}).should eq("A\nB")
  end

  it "keeps a value carrying a break as TEXT, digits and all" do
    # Crystal's to_i64? tolerates surrounding whitespace, so "42\n" would otherwise commit as
    # Int64 42 and silently drop the break the user just typed.
    CellHelper.convert("42\n").should eq({"42\n"})
    CellHelper.convert("42").should eq({42_i64})
    CellHelper.convert("'true\n").should eq({"'true\n"})
    CellHelper.convert("'true").should eq({true})
  end

  it "survives save and load unchanged" do
    app = make_notes_app
    adapter = app.shapes.first.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    r, c = data_cell(adapter, rows, cols)
    adapter.cell_assign(r, c, "first\nsecond")
    adapter.cell_read({r, c}).should eq("first\nsecond")

    path = File.tempname("multiline", ".embrace")
    begin
      app.save_document(path).should be_true
      reloaded = EmbraceApp.new
      reloaded.load_document(path).should be_true
      # Tables are enumerated through the meta table, the same way debug-helper does.
      tables = reloaded.persistency.get_table(MetaFieldLIDs::TableLastTable).map(&.[0].as(TableLID))
      found = tables.any? do |t|
        reloaded.persistency.get_field_lids(t).any? do |f|
          reloaded.persistency.get_record_lids(t).any? do |rec|
            reloaded.persistency.get_value(f, rec) == "first\nsecond"
          end
        end
      end
      found.should be_true
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "presents a field NAME on one line even when the stored name carries a break" do
    # Reachable without any authoring: an .xlsx header cell wrapped with Alt+Enter is taken
    # verbatim by import, and such a name can already be sitting in a saved document. Once
    # measurement became honest about line count, one of them would make EVERY row of the
    # Configurator tree several times taller — so names are flattened where they are
    # PRESENTED, which also reaches the names already on disk.
    app = make_notes_app
    p = app.persistency
    table = p.get_table(MetaFieldLIDs::TableLastTable).map(&.[0].as(TableLID)).first
    field = p.get_field_lids(table).first
    p.set_value(MetaFieldLIDs::Names, field, "First\nName")

    p.display_name(field).should eq("First Name")
    p.get_value(MetaFieldLIDs::Names, field).should eq("First\nName") # stored data untouched
  end
end
