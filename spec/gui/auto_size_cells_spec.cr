require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Shape → View → "Auto-size perspective cells".
#
# core's spec_helper installs NO font, so measure_text reports width 0 and every size claim
# below would be vacuous. Installed for this file only and restored after, because the font is
# global and other core specs are written against the zero-width measurement.

private def make_sized_app : EmbraceApp
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Notes
        Name | Body
        Al | a considerably longer value than the others
        Bo | b
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("N", p, p.context.clone, hash["Notes"].as(TableLID))
    app.request_rebuild
    app
end

# The shape of the field report: THREE data fields, the first empty, a long value in the
# second, a short one in the third — and values present on some rows only. The two-field fixture
# above never produced a third column, which is where the header drift was visible.
private def make_field_report_app : EmbraceApp
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Sheet
        c1 | c2 | c3
        1 | ahjh wjdj wjdjw jdjw | 
        2 |  | iwdidw
        3 |  | 
        4 |  | 
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("F", p, p.context.clone, hash["Sheet"].as(TableLID))
    app.request_rebuild
    app
end

private def toggle_id(shape) : String
    "auto_size_cells_#{shape.id}"
end

private def data_cell(adapter, want : String) : Tuple(Int32, Int32)?
    rows, cols = adapter.get_scrollorder
    rows.each do |r|
        cols.each do |c|
            return {r, c} if adapter.cell_read({r, c}).to_s == want
        end
    end
    nil
end

describe "auto-size perspective cells" do
    original_font = CrymbleUI::Widget.font
    before_each { CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new }
    after_each { CrymbleUI::Widget.font = original_font }

    it "measures a cell the way it PAINTS it: a dropdown votes width, not lines" do
        # doc/08-shapes.md:244 promises "a referenced (dropdown) cell contributes its width but not
        # its line count", and the LIBRARY default honours it by asking the painted widget — a
        # ComboBox reports no line count. embrace's own cell_natural_size override (written to avoid
        # cell_read's highlight side effects) measured every cell as a TextInput over the raw string,
        # so a multi-line referenced value voted 2 lines and grew the row. Measured, not guessed.
        p = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
            Cities
            City | Country
            Arizona | USA
            Boston | USA

            Persons
            Person | City_City
            Alan | Boston
        EOT
        cities = ShapeState.new("C", p, p.context.clone)
        cities.widget_table_picker.select_index(0)
        cities.update(true)
        ca = cities.matrix_adapter.not_nil!
        crows, ccols = ca.get_scrollorder
        city = nil
        crows.each { |r| ccols.each { |c| city ||= ({r, c} if ca.cell_read({r, c}).to_s == "Boston") } }
        ca.cell_assign(city.not_nil!, "Bos\nton") # the referenced value now has a hard break

        persons = ShapeState.new("P", p, p.context.clone)
        persons.widget_table_picker.select_index(1)
        persons.update(true)
        pa = persons.matrix_adapter.not_nil!
        rows, cols = pa.get_scrollorder
        ref = nil
        rows.each { |r| cols.each { |c| ref ||= ({r, c} if !pa.cell_get_header_info({r, c}) && pa.cell_read({r, c}).is_a?(ReferenceCell)) } }
        rc = ref.not_nil!
        pa.cell_paint(rc[0], rc[1]).should be_a(CrymbleUI::ComboBox) # instrument: it really is a dropdown

        nat = pa.cell_natural_size(rc[0], rc[1])
        nat[:lines].should eq(1)     # one line, as the doc promises and the dropdown paints
        nat[:width].should be > 0.0  # ...and it still votes a width
    end

    it "a structural change does not throw away where the user was scrolled" do
        # Field report: inserting a record while scrolled sent the view back to the top.
        #
        # A rebuild carries the scroll offset, but the new matrix starts at the ADAPTER's sizes —
        # the content-measured ones arrive later in the same frame. Every clamp in between computes
        # its maximum from a grid that is briefly its DEFAULT size (measured: 89px of content against
        # a 402px viewport where the real content is 654px), and a maximum of zero discards any
        # scrolled position. Unreachable before content sizing, because a row could not exceed the
        # viewport at all.
        #
        # Driven through the app, not the widget: a synthetic reconcile does not reproduce it —
        # tried, and the example passed with the fix removed.
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 600)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        # A tall value, the way multi-line records make one.
        vm = adapter.virtual_matrix.not_nil!
        rows, cols = adapter.get_scrollorder
        rc = {rows[0], cols[1]}
        vm.set_cursor_from_cell(rc)
        vm.on_text_input('a')
        40.times { vm.on_key_down(SF::Keyboard::Key::Enter, false, false, true); vm.on_text_input('b') }
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)

        live = adapter.virtual_matrix.not_nil!
        sv = live.content_scroll_view.not_nil!
        (sv.content_size.height - sv.viewport_size.height).should be > 100.0 # instrument: room to scroll
        sv.set_scroll_offset_for_test(CrymbleUI::Vec2.new(0.0, 200.0))
        renderer.render_frame(app)
        adapter.virtual_matrix.not_nil!.scroll_offset.y.should be_close(200.0, 1.0)

        shape.add_record   # the insert
        app.request_rebuild
        renderer.settle_rendering(app)

        adapter.virtual_matrix.not_nil!.scroll_offset.y.should be_close(200.0, 1.0)
    end

    it "measures a width at all (without this, every example below is vacuous)" do
        CrymbleUI::Widget.measure_text("Alpha", 14.0).width.should be > 0.0
    end

    it "widens the column holding a long value when the toggle is clicked" do
        # Driven through the menu item by id, as a user would — not by setting the flag. The
        # wiring IS the feature; a test that sets shape.auto_size_cells directly would pass
        # with the menu item missing entirely.
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        rc = data_cell(adapter, "a considerably longer value than the others").not_nil!
        before = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width

        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        # Assert the LAID-OUT cell, never get_col_width: those two disagreeing is exactly the
        # defect that made an earlier design look like it worked.
        live = adapter.virtual_matrix.not_nil!
        live.active_cells[rc].bounds.width.should be > before
    end

    # Cancelling an edit must put the line back the way it was.
    #
    # While the mode is on, the value being TYPED drives the line's size (the `fit_on_edit` hook
    # in shape.cr). Escape abandons that value and restores the one the cell had on focus — but
    # the size it grew to was never told, so the column stayed as wide (and the row as tall) as
    # the abandoned text needed. Field report 2026-09-18: "auto-size, when I edit a cell and make
    # it larger (any dimension) - and then cancel edit: row/col sizes are left from last edit,
    # not properly undone."
    #
    # Each example asserts the LAID-OUT cell and carries the grow as its own control, so it
    # cannot pass by auto-size doing nothing at all.
    it "gives the column its width back when the edit is CANCELLED" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "b").not_nil!
        before = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        "a value far longer than anything else in this column, by a wide margin".each_char { |ch| vm.on_text_input(ch) }
        renderer.settle_rendering(app)
        grown = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width
        grown.should be > before # control: the edit really did widen the column

        adapter.virtual_matrix.not_nil!.on_key_down(SF::Keyboard::Key::Escape, false, false)
        renderer.settle_rendering(app)

        # The abandoned text is gone, so the width it asked for must be gone with it — back to
        # what the column's remaining content needs (here: the long value two rows up).
        adapter.cell_read(rc).to_s.should eq("b") # the cancel really did revert the value
        adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width.should eq(before)
    end

    it "gives the row its height back when a multi-line edit is CANCELLED" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "b").not_nil!
        before = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.height

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        vm.on_text_input('x')
        3.times { vm.on_key_down(SF::Keyboard::Key::Enter, false, false, true); vm.on_text_input('y') } # Alt+Enter
        renderer.settle_rendering(app)
        grown = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.height
        grown.should be > before # control: the edit really did grow the row

        adapter.virtual_matrix.not_nil!.on_key_down(SF::Keyboard::Key::Escape, false, false)
        renderer.settle_rendering(app)

        adapter.cell_read(rc).to_s.should eq("b")
        adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.height.should eq(before)
    end

    it "gives a NARROWED column its width back too, or the restored value is left cut off" do
        # The mirror of the report, and the worse half: typing into the cell that HOLDS the
        # column's width (QuickEntry replaces the whole value) narrows the column, so a cancel
        # that does not re-fit leaves the restored — long — value drawn in a column sized for the
        # short one it replaced. Same hook, the grow branch of it.
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "a considerably longer value than the others").not_nil!
        before = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        vm.on_text_input('x') # QuickEntry: replaces the whole value
        renderer.settle_rendering(app)
        adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width.should be < before # control

        adapter.virtual_matrix.not_nil!.on_key_down(SF::Keyboard::Key::Escape, false, false)
        renderer.settle_rendering(app)

        adapter.cell_read(rc).to_s.should eq("a considerably longer value than the others")
        adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width.should eq(before)
    end

    it "KEEPS the new size when the edit is committed (so the two above cannot pass by reverting everything)" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "b").not_nil!
        before = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        "a value far longer than anything else in this column, by a wide margin".each_char { |ch| vm.on_text_input(ch) }
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)

        adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width.should be > before
    end

    # Stepping a Shape through its history re-measures too.
    #
    # The sizes have to follow the DATA, not just the editor. Alt+Left / the "<" button move the
    # Shape to an earlier commit, and the values in the grid change wholesale — so a column left
    # at the width of a value that commit never had is showing a size for content that is not
    # there. Driven through the button, because the wiring is the feature.
    it "re-measures the column when the Shape steps back through history" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "b").not_nil!

        # Two commits, each wider than the last, so stepping back lands on REAL content whose
        # width is known — not on the degenerate empty state before the table existed.
        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        "a middling value, wider than b".each_char { |ch| vm.on_text_input(ch) }
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)
        narrow = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width

        # Close the commit, or both edits land in the same open one and stepping back goes to
        # before the table had any content at all.
        shape.do_commit
        app.request_rebuild
        renderer.settle_rendering(app)

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        "a value far longer than anything else in this column, by a wide margin".each_char { |ch| vm.on_text_input(ch) }
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)
        wide = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width
        wide.should be > narrow # control: the second commit really did widen the column

        app.find("hist_back_#{shape.id}").not_nil!.as(CrymbleUI::Button).trigger_click
        renderer.settle_rendering(app)

        # Back on the first edit: the cell holds the middling value again, so the column must be
        # the width THAT needs — not the one the abandoned-from commit asked for.
        adapter.cell_read(rc).to_s.should eq("a middling value, wider than b")
        adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width.should eq(narrow)
    end

    it "refuses the drag while on — the mode owns every line's size, including the record column" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        vm = adapter.virtual_matrix.not_nil!
        fh = CrymbleUI::VirtualMatrix::FRAME_HEIGHT_BASE * CrymbleUI::FontSizing.zoom_factor
        border_x = vm.absolute_bounds.x + vm.ruler_col_width_pixels +
                   vm.grid_spacing + vm.get_col_width(0) * fh
        border_y = vm.absolute_bounds.y + vm.ruler_row_height_pixels / 2.0

        # Control first: with the mode OFF the gesture really does resize at this coordinate.
        before_off = vm.get_col_width(0)
        vm.on_mouse_down(CrymbleUI::Vec2.new(border_x, border_y))
        vm.on_mouse_move(CrymbleUI::Vec2.new(border_x + 50.0, border_y))
        vm.on_mouse_up(CrymbleUI::Vec2.new(border_x + 50.0, border_y))
        vm.get_col_width(0).should be > before_off

        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        # The record column is sized too (it compacts to its content, it just never grows past a
        # viewport it cannot scroll), so its drag would be overwritten by the next re-measure like
        # any other — and the handle is withdrawn rather than left to lie.
        live = adapter.virtual_matrix.not_nil!
        sticky_before = live.get_col_width(0)
        # Recomputed on the LIVE matrix: the toggle rebuilds, and a border read from the old
        # instance's widths lands next to the edge rather than on it — which would read as "refused"
        # for the wrong reason.
        sticky_border = live.absolute_bounds.x + live.ruler_col_width_pixels + live.grid_spacing +
                        live.get_col_width(0) * fh
        live.on_mouse_down(CrymbleUI::Vec2.new(sticky_border, border_y))
        live.on_mouse_move(CrymbleUI::Vec2.new(sticky_border + 50.0, border_y))
        live.on_mouse_up(CrymbleUI::Vec2.new(sticky_border + 50.0, border_y))
        live.get_col_width(0).should eq(sticky_before)

        # A column the mode DOES size still refuses: that drag really would be overwritten by the
        # next re-measure.
        live2 = adapter.virtual_matrix.not_nil!
        sized_border = live2.absolute_bounds.x + live2.ruler_col_width_pixels + live2.grid_spacing +
                       live2.get_col_width(0) * fh + live2.grid_spacing + live2.get_col_width(1) * fh
        pinned = live2.get_col_width(1)
        live2.on_mouse_down(CrymbleUI::Vec2.new(sized_border, border_y))
        live2.on_mouse_move(CrymbleUI::Vec2.new(sized_border + 50.0, border_y))
        live2.on_mouse_up(CrymbleUI::Vec2.new(sized_border + 50.0, border_y))
        live2.get_col_width(1).should eq(pinned)
    end

    it "is off by default and the menu item reflects the state" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        shape.auto_size_cells.should be_false
        item = app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem)
        item.trigger_click
        renderer.settle_rendering(app)
        shape.auto_size_cells.should be_true
    end

    it "a table of single-line values does not change height when the mode goes on" do
        # A single line's NATURAL height (font + padding + border) exceeds the box a default row
        # already paints in, so sizing every row to it would make an ordinary table ~20% shorter
        # in records while claiming to fit content that already fits. Asserted together with a
        # width that DID move, so "nothing changed" cannot pass as "the row rule worked".
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        rc = data_cell(adapter, "a considerably longer value than the others").not_nil!
        vm = adapter.virtual_matrix.not_nil!
        height_before = vm.active_cells[rc].bounds.height
        width_before = vm.active_cells[rc].bounds.width

        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        live = adapter.virtual_matrix.not_nil!
        live.active_cells[rc].bounds.width.should be > width_before    # something DID move
        live.active_cells[rc].bounds.height.should eq(height_before)   # ... but not the height
    end

    it "grows the cell while typing, without losing the editor" do
        # The headline behaviour: the value being typed drives the size. The editor must survive
        # it — a teardown would take the caret with it.
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        live = adapter.virtual_matrix.not_nil!
        rc = data_cell(adapter, "b").not_nil!
        before = live.active_cells[rc].bounds.width
        live.set_cursor_from_cell(rc)
        live.on_text_input('W')
        editor = live.proxy_focused_widget
        editor.should_not be_nil
        # Long enough to exceed the column's existing maximum: this cell shares its column with
        # a 42-character value, so a shorter entry could not widen anything and the example
        # would assert nothing.
        90.times { live.on_text_input('W') }
        renderer.render_frame(app)

        live.proxy_focused_widget.should be(editor)                      # same editor object
        live.active_cells[rc].bounds.width.should be > before            # and the cell grew
        adapter.cell_read(rc).to_s.should eq("b")                        # still uncommitted
    end
    # THE SECOND EDIT SESSION - the one that comes after a commit.
    #
    # Wolfgang, 2026-09-21: "click 1/c2, 'enter', 'a', 'a' -> widens; BS -> shortens; 'Enter' to
    # leave; same again: 'enter', 'a' -> widens; BS -> now does _not_ shorten!" Also on row
    # heights, and on the Escape that reverts the edit.
    #
    # One session cannot show it. Committing rebuilds the tree, reconciliation hands the fresh
    # matrix the old one's sizes and cancels the re-measure - and used to drop the pass-1 extents
    # with it, leaving the per-keystroke path grow-only from the first commit onward
    # (crymbleui VirtualMatrix#carry_line_extents_from). Every assertion here is on the far side
    # of that commit; the first session is the control that the gesture works at all.
    it "shortens on backspace in the second edit session, after a commit" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "b").not_nil!

        # Session one: 60 characters clear the 42-character sibling in this column, so the edited
        # cell alone decides the width and one backspace has to be visible.
        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        60.times { vm.on_text_input('W') }
        renderer.render_frame(app)
        grown = vm.active_cells[rc].bounds.width
        vm.on_key_down(SF::Keyboard::Key::Backspace, false, false)
        renderer.render_frame(app)
        vm.active_cells[rc].bounds.width.should be < grown # control: it shortens before a commit
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)

        # Session two: the same cell, the same gesture, across the rebuild the commit caused.
        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        80.times { vm.on_text_input('W') }
        renderer.render_frame(app)
        grown2 = vm.active_cells[rc].bounds.width
        grown2.should be > grown # control: the second session still widens
        20.times { vm.on_key_down(SF::Keyboard::Key::Backspace, false, false) }
        renderer.render_frame(app)

        vm.active_cells[rc].bounds.width.should be < grown2,
            "after the commit the cell stayed #{vm.active_cells[rc].bounds.width.round(1)}px wide " \
            "through twenty backspaces"
    end

    it "puts the width back on Escape in the second edit session, after a commit" do
        # Escape reverts the edit, so the size has to revert with it - on the far side of a commit
        # as well as before one. core announces the cancel through the same fit hook as a change
        # (shape.cr fit_on_edit, ev.change? || ev.cancel?), so what the revert asks for is a
        # SHRINK, and the grow-only fallback swallowed it.
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "b").not_nil!

        # Commit one edit first: the defect needs a rebuild to exist at all.
        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        30.times { vm.on_text_input('W') }
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        settled = vm.active_cells[rc].bounds.width
        80.times { vm.on_text_input('W') }
        renderer.render_frame(app)
        vm.active_cells[rc].bounds.width.should be > settled # control: the edit widened it

        vm.on_key_down(SF::Keyboard::Key::Escape, false, false)
        renderer.settle_rendering(app)

        adapter.cell_read(rc).to_s.size.should eq(30) # control: the value really did revert
        vm.active_cells[rc].bounds.width.should be_close(settled, 1.0),
            "the cell kept the abandoned edit's width (#{vm.active_cells[rc].bounds.width.round(1)}px " \
            "against #{settled.round(1)}px) after Escape put the old value back"
    end

    it "shortens the row on backspace in the second edit session, after a commit" do
        # The height half of the same report, through the same hook: Alt+Enter authors the breaks
        # that make the row tall, backspace takes them away again.
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rc = data_cell(adapter, "b").not_nil!

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        vm.on_text_input('x')
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)

        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell(rc)
        single = vm.active_cells[rc].bounds.height
        vm.on_text_input('x')
        4.times { vm.on_key_down(SF::Keyboard::Key::Enter, false, false, true) } # Alt+Enter
        vm.on_text_input('y')
        renderer.render_frame(app)
        tall = vm.active_cells[rc].bounds.height
        tall.should be > single # control: the authored breaks made the row taller

        6.times { vm.on_key_down(SF::Keyboard::Key::Backspace, false, false) }
        renderer.render_frame(app)

        vm.active_cells[rc].bounds.height.should be_close(single, 1.0),
            "the row stayed #{vm.active_cells[rc].bounds.height.round(1)}px tall after the breaks " \
            "were deleted again (a single-line row is #{single.round(1)}px)"
    end

    it "grows the row for the breaks you type, and keeps the value in view" do
        # Field report, two rounds. The breaks a user types ARE content: the row grows for them
        # (round 2: sizing to the content-bearing lines cut them away). And because the row
        # holds the whole value, the caret resting on the last — blank — line does not scroll
        # the text out of the cell, which is what made the cell look empty while editing.
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        live = adapter.virtual_matrix.not_nil!
        rc = data_cell(adapter, "b").not_nil!
        before = live.active_cells[rc].bounds.height
        live.set_cursor_from_cell(rc)
        live.on_text_input('x')
        4.times { live.on_key_down(SF::Keyboard::Key::Enter, false, false, true) } # Alt+Enter
        renderer.render_frame(app)

        live.active_cells[rc].bounds.height.should be > before
        editor = live.proxy_focused_widget.not_nil!.as(CrymbleUI::TextInput)
        editor.cursor_pos.should eq(5)                     # caret on the last, blank, line
        editor.effective_scroll_offset.y.should eq(0.0)    # ...and nothing scrolled away
    end

    it "keeps the sizes it computed when the toggle goes off again" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        vm = adapter.virtual_matrix.not_nil!
        fh = CrymbleUI::VirtualMatrix::FRAME_HEIGHT_BASE * CrymbleUI::FontSizing.zoom_factor
        border_y = vm.absolute_bounds.y + vm.ruler_row_height_pixels / 2.0
        # Column 1, not 0: the leftmost column is STICKY and the mode never sizes it, so a
        # handover example built on it could not tell "handed over" from "never touched".
        border_x = vm.absolute_bounds.x + vm.ruler_col_width_pixels + vm.grid_spacing +
                   vm.get_col_width(0) * fh + vm.grid_spacing + vm.get_col_width(1) * fh
        vm.on_mouse_down(CrymbleUI::Vec2.new(border_x, border_y))
        vm.on_mouse_move(CrymbleUI::Vec2.new(border_x + 60.0, border_y))
        vm.on_mouse_up(CrymbleUI::Vec2.new(border_x + 60.0, border_y))
        renderer.settle_rendering(app)
        dragged = adapter.virtual_matrix.not_nil!.get_col_width(1)

        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)
        auto = adapter.virtual_matrix.not_nil!.get_col_width(1)
        auto.should_not eq(dragged)   # the mode really took over — else the next assert is vacuous

        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)
        vm = adapter.virtual_matrix.not_nil!
        # Switching off hands the measured layout over as the user's own sizes — it is a good
        # starting point to adjust from, so nothing moves and the drag simply resumes from there.
        vm.get_col_width(1).should eq(auto)

        border_x = vm.absolute_bounds.x + vm.ruler_col_width_pixels + vm.grid_spacing +
                   vm.get_col_width(0) * fh + vm.grid_spacing + vm.get_col_width(1) * fh
        vm.on_mouse_down(CrymbleUI::Vec2.new(border_x, border_y))
        vm.on_mouse_move(CrymbleUI::Vec2.new(border_x + 40.0, border_y))
        vm.on_mouse_up(CrymbleUI::Vec2.new(border_x + 40.0, border_y))
        renderer.settle_rendering(app)
        adapter.virtual_matrix.not_nil!.get_col_width(1).should be > auto
    end

    it "a duplicated Shape keeps the mode" do
        app = make_sized_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        copy = shape.dup_shape("Copy")
        copy.auto_size_cells.should be_true
    end

    it "keeps each ruler label over the column it names (field report: headers drift)" do
        # From the field: with the mode on, c3's label sat left of its cells and c1's right of
        # the rank column. The ruler draws from @cached_col_sizes while cells are placed from
        # col_physical_cum — if those disagree the header row lies, and no assertion on cell
        # bounds alone can see it. embrace's scroll order puts headers at the TAIL, so this grid
        # has STICKY columns, which a plain headerless fixture does not exercise.
        app = make_field_report_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!

        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        vm = adapter.virtual_matrix.not_nil!
        ruler = vm.col_ruler_widget.not_nil!
        prims = ruler.to_primitives(ruler.bounds)
        labels = {} of String => Float64
        font = CrymbleUI::FontSizing.calculate_size(CrymbleUI::VirtualMatrix::RULER_LABEL_FONT_SCALE)
        prims.each do |pr|
            if pr.is_a?(CrymbleUI::DrawText)
                labels[pr.text] = pr.position.x + CrymbleUI::Widget.measure_text(pr.text, font).width / 2.0
            end
        end
        labels.size.should be > 0   # instrument: the ruler drew something

        rows, cols = adapter.get_scrollorder
        offenders = [] of String
        cols.each do |c|
            next if c < vm.sticky_col_count      # sticky columns are drawn by the corner strip
            cell = vm.active_cells.find { |k, _| k[1] == c }.try(&.[1])
            next unless cell
            centre = labels["c#{c + 1}"]?
            next unless centre
            left = cell.bounds.x
            right = cell.bounds.x + cell.bounds.width
            unless centre >= left && centre <= right
                offenders << "c#{c + 1} label at #{centre.round(1)} vs column #{left.round(1)}..#{right.round(1)}"
            end
        end
        # Print the whole geometry when it fails, so the numbers can be compared with what is
        # actually on screen rather than guessed at.
        offenders.should be_empty, "#{offenders.join("; ")} | labels=#{labels.map { |k, v| "#{k}@#{v.round(1)}" }.join(",")} | sticky_cols=#{vm.sticky_col_count} | order=#{cols.inspect}"
    end

    it "keeps the sticky corner chrome sized to the columns it covers" do
        # The field report's real cause: the corner strip is sized from ruler + sticky column
        # width, and auto-size changed that width without re-laying it out — so it kept a
        # 143px box where 64.8 was needed and painted over the first data column, which read
        # on screen as a mysterious empty gap plus a header label sitting off its column.
        #
        # This guard lives HERE as well as in crymbleui because every embrace grid has a sticky
        # column, while a library fixture only has one if someone remembers to build it — and
        # the eleven library examples that passed while this was broken all had none.
        app = make_field_report_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        adapter.virtual_matrix.not_nil!.sticky_col_count.should be > 0 # instrument

        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        vm = adapter.virtual_matrix.not_nil!
        if corner = vm.corner_ruler_widget
            corner.bounds.width.should be_close(vm.ruler_col_width_pixels + vm.sticky_col_width_pixels, 0.5)
        end
        # And the first data column must actually start where the chrome ends — the overlap is
        # what was visible.
        rows, cols = adapter.get_scrollorder
        first_data = cols.find { |c| c >= vm.sticky_col_count }.not_nil!
        cell = vm.active_cells.find { |k, _| k[1] == first_data }.not_nil![1]
        cell.bounds.x.should be >= vm.ruler_col_width_pixels
    end

    # DELETING A RECORD MUST NOT MOVE THE SURVIVING ROW'S TEXT.
    #
    # Wolfgang, 2026-09-21: with one record left and its row made tall by a multi-line cell, the
    # short cells beside it drew their values on the row's BOTTOM edge - "see how 1/c1's '1'
    # jumps?" - while the record-number column next to them stayed centred. Adding a record back
    # cured it. The cause is in crymbleui: a one-row grid's scroll order is `[0]`, which
    # `derive_sticky_count` could not tell apart from "row 0 is pinned", and a whole-axis sticky
    # strip leaves the ink-placement band empty, so `place_ink` pushed each value to its cell's
    # bottom edge to keep it "visible".
    it "keeps a short cell's value put when the record below it is deleted" do
        app = EmbraceApp.new
        p = app.persistency
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
            Sheet
            c1 | c2
            1 | a
            2 | b
        EOT
        app.shapes.clear
        app.shapes << ShapeState.new("S", p, p.context.clone, hash["Sheet"].as(TableLID))
        app.request_rebuild
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        text_offset = ->(rc : Tuple(Int32, Int32)) {
            cell = adapter.virtual_matrix.not_nil!.active_cells[rc]
            prim = cell.to_primitives(cell.bounds).select(&.is_a?(CrymbleUI::DrawText)).first
            prim.as(CrymbleUI::DrawText).position.y
        }

        # Row 0 becomes tall: four authored lines in c2, committed.
        vm = adapter.virtual_matrix.not_nil!
        vm.set_cursor_from_cell({0, 2})
        vm.on_text_input('a')
        3.times do
            vm.on_key_down(SF::Keyboard::Key::Enter, false, false, true) # Alt+Enter
            "aaa".each_char { |ch| vm.on_text_input(ch) }
        end
        vm.on_key_down(SF::Keyboard::Key::Enter, false, false)
        renderer.settle_rendering(app)

        tall = adapter.virtual_matrix.not_nil!.active_cells[{0, 1}].bounds.height
        tall.should be > 40.0 # control: the row really did grow for the four lines
        before = text_offset.call({0, 1})

        # Delete record 2, the way the cell context menu does it.
        adapter.cell_delete({1, 1})
        shape.update(true)
        app.request_rebuild
        renderer.settle_rendering(app)

        adapter.get_scrollorder[0].size.should eq(1) # control: one record left
        adapter.virtual_matrix.not_nil!.active_cells[{0, 1}].bounds.height.should be_close(tall, 0.5)
        text_offset.call({0, 1}).should be_close(before, 0.5),
            "the surviving row drew c1's value #{text_offset.call({0, 1}).round(1)}px down a " \
            "#{tall.round(1)}px cell, against #{before.round(1)}px while the second record existed"
    end


    # A REFERENCE CELL IS EDITED TOO, and the mode has to follow it.
    #
    # Wolfgang, 2026-09-22: with auto-size on, pointing a reference cell at a longer value left
    # the column at its old width and cut the value ("»Suppressi|"); toggling the mode off and on
    # re-measured it. The per-keystroke fit hook is attached to the TEXT editor only (shape.cr's
    # cell_paint), and a reference cell paints a ComboBox whose commit goes through
    # `cell_assign_reference` - so no path re-fitted the line after the write. The full sweep
    # measures it correctly, which is exactly why the toggle looked like a cure.
    it "widens the column when a reference cell is pointed at a longer value" do
        app = EmbraceApp.new
        p = app.persistency
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
            Cities
            City
            Rome
            Constantinopolis

            Persons
            Person | City_City
            Alan | Rome
        EOT
        app.shapes.clear
        app.shapes << ShapeState.new("P", p, p.context.clone, hash["Persons"].as(TableLID))
        app.request_rebuild
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        app.find(toggle_id(shape)).not_nil!.as(CrymbleUI::MenuItem).trigger_click
        renderer.settle_rendering(app)

        rows, cols = adapter.get_scrollorder
        rc = nil
        rows.each { |r| cols.each { |c| rc ||= ({r, c} if adapter.cell_read({r, c}).is_a?(ReferenceCell)) } }
        rc = rc.not_nil!
        before = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width

        # The ReferenceCell is LIVE: read the rank into an Int now, or the "before" value
        # reads back as the value we are about to assign.
        original_rank = adapter.cell_read(rc).as(ReferenceCell).rank
        candidates = {} of Int32 => String
        adapter.cell_read(rc).as(ReferenceCell).each_defined_fulfilling { |cand| candidates[cand.rank] = cand.value.to_s }
        longer = candidates.find { |_, v| v == "Constantinopolis" }.not_nil![0]
        longer.should_not eq(original_rank) # control: it really is a different record

        # The production path: this is what the cell's ComboBox calls on select.
        adapter.cell_assign_reference(rc[0], rc[1], longer)
        renderer.settle_rendering(app)

        adapter.cell_read(rc).as(ReferenceCell).rank.should eq(longer) # control: the value changed
        width = adapter.virtual_matrix.not_nil!.active_cells[rc].bounds.width
        width.should be > before,
            "the column stayed #{width.round(1)}px after the reference was pointed at a value " \
            "#{"Constantinopolis".size - "Rome".size} characters longer"
    end

end
