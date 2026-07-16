require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# T-062 regression guard in the REAL embrace tree.
#
# Own-layer widgets (WindowPanel, VirtualMatrix, ...) create their compositing layer
# LAZILY in perform_layout (@x ||= Layer.new), so a reconcile REUSES the carried
# @[Reconcile] layer instead of the constructor making a fresh one that the carried one
# immediately displaces — a displaced layer keeps owner == the live new instance, so
# in_tree? never reaps it and it lingers in Layer.@@all_layers as a stale duplicate.
#
# The invariant: after repeated request_rebuilds the set of ACTIVE layers (registry
# filtered by in_tree?) stays FLAT and DUPLICATE-FREE — active == cached, 0 stale. Under
# the pre-fix constructor-create path this grows a second "panel_…"/"matrix_content_…"
# layer per rebuild (same id, live owner), which both assertions below catch.
private def make_app(data_rows : Int32, num_shapes : Int32) : EmbraceApp
  app = EmbraceApp.new
  persistency = app.persistency
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  rows = (1..data_rows).map { |i| "a#{i} | b#{i} | c#{i}" }.join("\n")
  help << "T\nA | B | C\n#{rows}"
  t_lid = hash["T"].as(TableLID)
  app.shapes.clear
  num_shapes.times { app.shapes << ShapeState.new("T", persistency, persistency.context.clone, t_lid) }
  app.request_rebuild
  app
end

describe "embrace layer-registry hygiene (T-062)" do
  it "keeps active layers flat and duplicate-free across rebuilds (no constructor-layer leak)" do
    app = make_app(20, 2)
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)

    # request_rebuild reconstructs the tree, so the live root changes identity each time —
    # always read Layer.active_layers against the CURRENT app.root.
    baseline = CrymbleUI::Layer.active_layers(app.root.not_nil!).size
    baseline.should be > 0 # sanity: the real tree has own-layer widgets (panels/matrices)

    5.times do
      app.request_rebuild
      renderer.settle_rendering(app)
    end

    active = CrymbleUI::Layer.active_layers(app.root.not_nil!)
    # (1) 0 stale: every live layer id appears exactly once — a displaced constructor
    #     layer keeps owner == the live reconciled instance, so it stays in_tree? and would
    #     surface as a second active entry with the same id.
    active.map(&.id).uniq.size.should eq(active.size)
    # (2) no growth: the active set is stable across reconciles; a per-rebuild leak grows it.
    active.size.should eq(baseline)
  end
end
