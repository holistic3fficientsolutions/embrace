require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Which CONTEXT the History changes summary acts in. Its own file rather than an
# addition to history_changes_ui_spec.cr: that file is rewritten on the
# `multi-commit-crow` branch, so appending here would have to be merged by hand
# (measured: 131 lines of conflict for 77 lines of spec), while a new file merges
# untouched.

# One table is enough — this is about the context a row's button carries, not
# about the tristate header, which is what the sibling file's two-table fixture
# exists for.
private def make_sales_app : {EmbraceApp, Hash(String, FieldLID | TableLID | RecordLID)}
    app = EmbraceApp.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash)
    help << <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("Sales", app.persistency, app.persistency.context.clone, hash["Sales"].as(TableLID))
    app.request_rebuild
    {app, hash}
end

# The summary's row widgets are held by SimpleMatrixAdapter, not by the widget
# tree, so `app.find` cannot reach them — read them off `active_cells` instead.
# That needs the History node expanded (it is collapsed by default), otherwise the
# matrix is never laid out and `active_cells` is empty.
private def changes_row_widget(app : EmbraceApp, shape : ShapeState, renderer, id : String) : CrymbleUI::Widget?
    tn = app.find("history_#{shape.id}").as(CrymbleUI::TreeNode)
    unless tn.expanded
        tn.expanded = true
        app.request_rebuild
        renderer.settle_rendering(app)
    end
    vm = app.find("changes_#{shape.id}").as(CrymbleUI::VirtualMatrix)
    vm.active_cells.each_value.find { |w| w.id == id }
end

private def read_cell(app : EmbraceApp, shape : ShapeState, field : FieldLID, record : RecordLID)
    app.persistency.contexts.push(shape.context)
    value = app.persistency.get_value(field, record)
    app.persistency.contexts.pop
    value
end

private def write_cell(app : EmbraceApp, shape : ShapeState, field : FieldLID, record : RecordLID, value) : Nil
    app.persistency.contexts.push(shape.context)
    app.persistency.set_value(field, record, value)
    shape.context = app.persistency.contexts.pop
    shape.update(true)
end

describe "History changes summary — '→ Shape'" do
    # The summary rows are computed under the SHAPE's context (build_history_section
    # pushes shape.context before reading changes_in_open_commit). The button ending
    # each row must open that table where the counts came from. It used to clone the
    # APP's base context instead, which a Shape that forked a branch has left behind —
    # so the new Shape landed on a different branch showing different values than the
    # row the user clicked.
    it "opens the table on the clicked Shape's branch, not the app's base context" do
        app, hash = make_sales_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        region = hash["Region"].as(FieldLID)
        north = hash["north"].as(RecordLID)

        # Two commits on Mainline, then navigate back and edit — editing at a closed
        # commit forks a second branch, which is what leaves the app's base context
        # (never advanced by a per-Shape commit) on the OTHER branch.
        shape.do_commit
        write_cell(app, shape, region, north, "mainline-edit")
        shape.do_commit
        shape.navigate_history(-1)
        write_cell(app, shape, region, north, "branch-edit")
        app.request_rebuild
        renderer.settle_rendering(app)

        # Instrument check: the fork really happened and the two contexts really do
        # disagree — otherwise the assertions below could not fail and would pass for
        # the wrong reason. (A plain commit is not enough: a fresh Shape normalizes to
        # its branch tip, so a base context merely lagging on the SAME branch lands on
        # the same commit anyway.)
        shape.branch_names.size.should eq(2)
        shape.commit_leaf_rank.should eq(1)
        read_cell(app, shape, region, north).should eq("branch-edit")
        app.persistency.context.current_commit.should_not eq(shape.context.current_commit)

        sales_lid = hash["Sales"].as(TableLID)
        btn = changes_row_widget(app, shape, renderer, "changes_to_shape_#{shape.id}_#{sales_lid}")
            .not_nil!.as(CrymbleUI::Button)
        before = app.shapes.size
        btn.trigger_click

        app.shapes.size.should eq(before + 1)
        spawned = app.shapes.last
        spawned.commit_leaf_rank.should eq(shape.commit_leaf_rank)
        read_cell(app, spawned, region, north).should eq("branch-edit")
    end
end
