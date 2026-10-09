require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# NEW SHAPE OPENS ON THE BRANCH OF THE SHAPE YOU ARE IN, at that branch's tip.
#
# Wolfgang, 2026-09-25: "New Shape should open on the originating Shape's branch". "New Shape" is an
# app-menu item (^N), so the originating Shape is the frontmost open Shape panel - the one the user
# last clicked into. A new Shape used to seed from the persistency's base context (the position as
# of the last load) and snap to whatever tip get_leaf found from there: with two branches it always
# opened on the same one, wherever the user was working.
#
# The TIP, even when the originating Shape is stepped back in history: a new Shape shows the branch
# as it stands, not the past commit another Shape happens to be looking at.

private def make_app : {EmbraceApp, CrymbleUI::Testing::TestRenderer}
    app = Fixtures.app("T\nName\nAl\nBo", title: "A")[0]
    {app, Fixtures.renderer(app)}
end

private def settle(app, renderer)
    app.request_rebuild
    renderer.settle_rendering(app)
end

private def edit(app, renderer, shape : ShapeState, from : String, to : String)
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    rc = nil
    rows.each { |r| cols.each { |c| rc ||= {r, c} if adapter.cell_read({r, c}).to_s == from } }
    rc = rc.not_nil!
    adapter.cell_assign(rc[0], rc[1], to)
    settle(app, renderer)
end

# Two branches: "X" (commits on top of the start) and "Y" (an edit made after stepping back to the
# start, which auto-branches). Returns the tips in commit_leaves order.
private def two_branches(app, renderer, shape : ShapeState) : Array(CommitLID)
    shape.do_commit
    settle(app, renderer)
    edit(app, renderer, shape, "Al", "X1")
    shape.do_commit
    settle(app, renderer)
    edit(app, renderer, shape, "X1", "X2")
    2.times { shape.navigate_history(-1); settle(app, renderer) }
    edit(app, renderer, shape, "Al", "Y1")
    shape.commit_leaves.size.should eq(2) # precondition: there are two branches to choose between
    shape.commit_leaves
end

private def new_shape(app, renderer) : ShapeState
    app.find("mi_view_new_shape").not_nil!.as(CrymbleUI::MenuItem).trigger_click
    renderer.settle_rendering(app)
    app.shapes.last
end

describe "New Shape (^N)" do
    it "opens on the branch of the Shape you are in, on either branch" do
        app, renderer = make_app
        a = app.shapes.first
        tips = two_branches(app, renderer, a)
        tips.each_index do |branch|
            a.select_branch(branch)
            settle(app, renderer)
            # The previous round's new Shape opened in front; working in A again brings A back.
            app.find(a.id).not_nil!.as(CrymbleUI::WindowPanel).bring_to_front
            new_shape(app, renderer).context.current_commit.should eq(tips[branch])
        end
    end

    it "opens at the branch's tip when the Shape you are in is stepped back in history" do
        app, renderer = make_app
        a = app.shapes.first
        tips = two_branches(app, renderer, a)
        a.select_branch(1)
        settle(app, renderer)
        a.navigate_history(-1)
        settle(app, renderer)
        a.context.current_commit.should_not eq(tips[1]) # precondition: A looks at the past

        new_shape(app, renderer).context.current_commit.should eq(tips[1])
    end

    it "follows the Shape in FRONT when Shapes sit on different branches" do
        app, renderer = make_app
        a = app.shapes.first
        tips = two_branches(app, renderer, a)
        a.select_branch(0)
        settle(app, renderer)
        b = new_shape(app, renderer)
        b.select_branch(1)
        settle(app, renderer)

        app.find(a.id).not_nil!.as(CrymbleUI::WindowPanel).bring_to_front
        new_shape(app, renderer).context.current_commit.should eq(tips[0])
        app.find(b.id).not_nil!.as(CrymbleUI::WindowPanel).bring_to_front
        new_shape(app, renderer).context.current_commit.should eq(tips[1])
    end
end
