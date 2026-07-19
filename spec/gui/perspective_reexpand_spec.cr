require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Regression guard for the tester-reported "Perspective blanks after collapse/re-expand" bug:
# after collapsing and re-expanding the Field list, the Perspective (VirtualMatrix) painted every
# non-Rank field as empty (Rank survived on the sticky ruler layer). The data layer was always
# correct — this was a crymbleui content-Layer reconcile-render bug (a reconciled Layer losing its
# owner and dropping out of the render), fixed by the reconciled-Layer owner re-sync work. This test
# drives the exact reconcile (Field list toggle → Perspective reconcile) and asserts the CONTENT
# layer (non-Rank cells) keeps its ink. It PASSES at current HEAD (the fix is in) and would go RED if
# that reconcile-render fix regressed. Data-level checks can't catch it (widgets keep their values;
# the pixels vanish), so this reads the rendered content-layer backend.

private def make_perspective_app : EmbraceApp
  app = EmbraceApp.new
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash)
  help << <<-EOT
      People
      Name | City | Age
      Alice | Boston | 30
      Bob | Boston | 25
      Carol | Denver | 40
      Dave | Denver | 35
      Eve | Austin | 28
  EOT
  lid = hash["People"].as(TableLID)
  app.shapes.clear
  app.shapes << ShapeState.new("People", app.persistency, app.persistency.context.clone, lid)
  app.request_rebuild
  app
end

# Count "ink" pixels (darker than the light cell background) on the Perspective CONTENT layer —
# the non-Rank data cells. Sampled on a coarse grid for speed. Blank content = near-zero ink.
private def content_ink(shape : ShapeState) : Int32
  vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
  content = vm.layer.not_nil!
  be = content.backend.not_nil!.as(CrymbleUI::Testing::TestRenderBackend)
  count = 0
  y = 0
  while y < be.height
    x = 0
    while x < be.width
      px = be.get_pixel(x, y)
      count += 1 if px && (px.r.to_i + px.g.to_i + px.b.to_i) < 620 # dark text on light bg
      x += 4
    end
    y += 4
  end
  count
end

describe "Perspective survives Field list collapse/re-expand" do
  it "keeps the content cells painted after collapsing and re-expanding the Field list" do
    app = make_perspective_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    shape = app.shapes.first
    fl_id = "fieldlist_#{shape.id}"

    ink_before = content_ink(shape)
    ink_before.should be > 0 # sanity: the perspective paints data initially

    app.find(fl_id).not_nil!.as(CrymbleUI::TreeNode).toggle # collapse
    app.request_rebuild; renderer.settle_rendering(app)
    app.find(fl_id).not_nil!.as(CrymbleUI::TreeNode).toggle # re-expand
    app.request_rebuild; renderer.settle_rendering(app)

    ink_after = content_ink(shape)
    # The bug blanked the content layer → ink_after ≈ 0. Fixed → the content is repainted.
    ink_after.should be >= (ink_before // 2)
  end
end
