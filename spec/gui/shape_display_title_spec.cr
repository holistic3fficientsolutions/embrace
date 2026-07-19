require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# ShapeState#display_title — meaningful automatic dynamic shape names, shown in the panel title bar.
# "Shape #N" restores v1's stable per-shape number (the CrymbleUI port dropped it, so every shape
# rendered an identical "Shape"); ", Table (@branch X/N)" is net-new context re-derived live each build.

private def app_with_allocation_table : EmbraceApp
    app = EmbraceApp.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash)
    help << <<-EOT
        Allocation
        Person | Project | Amount
        Alice | Apollo | 10
    EOT
    lid = hash["Allocation"].as(TableLID)
    app.shapes.clear
    app.shapes << ShapeState.new("Shape", app.persistency, app.persistency.context.clone, lid)
    app
end

describe "ShapeState#display_title (automatic dynamic shape names)" do
    it "composes 'Shape #N, Table (@branch X/N)' for a table-pinned shape" do
        app = app_with_allocation_table
        CrymbleUI::Testing::TestRenderer.new(1200, 800).settle_rendering(app)
        shape = app.shapes.first
        expected = "Shape ##{shape.number}, Allocation (@#{shape.current_branch_name} #{shape.current_commit_index + 1}/#{shape.commit_path.size})"
        shape.display_title.should eq(expected)
    end

    it "stamps each shape a distinct, stable number (not positional)" do
        app = app_with_allocation_table
        lid = app.shapes.first.table_lid.not_nil!
        s2 = ShapeState.new("Shape", app.persistency, app.persistency.context.clone, lid)
        s1 = app.shapes.first
        s2.number.should_not eq(s1.number)
        first_number = s1.number
        app.rebuild # numbers are stored, so a rebuild (or an earlier shape closing) never renumbers
        s1.number.should eq(first_number)
    end

    it "keeps a derived view's explicit ▸ title (no auto-decoration)" do
        app = app_with_allocation_table
        lid = app.shapes.first.table_lid.not_nil!
        derived = ShapeState.new("Allocation ▸ diff", app.persistency, app.persistency.context.clone, lid)
        derived.display_title.should eq("Allocation ▸ diff")
    end
end
