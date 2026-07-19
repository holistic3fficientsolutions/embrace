require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# T-060: the filter "search…" box is two-way bound (text_input(bind:)) to the per-key Source in
# @filter_search — so the input's cell IS the app's filter-search state. These guard the properties
# that binding creates (shared cell, per-key independence, persistence across rebuild, Escape-undo)
# and that the debounce is preserved (see filter_search_debounce_spec).

private def make_filter_app(*cols : Int32) : EmbraceApp
  app = EmbraceApp.new
  persistency = app.persistency
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
    T
    A | B
    north | widget
    south | gadget
    east | widget
  EOT
  t_lid = hash["T"].as(TableLID)
  app.shapes.clear
  shape = ShapeState.new("T", persistency, persistency.context.clone, t_lid)
  app.shapes << shape
  cols.each { |c| shape.filter_add(c, Set(Cell).new) } # activate a filter → its search box appears
  app.request_rebuild
  app
end

private def settled(app : EmbraceApp) : CrymbleUI::Testing::TestRenderer
  r = CrymbleUI::Testing::TestRenderer.new(1400, 900)
  r.settle_rendering(app)
  r
end

private def search_box(app : EmbraceApp, col : Int32) : CrymbleUI::TextInput
  app.find("filter_search_#{col}_#{app.shapes.first.id}").not_nil!.as(CrymbleUI::TextInput)
end

# The tri "all" checkbox label is "all (N)" with no search, "all (visible/total)" when narrowed —
# a Cell-hash-independent observable of what the search narrowed the chip list to.
private def tri_label(app : EmbraceApp, col : Int32) : String
  app.find("filter_all_#{col}_#{app.shapes.first.id}").not_nil!.as(CrymbleUI::Checkbox).text
end

describe "filter search box — two-way Source binding (bind:)" do
  it "is bound: commit_filter_search shows in the input with no rebuild (shared cell)" do
    app = make_filter_app(0)
    settled(app)
    shape = app.shapes.first
    ti = search_box(app, 0)
    ti.value.should eq("")

    before = app.build_count
    app.commit_filter_search({shape.id, 0}, "nor")

    (app.build_count - before).should eq(0) # no rebuild fired
    ti.value.should eq("nor")               # the input reflects it (RED on old: independent cell → stays "")
  end

  it "keeps per-column search cells independent (no shared-default aliasing)" do
    app = make_filter_app(0, 1)
    settled(app)
    shape = app.shapes.first

    app.commit_filter_search({shape.id, 0}, "nor")

    search_box(app, 0).value.should eq("nor")
    search_box(app, 1).value.should eq("") # column 1's Source is a distinct cell
  end

  it "persists a real keystroke into the shared Source and narrows on the next rebuild" do
    app = make_filter_app(0)
    renderer = settled(app)
    shape = app.shapes.first

    # Column 0's distinct values are the record ranks "1"/"2"/"3"; search "2" → 1 of 3 visible.
    ti = search_box(app, 0)
    ti.on_focus
    ti.on_text_input('2')
    app.request_rebuild
    renderer.settle_rendering(app)

    search_box(app, 0).value.should eq("2") # survived the rebuild (persistent Source, not re-seeded fresh)
    tri_label(app, 0).should eq("all (1/3)") # the typed value reached the narrowing
  end

  it "drops the search cell on filter remove, so a re-added filter starts empty" do
    app = make_filter_app(0)
    renderer = settled(app)
    shape = app.shapes.first

    app.commit_filter_search({shape.id, 0}, "nor")
    app.find("filter_remove_0_#{shape.id}").not_nil!.as(CrymbleUI::Button).trigger_click
    renderer.settle_rendering(app)

    shape.filter_add(0, Set(Cell).new) # re-add the same column
    app.request_rebuild
    renderer.settle_rendering(app)

    search_box(app, 0).value.should eq("") # fresh Source, no resurrected stale search
  end

  it "Escape reverts the search and re-narrows (bind makes it undo, not a no-op)" do
    app = make_filter_app(0)
    renderer = settled(app)
    shape = app.shapes.first

    ti = search_box(app, 0)
    ti.on_focus         # value_on_focus = "" (the current, empty search)
    ti.on_text_input('2') # narrows to 1/3 (shared cell now "2")
    ti.value.should eq("2")

    ti.on_key_down(SF::Keyboard::Key::Escape, false, false) # revert to value_on_focus ("")
    ti.value.should eq("") # the SHARED cell reverted (old no-op Escape would leave @filter_search = "2")

    app.request_rebuild
    renderer.settle_rendering(app)
    tri_label(app, 0).should eq("all (3)") # narrowing followed the revert (no-op Escape → "all (1/3)")
  end
end
