require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "./support/embrace_ui"

include Persistency

# A Field-list move sequence that UN-MERGES the Perspective's first column (c1). On the demo's Allocations
# Shape: Time -> Columns; Project -> Rows (below Rank); Person -> Rows (below Project); Rank -> Unused; then
# Project -> Rows below Person. Before the last move c1 is Project with five 2-row merges
# (Arts/Healing/Law/Peace/Survival); after it c1 is Person, every cell one row - and every field sits where it
# was dropped.
#
# History. This file guarded the stale separator bands this sequence left in c1 (d7a61f0f, 2026-07-21: the
# ShapeState#update gate missed the fieldlist's own version, so the drop never announced the change and the
# retained buffer kept the old cell's fill in the bands the un-merge vacated) by reading those band pixels in the
# matrix's content layer. That check was removed on 2026-09-26, because it read a layer c1 no longer paints in:
# since same-level row headers became sticky (8cfd3db5) the headers paint in the STICKY column layer, which is
# built fresh on every rebuild. Measured the same day: the bands in the retained content layer have two
# independent clears - the gate's announce and crymble-ui's full clear of a layer re-rendered after a layout
# change - and only with both removed (and the headers forced back into the content layer) do the stale bands
# return. Removing the gate's fieldlist term alone turns this file RED only in a -Dverify_bounds build
# (crymble-ui's MatrixAdapter contract check fires on the sequence's earlier moves, which change the row/column
# count); a normal build heals it and stays green.

private CI_NAME  = GUI::Widget::FieldlistConstants::ColumnIndices::Name
private CI_CLASS = GUI::Widget::FieldlistConstants::ColumnIndices::Class
private CI_RANK  = GUI::Widget::FieldlistConstants::ColumnIndices::Rank
private RC_COL   = GUI::Widget::FieldlistConstants::RowClass::ColumnHeader
private RC_ROW   = GUI::Widget::FieldlistConstants::RowClass::RowHeader
private RC_AGG   = GUI::Widget::FieldlistConstants::RowClass::Aggregate
private RC_FREE  = GUI::Widget::FieldlistConstants::RowClass::Unused

private def make_demo_app : EmbraceApp
    Fixtures.app(<<-EOT, open: "Allocations")[0]
        Projects
        Project
        Arts
        Autonomy
        Curiosity
        Healing
        Justice
        Law
        Loyality
        Peace
        Suppression
        Survival

        Times
        Time
        Former
        Future
        Present

        Persons
        Person
        Alan
        Amanita
        Denny
        Helen
        Jared
        Jezelia
        Kaden
        Max
        Melanie
        Rafferty
        Riley
        Samwise
        Sauron
        Wanda
        Will

        Allocations
        Person_Person | Time_Time | Project_Project | Allocation
        Alan | Present | Law | 100
        Denny | Present | Law | 100
        Sauron | Former | Suppression | 100
        Samwise | Former | Peace | 100
        Wanda | Future | Peace | 100
        Melanie | Future | Survival | 100
        Jared | Future | Survival | 100
        Jezelia | Future | Autonomy | 100
        Rafferty | Future | Curiosity | 100
        Kaden | Future | Loyality | 100
        Max | Present | Healing | 100
        Helen | Present | Healing | 100
        Will | Present | Justice | 100
        Riley | Present | Arts | 100
        Amanita | Present | Arts | 100
    EOT
end

# One real Field-list drag-drop per step, through the Driver: the field's own draggable onto the
# section's append zone (fl_zone_ - the zone a user drops on at the end of a section).
private def run_move_sequence(ui : EmbraceUI, &between : ->)
    app = ui.app
    shape = app.shapes.first
    Fixtures.open_fieldlist(app, ui.renderer)

    ui.drag ui.fieldlist_field(shape, "Allocations", "Time"), onto: ui.columns_zone(shape)
    ui.drag ui.fieldlist_field(shape, "Allocations", "Project"), onto: ui.rows_zone(shape)
    ui.drag ui.fieldlist_field(shape, "Allocations", "Person"), onto: ui.rows_zone(shape)
    ui.drag ui.fieldlist_field(shape, "Allocations", "Rank"), onto: ui.unused_zone(shape)
    between.call
    ui.drag ui.fieldlist_field(shape, "Allocations", "Project"), onto: ui.rows_zone(shape)
end

private def assert_final_config(app : EmbraceApp)
    adapter = app.shapes.first.fieldlist_adapter.not_nil!
    state = (0...adapter.size).map do |ri|
        {adapter.cell_read({ri, CI_NAME}).to_s,
         adapter.cell_read({ri, CI_CLASS}),
         adapter.cell_read({ri, CI_RANK}).as(Int64)}
    end.to_h { |name, cls, rank| {name, {cls, rank}} }
    state["Rank"][0].should eq(RC_FREE)
    state["Time"][0].should eq(RC_COL)
    state["Person"][0].should eq(RC_ROW)
    state["Project"][0].should eq(RC_ROW)
    state["Allocation"][0].should eq(RC_AGG)
    (state["Person"][1] < state["Project"][1]).should be_true # Person ABOVE Project
end

describe "Field-list move that un-merges the first column" do
    around_all do |example|
        ENV["EMBRACE_SHAPE_PANEL_WIDTH"] = "900"
        ENV["EMBRACE_SHAPE_PANEL_HEIGHT"] = "700"
        example.run
        ENV.delete("EMBRACE_SHAPE_PANEL_WIDTH")
        ENV.delete("EMBRACE_SHAPE_PANEL_HEIGHT")
    end

    it "un-merges c1 and lands every field where it was dropped" do
        app = make_demo_app
        ui = EmbraceUI.new(app, 1600, 1000)
        shape = app.shapes.first

        # Rows of the 2-row merged c1 cells BEFORE the final move (a cell taller than one 20px row), and the
        # height of a one-row cell.
        merged_anchors = [] of Int32
        singleton_h = 0.0
        run_move_sequence(ui) do
            vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
            vm.active_cells.each do |key, w|
                next unless key[1] == 0
                if w.bounds.height > 30.0
                    merged_anchors << key[0]
                else
                    singleton_h = w.bounds.height
                end
            end
            merged_anchors.size.should eq(5) # Arts, Healing, Law, Peace, Survival
        end
        assert_final_config(app)

        # After the move every c1 cell is one row.
        vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
        cells0 = vm.active_cells.select { |k, _| k[1] == 0 }
        cells0.size.should be >= 12 # the check sees the column, not an empty set - measured: 16
        cells0.each { |_, w| w.bounds.height.should be_close(singleton_h, 0.01) }
    end

    # Cache validation compares the cached and the immediate pipeline for the CONTENT layer (the data cells); it
    # skips sticky layers, so it cannot see the row headers.
    {% if flag?(:cache_validation) %}
    it "the whole sequence is dual-pipeline clean (cached == immediate)" do
        ui = EmbraceUI.new(make_demo_app, 1600, 1000)
        CrymbleUI::CacheValidation.enable_all
        CrymbleUI::CacheValidation.clear_failures!
        run_move_sequence(ui) { }
        CrymbleUI::CacheValidation.assert_no_failures!
    end
    {% end %}
end
