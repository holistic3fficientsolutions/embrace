require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Integration guard for the tester bug: load demo, collapse the Perspective section, expand it again
# → only the Rank column shows, the rest of the body is blank. Root cause + unit guard live in
# crymbleui (spec/rendering/matrix_viewport_stale_after_reexpand_spec.cr): a TreeNode collapse zeros
# the matrix cells' bounds directly, and update_visible_cells' early-exit left them at 0×0 on re-expand
# → the zero-size collect guard dropped the whole body. Asserted via the render-DISPOSITION oracle
# (a dropped cell has a nil disposition), NOT pixels — the headless backend RETAINS pixels where a
# real SFML RenderTexture goes blank, so a pixel assertion is a false green here.

private def make_demo_app : EmbraceApp
  app = EmbraceApp.new
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash)
  help << <<-EOT
      Cities
      City | Country
      Arizona | USA
      Boston | USA
      Mordor | Middle-earth
      Shire | Middle-earth

      Persons
      Person | City_City
      Alan | Boston
      Melanie | Arizona
      Sauron | Mordor
      Samwise | Shire

      Times
      Time
      Former
      Present
      Future

      Projects
      Project
      Law
      Peace
      Survival

      Allocations
      Person_Person | Time_Time | Project_Project | Allocation
      Alan | Present | Law | 100
      Sauron | Former | Peace | 100
      Samwise | Former | Peace | 100
      Melanie | Future | Survival | 100
  EOT
  app.shapes.clear
  app.shapes << ShapeState.new("Shape", app.persistency, app.persistency.context.clone, hash["Allocations"].as(TableLID))
  app.request_rebuild
  app
end

describe "Perspective survives collapse + re-expand of its section" do
  it "re-paints the body cells after collapsing and re-expanding the Perspective" do
    app = make_demo_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    shape = app.shapes.first
    m_id = "matrix_#{shape.id}"
    vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!

    # Collapse + re-expand is layout-only (toggle → mark_needs_layout); render_frame (NOT
    # request_rebuild, which recreates the matrix and masks the bug) applies it via the real pipeline.
    app.find(m_id).not_nil!.as(CrymbleUI::TreeNode).toggle # collapse (zeros the cells)
    renderer.render_frame(app)
    app.find(m_id).not_nil!.as(CrymbleUI::TreeNode).toggle # re-expand
    renderer.render_frame(app)

    # The visible body cells (non-Rank) must have been PAINTED in the re-expand frame — a dropped cell
    # has a nil disposition. Before the fix these were all nil (blank body, only Rank surviving).
    body = vm.active_cells.select { |k, _| k[1] >= 1 }.values
    body.should_not be_empty
    painted = body.count { |cell| !renderer.widget_disposition(cell).nil? }
    painted.should eq(body.size)
  end
end
