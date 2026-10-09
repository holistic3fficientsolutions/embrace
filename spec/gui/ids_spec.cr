require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# THE LOGICAL KEY OF A COLUMN OF A SHAPE (GUI::Ids.path_key) - what a test addresses a configurator row
# and a fieldlist field by. It must name exactly one column and keep naming it through what a user
# does: rename, deselect and reselect it, commit, rebuild, duplicate the Shape. The configurator
# and the fieldlist reach it from two sides (a tree node, a stable column id) and must agree.
#
# Fixture: People reaches Cities twice (Home, Work - outward) and is reached twice from Visits
# (Mother, Father - inward).

private def label(node) : String
    node.get_display_texts[1]
end

# The configurator row with this label under the row labelled `under` (the nearest one above it at a
# lower level), e.g. row(shape, "Country", under: "Home").
private def row(shape, name : String, under : String? = nil) : Interface::GUI::VHTreeAdapter
    current_under = nil.as(String?)
    found = [] of Interface::GUI::VHTreeAdapter
    Fixtures.tree_rows(shape).each do |node, level|
        current_under = label(node) if under && level == 1
        found << node if label(node) == name && (under.nil? || current_under == under)
    end
    raise "#{found.size} rows '#{name}' under '#{under}'" unless found.size == 1
    found.first
end

private def expand_all(app, renderer, shape)
    3.times do
        target = Fixtures.tree_rows(shape).find { |n, _| n.is_expandable? && n.get_display_texts.join.ends_with?("+") }
        break unless target
        target[0].toggle_expand
        Fixtures.refresh(app, renderer, shape)
    end
end

private def app_with_references : {EmbraceApp, CrymbleUI::Testing::TestRenderer, ShapeState}
    app = Fixtures.app(<<-EOT, open: "People", title: "P")[0]
        Cities
        City | Country
        Rome | Italy

        People
        Name | Home_City | Work_City
        Al | Rome | Rome

        Visits
        Mother_Name | Father_Name | Day
        Al | Al | Mon
    EOT
    renderer = Fixtures.renderer(app)
    shape = app.shapes.first
    %w(Home Work).each do |ref|
        row(shape, ref).toggle_expand
        Fixtures.refresh(app, renderer, shape)
    end
    Fixtures.tree_rows(shape).select { |n, l| l == 2 && n.is_table? && n.is_expandable? }.each do |n, _|
        n.toggle_expand
        Fixtures.refresh(app, renderer, shape)
    end
    {app, renderer, shape}
end

# The fieldlist row showing a name that contains `part` and starts with `prefix`.
private def fl_row(shape, prefix : String, part : String) : Int32
    adapter = shape.fieldlist_adapter.not_nil!
    names = (0...adapter.size).map { |ri| adapter.cell_read({ri, GUI::Widget::FieldlistConstants::ColumnIndices::Name}).to_s }
    matches = names.each_index.select { |ri| names[ri].starts_with?(prefix) && names[ri].includes?(part) }.to_a
    raise "#{matches.size} fieldlist rows '#{prefix}...#{part}' in #{names}" unless matches.size == 1
    matches.first
end

describe GUI::Ids do
    it "keys the root table as root, and a pseudo field by its name" do
        _app, _r, shape = app_with_references
        Fixtures.tree_rows(shape).first[0].key.should eq("root")
        Fixtures.tree_rows(shape).find { |n, l| l == 1 && label(n) == "Rank" }.not_nil![0].key.should eq("Rank")
        Fixtures.tree_rows(shape).find { |n, l| l == 1 && label(n) == "(Show all records?)" }.not_nil![0].key.should eq("ShowAll")
    end

    it "keys one field reached through two references as two columns" do
        _app, _r, shape = app_with_references
        via_home = row(shape, "Country", under: "Home").key
        via_work = row(shape, "Country", under: "Work").key
        via_home.should_not eq(via_work)
        via_home.should start_with(row(shape, "Home").key + ".")
        via_work.should start_with(row(shape, "Work").key + ".")
    end

    it "keys two inward references from one table apart" do
        app, renderer, shape = app_with_references
        row(shape, "Name").toggle_expand
        Fixtures.refresh(app, renderer, shape)
        visits = Fixtures.tree_rows(shape).select { |n, l| l == 2 && label(n) == "Visits" }.map(&.[0])
        visits.size.should eq(2) # precondition: Visits via Mother and via Father
        visits.map(&.key).uniq.size.should eq(2)
    end

    it "gives the fieldlist the configurator's key for every column, both hops included" do
        app, renderer, shape = app_with_references
        %w(Home Work).each do |ref|
            row(shape, "Country", under: ref).toggle_select
            Fixtures.refresh(app, renderer, shape)
        end
        shape.field_key(fl_row(shape, "Home", "Country")).should eq(row(shape, "Country", under: "Home").key)
        shape.field_key(fl_row(shape, "Work", "Country")).should eq(row(shape, "Country", under: "Work").key)
        shape.field_key(fl_row(shape, "Name", "Name")).should eq(row(shape, "Name").key)
        shape.field_key(fl_row(shape, "Rank", "Rank")).should eq("Rank")
    end

    it "keys an unselected configurator row, and keeps the key once it is selected" do
        app, renderer, shape = app_with_references
        before = row(shape, "Country", under: "Work").key
        row(shape, "Country", under: "Work").toggle_select
        Fixtures.refresh(app, renderer, shape)
        row(shape, "Country", under: "Work").key.should eq(before)
        shape.field_key(fl_row(shape, "Work", "Country")).should eq(before)
    end

    it "keeps a column's key through deselect-and-reselect, rename, commit, rebuild and duplicate" do
        app, renderer, shape = app_with_references
        row(shape, "Country", under: "Work").toggle_select
        Fixtures.refresh(app, renderer, shape)
        key = shape.field_key(fl_row(shape, "Work", "Country"))

        2.times do # the column itself off and on: its stable column id changes, its key must not
            row(shape, "Country", under: "Work").toggle_select
            Fixtures.refresh(app, renderer, shape)
        end
        shape.field_key(fl_row(shape, "Work", "Country")).should eq(key)

        country = row(shape, "Country", under: "Work").field_lid.not_nil!
        shape.persistency.contexts.push(shape.context)
        shape.persistency.set_value(MetaFieldLIDs::Names, country, "Nation")
        shape.context = shape.persistency.contexts.pop
        Fixtures.refresh(app, renderer, shape)
        shape.field_key(fl_row(shape, "Work", "Nation")).should eq(key)

        shape.do_commit
        Fixtures.refresh(app, renderer, shape)
        shape.field_key(fl_row(shape, "Work", "Nation")).should eq(key)

        twin = shape.dup_shape("P2")
        app.shapes << twin
        Fixtures.refresh(app, renderer, twin)
        twin.field_key(fl_row(twin, "Work", "Nation")).should eq(key)
    end
end
