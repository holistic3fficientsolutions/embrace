require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/fixtures"

include Persistency

# A FIELD REACHED THROUGH A REFERENCE KEEPS ITS PLACE WHEN A SIBLING REFERENCE CHANGES.
#
# People reaches Cities twice - through Home and through Work - and Country is pulled in through
# both. Put Work's Country in Rows, then deselect HOME's Country: Work's Country fell back to the
# default section. The field list arranges a column by its stable user id, and that id is keyed by
# the column's path through the references; the walk that built the paths let a later sibling hop
# inherit an earlier hop's segments, so Work's path - and id - changed with Home's use (measured
# 2026-09-25: id 5 -> 6, section Rows -> default).

private alias FLC = Table::Lazy::Fieldlist::ColumnIndices

# The Country node reached through `ref` (Home or Work): the Country after that reference's field
# in tree order - picked by its reference, never by position among the Countries.
private def country_via(shape, ref : String) : Interface::GUI::VHTreeAdapter
    under = false
    found = nil.as(Interface::GUI::VHTreeAdapter?)
    Fixtures.tree_rows(shape).each do |n, l|
        under = n.get_display_texts.join.includes?(ref) if l == 1
        found ||= n if under && l >= 3 && n.get_display_texts.join.includes?("Country") && n.is_selectable?
    end
    found || raise "no Country via #{ref}"
end

private ROWS = Table::Lazy::Pivot::Classes::Row.value.to_i64

# The field list row of the Country reached through `ref`.
private def country_row(fl, ref : String) : Int32
    ri = (0...fl.size[0]).find { |i|
        name = fl[[i, FLC::Name.value]].to_s
        name.starts_with?(ref) && name.includes?("Country")
    }
    ri || raise "no #{ref} Country in the field list"
end

private def field_list(shape)
    (shape.fieldlist_data || shape.fieldlist).not_nil!
end

private def section_of(shape, ref : String) : Int64
    fl = field_list(shape)
    fl[[country_row(fl, ref), FLC::Class.value]].as(Int64)
end

# Home's Country and Work's Country both selected; Work's put in Rows.
private def two_hops : {EmbraceApp, CrymbleUI::Testing::TestRenderer, ShapeState}
    app = Fixtures.app(<<-EOT, open: "People", title: "P")[0]
        Cities
        City | Country
        Rome | Italy
        Oslo | Norway

        People
        Name | Home_City | Work_City
        Al | Rome | Oslo
    EOT
    renderer = Fixtures.renderer(app)
    shape = app.shapes.first
    %w(Home Work).each do |ref|
        field = Fixtures.tree_rows(shape).find { |n, l| l == 1 && n.get_display_texts.join.includes?(ref) && n.is_expandable? }
        field.not_nil![0].toggle_expand
        Fixtures.refresh(app, renderer, shape)
    end
    Fixtures.tree_rows(shape).select { |n, l| l >= 2 && n.is_table? && n.is_expandable? }.each do |n, _|
        n.toggle_expand
        Fixtures.refresh(app, renderer, shape)
    end
    %w(Home Work).each do |ref|
        country_via(shape, ref).toggle_select
        Fixtures.refresh(app, renderer, shape)
    end
    put_in_rows(app, renderer, shape, "Work")
    {app, renderer, shape}
end

# SETUP only - the field list's own section value, written directly. The symptom under test comes
# from a user action (a deselect in the configurator), not from this write.
private def put_in_rows(app, renderer, shape, ref : String) : Nil
    fl = field_list(shape)
    fl[[country_row(fl, ref), FLC::Class.value]] = ROWS
    Fixtures.refresh(app, renderer, shape)
end

describe "a field reached through a reference" do
    it "keeps its section when a sibling reference's field is deselected" do
        app, renderer, shape = two_hops
        section_of(shape, "Work").should eq(ROWS) # control: it is in Rows
        country_via(shape, "Home").toggle_select  # Home's Country off
        Fixtures.refresh(app, renderer, shape)
        section_of(shape, "Work").should eq(ROWS)
    end

    it "keeps it when that sibling's field is switched off and on again" do
        app, renderer, shape = two_hops
        2.times do
            country_via(shape, "Home").toggle_select
            Fixtures.refresh(app, renderer, shape)
        end
        section_of(shape, "Work").should eq(ROWS)
    end

    # Control: the EARLIER sibling was never affected - green before and after the fix.
    it "leaves the earlier reference's field alone when the later one's is deselected" do
        app, renderer, shape = two_hops
        put_in_rows(app, renderer, shape, "Home")
        country_via(shape, "Work").toggle_select
        Fixtures.refresh(app, renderer, shape)
        section_of(shape, "Home").should eq(ROWS)
    end
end
