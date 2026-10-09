require "spec"
require "../../../spec/spec_helper"
require "../../../src/gui/embrace"
require "../../../src/debug-helper"
require "../../../src/constants"
require "crymble-ui/testing/test_renderer"
require "crymble-ui/testing/gui_test_helpers"

# Fixtures - no Driver: building state, and real-input clicks (Fixtures.click); EmbraceUI - Driver acts (embrace_ui.cr).
# Build with Fixtures, act with EmbraceUI. Building state here: tables, an app, a Shape, a pivot arrangement, the
# field list opened, a grid cell found.
#
# A helper two spec files need lives here or there, never twice (spec/gui/spec_helper_copies_spec.cr checks it);
# a spec's own DATA stays in the spec. Types are written from the top (`::Persistency`), so nothing here leans on
# a spec's `include Persistency`.
module Fixtures
    extend CrymbleUI::Testing::GUITestHelpers # click_on(app, widget): a click through App's real input path

    private alias PivotClass = Table::Lazy::Pivot::Classes

    alias Lids = Hash(String, ::Persistency::FieldLID | ::Persistency::TableLID | ::Persistency::RecordLID)

    # === Building state ===

    # Read TableReader text into a persistency: the tables' and fields' LIDs by name.
    def self.read_tables(persistency : ::Persistency::Default, text : String) : Lids
        lids = Lids.new
        TableReader(::Persistency::Default, ::Persistency::Cell).new(persistency, lids) << text
        lids
    end

    # An app on these tables with `shapes` Shapes on `open` (default: the text's first table), titled `title`
    # (default: the table), each on its own context taken after the read; a rebuild requested, nothing rendered.
    def self.app(text : String, open : String? = nil, title : String? = nil, shapes : Int32 = 1) : {EmbraceApp, Lids}
        app = EmbraceApp.new
        lids = read_tables(app.persistency, text)
        table = open || text.lines.first.strip
        lid = lids[table]?.try(&.as(::Persistency::TableLID)) ||
              raise ArgumentError.new("no table '#{table}' in the fixture; names: #{lids.keys.join(", ")}")
        app.shapes.clear
        shapes.times { app.shapes << ShapeState.new(title || table, app.persistency, app.persistency.context.clone, lid) }
        app.request_rebuild
        {app, lids}
    end

    # An app on one generated table T (A | B | C, `rows` records "a1 | b1 | c1", ...) with `shapes` Shapes on it -
    # for specs that count what a rebuild does as data and Shapes grow.
    def self.generated_app(*, rows : Int32, shapes : Int32) : EmbraceApp
        records = (1..rows).map { |i| "a#{i} | b#{i} | c#{i}" }.join("\n")
        app(["T", "A | B | C", records].join("\n"), shapes: shapes)[0]
    end

    private CITIES_PERSONS = <<-EOT
        Cities
        City | Country
        Arizona | USA
        Boston | USA

        Persons
        Person | City_City
        Alan | Boston
        EOT

    # Persons referencing Cities, in a persistency of its own (no app).
    def self.cities_persons : ::Persistency::Default
        persistency = ::Persistency::Default.new
        read_tables(persistency, CITIES_PERSONS)
        persistency
    end

    # A Shape on Persons, chosen in the table picker as a user does. The picker lists tables alphabetically, so on
    # cities_persons Persons is index 1; any other data fails loudly here rather than showing another table.
    def self.persons_shape(persistency : ::Persistency::Default) : ShapeState
        shape = ShapeState.new("Shape", persistency, persistency.context.clone)
        shape.widget_table_picker.select_index(1)
        shape.update(true)
        table = shape.table_lid.try { |lid| persistency.display_name(lid) }
        raise ArgumentError.new("index 1 picked '#{table}', not Persons; the picker offers: " \
                                "#{shape.widget_table_picker.names.join(", ")}") unless table == "Persons"
        shape
    end

    private SALES = <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10
        south | widget | 20
        north | gadget | 30
        south | gadget | 40
        north | widget | 50
        EOT

    # The Sales table (Region, Product, Amount) in a persistency of its own. Region x Product combinations repeat,
    # so a pivot on them aggregates more than one record per cell (drill-down cells exist) and a filter has
    # something to do.
    def self.sales : {::Persistency::Default, ::Persistency::TableLID}
        persistency = ::Persistency::Default.new
        lids = read_tables(persistency, SALES)
        {persistency, lids["Sales"].as(::Persistency::TableLID)}
    end

    # A document with these tables, written to disk by persistency alone - outside any app under test, so no
    # unsaved-changes question can interfere - under temp/ (gitignored), where the Load dialog starts. Yields
    # the path as the Load dialog walks it and removes the file when the block is done.
    def self.document_file(name : String, text : String, & : String ->) : Nil
        persistency = ::Persistency::Default.new
        read_tables(persistency, text)
        Dir.mkdir_p("temp/spec_fixtures")
        path = "temp/spec_fixtures/#{name}-#{Random::Secure.hex(4)}.embrace"
        File.write(path, persistency.save)
        begin
            yield path
        ensure
            File.delete?(path)
        end
    end

    # The fieldlist arranged as a pivot: `rows` (a list, or a Hash of row name => level), `columns` and
    # `aggregates`; every other field Unused. A list writes no levels. A name that is not a fieldlist field, or
    # names two, raises listing the fields.
    def self.pivot(shape : ShapeState, rows : Array(String), columns = [] of String, aggregates = [] of String) : Nil
        arrange(shape, rows, nil, columns, aggregates)
    end

    def self.pivot(shape : ShapeState, rows : Hash(String, Int32), columns = [] of String, aggregates = [] of String) : Nil
        arrange(shape, rows.keys, rows, columns, aggregates)
    end

    private def self.arrange(shape : ShapeState, rows : Array(String), levels : Hash(String, Int32)?,
                             columns : Array(String), aggregates : Array(String)) : Nil
        fl = shape.fieldlist.not_nil!
        name_col = Table::Lazy::Fieldlist::ColumnIndices::Name.value
        class_col = Table::Lazy::Fieldlist::ColumnIndices::Class.value
        level_col = Table::Lazy::Fieldlist::ColumnIndices::Level.value
        names = (0...fl.size[0]).map { |ri| fl[[ri, name_col]] } # size first: it brings the fieldlist up to date
        row_of = ->(name : String) do
            hits = names.each_index.select { |ri| names[ri] == name }.to_a
            return hits.first if hits.size == 1
            raise ArgumentError.new("#{hits.empty? ? "no" : hits.size} fieldlist fields '#{name}'; fields: #{names.join(", ")}")
        end
        placed = rows.map { |n| {row_of.call(n), PivotClass::Row, levels.try(&.[n])} } +
                 columns.map { |n| {row_of.call(n), PivotClass::Column, nil} } +
                 aggregates.map { |n| {row_of.call(n), PivotClass::Aggregate, nil} }
        names.each_index { |ri| fl[[ri, class_col]] = PivotClass::Unused.value.to_i64 }
        placed.each do |ri, cls, level|
            fl[[ri, class_col]] = cls.value.to_i64
            fl[[ri, level_col]] = level.to_i64 if level
        end
        shape.matrix_adapter.not_nil!.invalidate_all!
    end

    # The Shape's configurator rows in tree order, each with its level.
    def self.tree_rows(shape : ShapeState) : Array({Interface::GUI::VHTreeAdapter, Int32})
        found = [] of {Interface::GUI::VHTreeAdapter, Int32}
        shape.dfs_tree { |node, level| found << {node, level} }
        found
    end

    # === Rendering ===

    # A renderer of this size, the app settled on it once - nothing more (no Driver, so no build_tree of its own).
    def self.renderer(app : EmbraceApp, width : Int32 = 1200, height : Int32 = 800) : CrymbleUI::Testing::TestRenderer
        renderer = CrymbleUI::Testing::TestRenderer.new(width, height)
        renderer.settle_rendering(app)
        renderer
    end

    # Open the Shape's field list, which starts collapsed, and settle - before dragging in it. A spec driving
    # the app passes its Driver's renderer, after building the Driver.
    def self.open_fieldlist(app : EmbraceApp, renderer : CrymbleUI::Testing::TestRenderer,
                            shape : ShapeState = app.shapes.first) : Nil
        app.find("fieldlist_#{shape.id}").not_nil!.as(CrymbleUI::TreeNode).toggle
        app.request_rebuild
        renderer.settle_rendering(app)
    end

    # The Shape recomputed, the app rebuilt and settled - after a change made below the GUI.
    def self.refresh(app : EmbraceApp, renderer : CrymbleUI::Testing::TestRenderer, shape : ShapeState) : Nil
        shape.update(true)
        app.request_rebuild
        renderer.settle_rendering(app)
    end

    # === Grid cells (the adapter, in scroll order) ===

    # The first cell that is no header, not empty and no reference.
    def self.first_data_cell(adapter) : {Int32, Int32}
        find(adapter, "data cell (not a header, not empty, not a reference)") do |r, c|
            next false if adapter.cell_get_header_info({r, c}) # before reading: a read records the cell's value
            v = adapter.cell_read({r, c})
            v != "" && !v.is_a?(ReferenceCell)
        end
    end

    # The first cell - headers included - that shows this text.
    def self.cell_showing(adapter, text : String) : {Int32, Int32}
        find(adapter, "cell showing #{text.inspect}") { |r, c| adapter.cell_read({r, c}).to_s == text }
    end

    # The first data cell that holds a reference.
    def self.first_reference_cell(adapter) : {Int32, Int32}
        find(adapter, "reference data cell") do |r, c|
            !adapter.cell_get_header_info({r, c}) && adapter.cell_read({r, c}).is_a?(ReferenceCell)
        end
    end

    private def self.find(adapter, what : String, & : Int32, Int32 -> Bool) : {Int32, Int32}
        rows, cols = adapter.get_scrollorder
        rows.each { |r| cols.each { |c| return {r, c} if yield r, c } }
        raise ArgumentError.new("found no #{what} among #{rows.size} x #{cols.size} cells")
    end

    # === Real-input clicks ===

    # A click on the widget with this id through App's real input path (hit test included) - for specs whose
    # claim is that path; a use-case act goes through EmbraceUI's Driver instead.
    def self.click(app : CrymbleUI::App, id : String) : Nil
        click_on(app, app.find(id) || raise ArgumentError.new("no widget #{id}"))
    end
end
