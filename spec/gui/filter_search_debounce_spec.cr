require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# STOPGAP (mitigation): typing in a filter's "search…" box must NOT fire a full-app
# rebuild per keystroke (~82ms freeze — measured). It's debounced: the chip list narrows once, after
# typing pauses. This guards the per-keystroke-rebuild elimination — the felt win. (The timer FIRING
# later isn't asserted: there's no headless scheduler-advance; the "no immediate rebuild" property is
# what removes the freeze, and it's what regresses if someone reverts the debounce to request_rebuild.)
private def make_filtered_app : EmbraceApp
  app = Fixtures.app(<<-EOT)[0]
    T
    A | B
    north | widget
    south | gadget
    east | widget
  EOT
  shape = app.shapes.first
  shape.filter_add(0, Set{"north".as(Cell)}) # activate a filter → the search box appears
  app
end

describe "filter-search debounce" do
  it "a keystroke in the filter search does NOT fire an immediate full rebuild" do
    app = make_filtered_app
    renderer = CrymbleUI::Testing::TestRenderer.new(1400, 900)
    renderer.settle_rendering(app)
    shape = app.shapes.first
    ti = app.find("filter_search_0_#{shape.id}").not_nil!.as(CrymbleUI::TextInput)

    before = app.build_count
    ti.on_text_input('n') # keystroke → on_change → debounce (was: request_rebuild = a full-app rebuild)
    renderer.render_frame(app)
    (app.build_count - before).should eq(0)
  end
end
