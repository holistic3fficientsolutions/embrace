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

# THE TITLE NAMES THE TABLE AS THE SHAPE'S OWN CONTEXT HAS IT, not as the ambient one does.
#
# `table_name` read `display_name` under whatever context happened to be current, and the panel
# build calls `display_title` bare (embrace.cr:437) - so a shape whose context carries a rename
# the ambient context does not titled itself with the ambient name. Measured 2026-09-22: the
# shape's context said "People", the ambient said "Persons", and the panel showed "Persons".
#
# NOT asserted here, because the model does not promise it: stepping back through history does
# NOT rewind a NAME. `path_for_field` resolves meta lids (Names is negative) along the METADATA
# path, while `navigate_history` moves `current_commit` only - so names are deliberately not
# versioned along the data timeline. A shape at an older commit keeps today's names, by design.
describe "ShapeState#display_title and the shape's own context" do
    it "names the table as the shape's context has it, not as the ambient context does" do
        app = EmbraceApp.new
        p = app.persistency
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
            Persons
            Name
            Wanda
        EOT
        table_lid = hash["Persons"].as(TableLID)
        app.shapes.clear
        app.shapes << ShapeState.new("Persons", p, p.context.clone, table_lid)
        shape = app.shapes.first
        shape.do_commit

        # Rename THROUGH THE SHAPE'S context, and keep the context it hands back - the ambient
        # context never sees it. (This is one of the sites that deliberately keeps the popped
        # context, which is why it is not written with `with_context`.)
        p.contexts.push(shape.context)
        p.set_value(MetaFieldLIDs::Names, table_lid, "People")
        shape.context = p.contexts.pop
        shape.do_commit
        shape.update(true)

        p.display_name(table_lid).should eq("Persons")                                  # ambient
        p.with_context(shape.context) { p.display_name(table_lid) }.should eq("People")  # the shape's

        shape.display_title.should contain("People"),
            "the shape titled itself #{shape.display_title.inspect}, which is the name the " \
            "AMBIENT context resolves - its own context has the table as \"People\""
    end
end
