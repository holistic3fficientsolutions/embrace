require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# Cell-keyboard ops are embrace-owned, registered as cursor-scoped
# panel shortcuts (^X ^V Ins Del ^U ^T) — no longer a crymble-ui CellAction.
#
# Headless harness: cell shortcuts route through the real ShortcutManager, NOT
# the focus manager (TestRenderer installs no real shortcut manager). So we
# settle once for font + adapter, then install a real ShortcutManager and
# rebuild so the DSL registers the shape-panel shortcuts into it, then fire
# handle_key_event(event, shape_panel) directly — exactly the renderer's last
# routing step after the focused widget declines the key.

private def make_items_app : EmbraceApp
  Fixtures.app(<<-EOT)[0]
      Items
      Name | Tag
      Alpha | x
      Beta |
  EOT
end

# Settle for layout/font, then wire a real ShortcutManager and rebuild so the
# DSL cell shortcuts register into it. Returns {app, adapter, vm, panel}.
private def wire_shortcuts(app : EmbraceApp)
  renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
  renderer.settle_rendering(app)

  sm = CrymbleUI::ShortcutManager.new
  CrymbleUI::Widget.shortcut_manager = sm
  app.build_tree

  shape = app.shapes.first
  adapter = shape.matrix_adapter.not_nil!
  vm = adapter.virtual_matrix.not_nil!
  panel = app.root.not_nil!.find_topmost_panel.not_nil!
  {sm, adapter, vm, panel}
end

private def key_event(code : SF::Keyboard::Key, control : Bool = false, shift : Bool = false) : SF::Event::KeyPressedEvent
  e = SF::Event::KeyPressedEvent.new
  e.control = control
  e.system = false
  e.alt = false
  e.shift = shift
  e.code = code
  e
end

private def find_cell(adapter) : Tuple(Int32, Int32)
  rows, cols = adapter.get_scrollorder
  rows.each do |r|
    cols.each do |c|
      next if adapter.cell_get_header_info({r, c})
      return {r, c} if yield adapter.cell_read({r, c})
    end
  end
  raise "no matching cell"
end

private def header_cell(adapter) : Tuple(Int32, Int32)
  rows, cols = adapter.get_scrollorder
  rows.each do |r|
    cols.each do |c|
      return {r, c} if adapter.cell_get_header_info({r, c})
    end
  end
  raise "no header cell"
end

describe "cell keyboard shortcuts (embrace-owned)" do
  it "Ctrl+T sets the cursor cell to true (restored keyboard shortcut)" do
    sm, adapter, vm, panel = wire_shortcuts(make_items_app)
    rc = find_cell(adapter) { |v| v.to_s == "x" }
    vm.cursor_rc = rc

    sm.handle_key_event(key_event(SF::Keyboard::Key::T, control: true), panel).should be_true
    adapter.cell_read({rc[0], rc[1]}).should eq(true)
  end

  it "Ctrl+U sets the cursor cell to undefined/empty" do
    sm, adapter, vm, panel = wire_shortcuts(make_items_app)
    rc = find_cell(adapter) { |v| v.to_s == "x" }
    vm.cursor_rc = rc

    sm.handle_key_event(key_event(SF::Keyboard::Key::U, control: true), panel).should be_true
    adapter.cell_read({rc[0], rc[1]}).to_s.should eq("")
  end

  # (Ctrl+X / Ctrl+V - the cut/paste wiring - lives in cell_cut_spec, with what ends a cut.)

  it "Ctrl+T on a non-assignable header cell no-ops cleanly (no raise)" do
    sm, adapter, vm, panel = wire_shortcuts(make_items_app)
    hc = header_cell(adapter)
    before = adapter.cell_read({hc[0], hc[1]}).to_s
    vm.cursor_rc = hc

    sm.handle_key_event(key_event(SF::Keyboard::Key::T, control: true), panel).should be_true
    adapter.cell_read({hc[0], hc[1]}).to_s.should eq(before)
  end
end
