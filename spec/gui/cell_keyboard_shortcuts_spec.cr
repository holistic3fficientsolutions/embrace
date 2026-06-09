require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# T-006: cell-keyboard ops are embrace-owned, registered as cursor-scoped
# panel shortcuts (^X ^V Ins Del ^U ^T) — no longer a crymble-ui CellAction.
#
# Headless harness: cell shortcuts route through the real ShortcutManager, NOT
# the focus manager (TestRenderer installs no real shortcut manager). So we
# settle once for font + adapter, then install a real ShortcutManager and
# rebuild so the DSL registers the shape-panel shortcuts into it, then fire
# handle_key_event(event, shape_panel) directly — exactly the renderer's last
# routing step after the focused widget declines the key.

private def make_items_app : EmbraceApp
  app = EmbraceApp.new
  persistency = app.persistency
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Items
      Name | Tag
      Alpha | x
      Beta |
  EOT
  items_lid = hash["Items"].as(TableLID)
  app.shapes.clear
  ctx = persistency.context.clone
  app.shapes << ShapeState.new("Items", persistency, ctx, items_lid)
  app.request_rebuild
  app
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

describe "T-006 cell keyboard shortcuts (embrace-owned)" do
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

  # Ctrl+X arms the cut (highlights drag_source_cell); Ctrl+V consumes it,
  # firing cell_move on the cursor target. We assert the wiring T-006 owns —
  # the cut/paste state machine — not cell_move's relational re-clustering
  # semantics (pre-existing, unchanged by this task).
  it "Ctrl+X arms the cut and Ctrl+V consumes it (cut/paste wiring)" do
    sm, adapter, vm, panel = wire_shortcuts(make_items_app)
    source = find_cell(adapter) { |v| v.to_s == "x" }
    target = find_cell(adapter) { |v| v.to_s == "" }

    vm.cursor_rc = source
    sm.handle_key_event(key_event(SF::Keyboard::Key::X, control: true), panel).should be_true
    vm.drag_source_cell.should eq(source) # cut armed: highlight on the source

    vm.cursor_rc = target
    sm.handle_key_event(key_event(SF::Keyboard::Key::V, control: true), panel).should be_true
    vm.drag_source_cell.should be_nil # cut consumed by the paste
  end

  it "Ctrl+T on a non-assignable header cell no-ops cleanly (no raise)" do
    sm, adapter, vm, panel = wire_shortcuts(make_items_app)
    hc = header_cell(adapter)
    before = adapter.cell_read({hc[0], hc[1]}).to_s
    vm.cursor_rc = hc

    sm.handle_key_event(key_event(SF::Keyboard::Key::T, control: true), panel).should be_true
    adapter.cell_read({hc[0], hc[1]}).to_s.should eq(before)
  end
end
