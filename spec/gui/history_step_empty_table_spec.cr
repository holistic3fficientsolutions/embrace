require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# A history step back to a commit where the Shape's table has no content collapses its grid. The matrix
# that showed the rows before must not be what is drawn afterwards: it was once measured still holding
# 2 rows x 3 columns and six parented cells after the step - read from a reference to the matrix of the
# previous build, it turned out. What is drawn is what the app's tree reaches, so that is what this checks.
private def reachable(root : CrymbleUI::Widget) : Array(CrymbleUI::Widget)
  out = [] of CrymbleUI::Widget
  stack = [root]
  while w = stack.pop?
    out << w
    w.children.each { |c| stack << c }
  end
  out
end

describe "a history step that empties the Shape's table" do
  it "leaves no matrix of the previous state in the tree" do
    app = Fixtures.app(<<-EOT, title: "N")[0]
        Notes
        Name | Body
        Al | x
        Bo | b
    EOT
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    shape = app.shapes.first
    adapter = shape.matrix_adapter.not_nil!
    vm = adapter.virtual_matrix.not_nil!
    vm.set_cursor_from_cell(Fixtures.cell_showing(adapter, "b"))
    "zz".each_char { |ch| vm.on_text_input(ch) }
    vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
    renderer.settle_rendering(app)
    before = adapter.virtual_matrix.not_nil!
    before.active_cells.size.should be >= 6 # control: the grid showed the rows
    reachable(app.root.not_nil!).any?(&.same?(before)).should be_true # control: the walk sees the grid

    shape.navigate_history(-1)
    app.request_rebuild
    renderer.settle_rendering(app)

    tree = reachable(app.root.not_nil!)
    tree.any?(&.same?(before)).should be_false
    # Nothing in the tree still draws from the table's old adapter, and the Shape has none now.
    tree.none? { |w| w.as?(CrymbleUI::VirtualMatrix).try(&.@adapter).same?(adapter) }.should be_true
    shape.matrix_adapter.should be_nil # control: the step really emptied it
  end
end
