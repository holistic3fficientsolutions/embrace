require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Reproduction specs (TEST mode — NO fixes) for the user report:
#
#   "Hab versucht, nach dem Tutorial ein 'true einzugeben und dann per Space
#    zu toggeln. Die Umwandlung in einen Bool scheint aber nicht geklappt zu
#    haben. Bei Strings hatte ich auch Probleme mit Spaces."
#
# Context from the docs:
#   * doc/tutorials.csv #2 promises: "direct entering, space for toggling bools".
#   * doc/concepts/01-tables-fields-records.md: typing `'true` enters the Bool
#     literal `true` (parsed by CellHelper.convert in src/gui/cell.cr).
#
# Two independent defects reproduced below.

private def make_flags_app : EmbraceApp
  app = EmbraceApp.new
  persistency = app.persistency
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Flags
      Name | Active
      Alpha | one
      Beta | two
  EOT
  flags_lid = hash["Flags"].as(TableLID)
  app.shapes.clear
  ctx = persistency.context.clone
  app.shapes << ShapeState.new("Flags", persistency, ctx, flags_lid)
  app.request_rebuild
  app
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
  raise "no data cell found"
end

describe "Bug report #1: 'true + Space toggle + strings with spaces" do
  # ---------------------------------------------------------------------------
  # Part A — "per Space zu toggeln ... nicht geklappt"
  #
  # Tutorial #2 promises Space toggles a Bool. As in the pre-crymbleui ImGui
  # build, a Bool cell renders as a Checkbox; the cursor cell's checkbox becomes
  # the matrix proxy, so a Space keypress is forwarded to Checkbox#trigger_click,
  # which flips the value (the paired TextEntered(' ') is a no-op on a checkbox).
  # ---------------------------------------------------------------------------
  it "Space on a Bool cell toggles it true -> false (tutorial #2)" do
    app = make_flags_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    adapter = app.shapes.first.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    r, c = first_data_cell(adapter, rows, cols)

    # Enter a Bool via the documented apostrophe syntax.
    adapter.cell_assign(r, c, "'true")
    app.request_rebuild
    renderer.settle_rendering(app)
    adapter.cell_read({r, c}).should eq(true) # precondition: it is a Bool
    # …and it renders as a Checkbox (not free-text), as in the ImGui build.
    adapter.cell_paint(r, c).should be_a(CrymbleUI::Checkbox)

    vm = adapter.virtual_matrix.not_nil!
    vm.set_cursor_from_cell({r, c}) # checkbox of the cursor cell becomes the proxy
    # A spacebar press delivers BOTH a KeyPressed(Space) and a TextEntered(' ');
    # mirror the real event pair (the ' ' must be harmless on a checkbox).
    vm.on_key_down(SF::Keyboard::Key::Space, false, false)
    vm.on_text_input(' ')
    app.request_rebuild
    renderer.settle_rendering(app)

    # Promised behaviour: the Bool toggled to false.
    adapter.cell_read({r, c}).should eq(false)
  end

  # ---------------------------------------------------------------------------
  # Part B — "Die Umwandlung in einen Bool ... nicht geklappt" /
  #          "Bei Strings hatte ich auch Probleme mit Spaces"
  #
  # CellHelper.convert recognises the Bool/nil literals only by EXACT string
  # match (`value == "'true"`). A single stray leading or trailing space — easy
  # to type, and invisible afterwards — defeats the match, so the value silently
  # stays a String instead of becoming the intended Bool. That is precisely the
  # "spaces broke my Bool / my string" symptom from the report.
  #
  # (GUI text entry of spaces inside strings is fine — verified separately — so
  #  the defect lives in convert(), not in the crymbleui input path.)
  # ---------------------------------------------------------------------------
  it "convert('true) is the Bool true (control)" do
    CellHelper.convert("'true").should eq({true})
  end

  it "convert with a TRAILING space still yields the Bool true" do
    CellHelper.convert("'true ").should eq({true})
  end

  it "convert with a LEADING space still yields the Bool true" do
    CellHelper.convert(" 'true").should eq({true})
  end

  it "convert('false / 'nil) tolerate surrounding whitespace too" do
    CellHelper.convert("'false ").should eq({false})
    CellHelper.convert(" 'nil").should eq({nil})
  end
end
