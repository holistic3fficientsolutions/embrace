require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# MEASUREMENT (not a guard): quantify the cost of ONE full-app request_rebuild.
# Every hot-path rebuild (filter search = per keystroke, cell data entry = per
# committed cell) re-runs build() from scratch, which reconstructs the WHOLE
# widget tree of every open shape. This prints widgets-constructed-per-rebuild
# scaled by data rows and shape count, so the per-event cost can be ranked
# against the crymbleui per-frame walk findings. Frequency (per keystroke /
# per cell) is structural — see EmbraceApp#debounce_filter_search (filter search →
# request_rebuild once typing pauses) and the adapter's on_data_changed → request_rebuild
# set in EmbraceApp#build_shape_panel.

private def count_widgets(w : CrymbleUI::Widget) : Int32
  n = 1
  w.children.each { |c| n += count_widgets(c) }
  n
end

describe "embrace rebuild cost audit" do
  it "prints widgets-per-rebuild scaling with rows and shapes" do
    verbose = !ENV["SPEC_VERBOSE"]?.nil? # measurement output; silent unless asked for
    puts "\n=== embrace full-rebuild cost (widgets reconstructed per request_rebuild) ===" if verbose
    totals = {} of {Int32, Int32} => Int32
    [{5, 1}, {20, 1}, {5, 2}, {20, 2}, {50, 1}].each do |cfg|
      rows, shapes = cfg
      app = Fixtures.generated_app(rows: rows, shapes: shapes)
      renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
      renderer.settle_rendering(app)
      total = count_widgets(app.root.not_nil!)
      puts "  rows=#{rows} shapes=#{shapes} -> build_count=#{app.build_count} widgets_per_tree=#{total}" if verbose
      totals[cfg] = total
    end
    totals[{5, 2}].should be > totals[{5, 1}] # the count sees a second Shape - the instrument measures something
  end

  it "one request_rebuild = one full build() reconstructing the whole tree (the per-event cost)" do
    app = Fixtures.generated_app(rows: 20, shapes: 1)
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    before = app.build_count
    app.request_rebuild
    renderer.render_frame(app)
    widgets = count_widgets(app.root.not_nil!)
    puts "\n  one request_rebuild -> #{app.build_count - before} build() reconstructing #{widgets} widgets" if !ENV["SPEC_VERBOSE"]?.nil?
    # Filter search fires this once typing pauses (debounce_filter_search); cell entry per
    # committed cell (on_data_changed) — so the per-event cost is one full build() of this magnitude.
    (app.build_count - before).should eq 1
  end
end
