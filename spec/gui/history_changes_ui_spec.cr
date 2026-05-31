require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Headless GUI specs for the History section's changes summary.

private def make_multi_table_app : {EmbraceApp, Hash(String, FieldLID | TableLID | RecordLID)}
    # Two tables so the tristate (≥2 change rows) is triggered.
    app = EmbraceApp.new
    persistency = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10

        Persons
        Name
        Alice
    EOT
    sales_lid = hash["Sales"].as(TableLID)
    app.shapes.clear
    ctx = persistency.context.clone
    app.shapes << ShapeState.new("Sales", persistency, ctx, sales_lid)
    app.request_rebuild
    {app, hash}
end

describe "History changes summary — tristate" do
    it "renders the tristate header when ≥2 tables have changes" do
        app, _hash = make_multi_table_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        tri = app.find("changes_check_all_#{shape.id}")
        tri.should_not be_nil
    end

    it "tristate 'commit all' reflects @commit_deferred state: Checked when empty" do
        app, hash = make_multi_table_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        tri = app.find("changes_check_all_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Checked)
    end

    it "tristate click (Checked → Unchecked) defers ALL changed tables for this shape" do
        app, hash = make_multi_table_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        tri = app.find("changes_check_all_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Checked)
        tri.trigger_click
        app.request_rebuild
        renderer.settle_rendering(app)

        # Now every changed table should be in @commit_deferred for this shape
        sales_lid = hash["Sales"].as(TableLID)
        persons_lid = hash["Persons"].as(TableLID)
        app.@commit_deferred.includes?({shape.id, sales_lid}).should be_true
        app.@commit_deferred.includes?({shape.id, persons_lid}).should be_true

        # Tristate should now render as Unchecked
        tri = app.find("changes_check_all_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Unchecked)
    end

    it "tristate click (Unchecked → Checked) clears @commit_deferred for this shape" do
        app, hash = make_multi_table_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        # Defer all changed tables (including Unnamed from do_newfile_empty_impl)
        app.persistency.contexts.push(shape.context)
        all_changed = app.persistency.changes_in_open_commit.keys
        app.persistency.contexts.pop
        all_changed.each { |t| app.@commit_deferred.add({shape.id, t}) }
        app.request_rebuild
        renderer.settle_rendering(app)
        tri = app.find("changes_check_all_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Unchecked)
        tri.trigger_click
        app.request_rebuild
        renderer.settle_rendering(app)

        app.@commit_deferred.any? { |sid, _| sid == shape.id }.should be_false
    end

    it "tristate click (Indeterminate → Checked) clears all for this shape" do
        app, hash = make_multi_table_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        sales_lid = hash["Sales"].as(TableLID)
        # Only one deferred → Indeterminate
        app.@commit_deferred.add({shape.id, sales_lid})
        app.request_rebuild
        renderer.settle_rendering(app)
        tri = app.find("changes_check_all_#{shape.id}").not_nil!.as(CrymbleUI::Checkbox)
        tri.check_state.should eq(CrymbleUI::CheckState::Indeterminate)
        tri.trigger_click
        app.request_rebuild
        renderer.settle_rendering(app)

        # "Commit all" → every row checked → @commit_deferred clear for this shape
        app.@commit_deferred.any? { |sid, _| sid == shape.id }.should be_false
    end
end
