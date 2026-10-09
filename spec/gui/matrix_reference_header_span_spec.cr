require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# Regression (tut-14): a merged row-header cell must render at its full spanned
# height. VALUE headers (TextInput) always did; REFERENCE headers (ComboBox,
# from a factored-out field) were capped at ~2 rows, leaving a gap for groups
# with >=3 records. Both must now fill.
#
# Row hierarchy: Name(L0) -> Project(L1) -> ID(L2, one leaf per record).
# Groups of sizes 1..4 so we can compare span-1 vs span-3 header heights.

private def make_value_app : EmbraceApp
  Fixtures.app(<<-EOT, title: "S")[0]
      Tasks
      Name | Project | ID
      Alice | Alpha | 1
      Alice | Beta | 2
      Alice | Beta | 3
      Bob | Gamma | 4
      Bob | Gamma | 5
      Bob | Gamma | 6
      Bob | Delta | 7
      Bob | Delta | 8
      Bob | Delta | 9
      Bob | Delta | 10
  EOT
end

private def make_ref_app : EmbraceApp
  Fixtures.app(<<-EOT, open: "Base", title: "S")[0]
      Projects
      Project
      Alpha
      Beta
      Gamma
      Delta

      Base
      Name | Project_Project | ID
      Alice | Alpha | 1
      Alice | Beta | 2
      Alice | Beta | 3
      Bob | Gamma | 4
      Bob | Gamma | 5
      Bob | Gamma | 6
      Bob | Delta | 7
      Bob | Delta | 8
      Bob | Delta | 9
      Bob | Delta | 10
  EOT
end

# {span => live VirtualMatrix widget height} for each distinct Project (L1) group.
private def project_header_heights(app : EmbraceApp) : Hash(Int32, Float64)
  shape = app.shapes.first
  Fixtures.pivot(shape, {"Name" => 0, "Project" => 1, "ID" => 2})
  renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
  renderer.settle_rendering(app)
  adapter = shape.matrix_adapter.not_nil!
  vm = adapter.virtual_matrix.not_nil!
  rows, cols = adapter.get_scrollorder
  result = {} of Int32 => Float64
  seen = Set(Int32).new
  rows.each do |r|
    cols.each do |c|
      hi = adapter.cell_get_header_info({r, c})
      next unless hi && hi[0] && hi[1] == 1
      bb = adapter.cell_get_bounding_box({r, c})
      next if seen.includes?(bb[0][0])
      seen << bb[0][0]
      span = bb[1][0] - bb[0][0] + 1
      if w = vm.active_cells[{bb[0][0], bb[0][1]}]?
        result[span] = w.bounds.height
      end
    end
  end
  result
end

describe "merged row-header cells fill their spanned height (tut-14)" do
  it "VALUE headers: span-3 is ~3x a span-1 header" do
    h = project_header_heights(make_value_app)
    h.has_key?(1).should be_true
    h.has_key?(3).should be_true
    h[3].should be > h[1] * 2.5
    h[4].should be > h[3]
  end

  it "REFERENCE headers: span-3 fills too (regression — was capped at ~2 rows)" do
    h = project_header_heights(make_ref_app)
    h.has_key?(1).should be_true
    h.has_key?(3).should be_true
    h[3].should be > h[1] * 2.5
    h[4].should be > h[3]
  end
end
