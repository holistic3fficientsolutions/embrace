# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# needs to come at the beginning
{% if flag?(:win32) %}
# needs to be at the very beginning, before Vesa driver can emit sth. to the non-existant Windows GUI console - otherwise: silent crash
null_file = File.open(File::NULL, "w") # Open the null device for writing
# Redirect STDOUT to null_file so that any output goes to /dev/null
STDOUT.reopen(null_file)
STDOUT.sync = true  # Ensure immediate flushing
# Likewise, redirect STDERR to null_file
STDERR.reopen(null_file)
STDERR.sync = true

# see https://github.com/crystal-lang/crystal/issues/13058
@[Link(ldflags: "/ENTRY:wWinMainCRTStartup")]
@[Link(ldflags: "/SUBSYSTEM:WINDOWS")]
lib LibCrystalMain
end

lib LibC
    alias HINSTANCE = HANDLE
    # shellapi.h
    fun CommandLineToArgvW(lpCmdLine : LPWSTR, pNumArgs : Int*) : LPWSTR*
end

fun wWinMain(
    hInstance : LibC::HINSTANCE,
    hPrevInstance : LibC::HINSTANCE,
    pCmdLine : LibC::LPWSTR,
    nCmdShow : LibC::Int,
    ) : LibC::Int
    argv = LibC.CommandLineToArgvW(pCmdLine, out argc)
    wmain(argc, argv)
ensure
    LibC.LocalFree(argv) if argv
end
{% end %}

require "crymble-ui"
require "../../lib/crymble-ui/src/csfml3/wrapper"
require "../persistency"

# Workaround: Crystal 1.19+ type resolution needs explicit alias when
# `private pseudo_enum` is used in Persistency module.
# (A top-level `include GUI` would change lookup scope, so we avoid it here.)
module Interface::Persistency
  include ::Persistency
end
require "../constants"
require "../debug-helper" # for TableReader

SCREENSHOT_MODE = {{ flag?(:screenshot_mode) }}

require "./shape"
require "./embrace_dialogs"
require "./embrace_context_menus"
require "./embrace_file_ops"

# design decisions
# - no modal dialogues
# - statusbar is painted by CrymbleUI framework
# - main menubar is part of EmbraceApp.build
# - CrymbleUI handles window management, event dispatch, rendering

include Persistency # bring FieldLID, TableLID, RecordLID, CommitLID into scope

class EmbraceApp < CrymbleUI::App
    include FieldlistGrid

    @filename : String? = nil
    @persistency = Persistency::Default.new
    @last_save_version = 0

    getter persistency : Persistency::Default
    getter shapes : Array(ShapeState)

    # Theme state
    @dark_theme : Bool = true

    # Statusbar state
    @statusbar_text : String = ""
    @statusbar_color : CrymbleUI::Color = CrymbleUI::Color.white # only used during priority messages
    @statusbar_priority_remaining : Int32 = 0
    @statusbar_priority_text : String = ""
    @statusbar_timer_id : Int32? = nil
    @last_hover_cell : {Int32, Int32}? = nil
    @last_hover_cell_name : String = ""

    # Splash overlay — timer starts at first render, NOT at app construction,
    # so the animation isn't missed when startup is slow (e.g. Windows ~1-2s init).
    @splash_start : Time::Instant? = nil
    @splash_timer_id : Int32? = nil
    SPLASH_STAGES = [0.0, 0.4, 0.6, 0.72, 1.2, 1.6]

    # Open shapes
    @shapes = Array(ShapeState).new

    # Background color (dark theme default; toggled by @dark_theme)
    @bg_color : CrymbleUI::Color = CrymbleUI::Color.new(0, 0, 0, 255)

    # Dialog state - pending confirm dialog
    @pending_confirm : {String, Proc(Nil)}? = nil

    # About dialog
    @show_about : Bool = false

    # Dialog stack for all dialog types
    @dialogs = Array(Dialogs::Base).new

    # Context menu state: {x, y, title, items: Array({label, shortcut, enabled, action})}
    @context_menu : {Float64, Float64, String, Array({String, String?, Bool, Proc(Nil)})}? = nil
    @context_menu_popup : CrymbleUI::Popup? = nil

    # Clipboard for cell cut/paste: {shape_id, row, col}
    @cut_cell : {String, Int32, Int32}? = nil

    # Per-shape deferred-commit state: which tables are UNCHECKED (= should
    # float to the next open commit instead of being committed now). Keyed by
    # {shape_id, table_lid}. Unchecked = present in the set. Cleared on Commit!.
    @commit_deferred : Set({String, TableLID}) = Set({String, TableLID}).new

    # Per-filter-row text search: narrows which distinct-value checkboxes are
    # visible in the filter UI. Keyed by {shape_id, column_index}. Ephemeral.
    # Missing key → empty string (no filter).
    @filter_search : Hash({String, Int32}, String) = Hash({String, Int32}, String).new("")

    # Test-facing helper: set a per-filter-row search string programmatically
    # without routing through the on_text input callback. Used by filter_ui_spec.
    def commit_filter_search(key : {String, Int32}, value : String) : Nil
        @filter_search[key] = value
    end

    def initialize
        # Register compile-time-embedded image bytes under the same paths the
        # widgets use. The actual GPU texture is created lazily by
        # CrSFMLBackend.draw_image on first use, so this works regardless of
        # the current working directory and doesn't need a GL context yet.
        # See src/constants.cr for the single source of bytes.
        CrymbleUI::CrSFMLBackend.register_embedded_image(
            "resources/logo-embrace-h3o.png", Constant::LogoBytes)
        CrymbleUI::CrSFMLBackend.register_embedded_image(
            "resources/embrace-logo.png", Constant::IconBytes)
        CrymbleUI::Theme.set(:dark)
        update_bg_color
        @last_save_version = @persistency.version
        @persistency.contexts.pop # clear stack
        do_newfile_empty_impl
        shape_add
        @on_event_exception = ->(msg : String) {
            set_statusbar_warning(msg)
            nil
        }
        on_hover_change do
            if @statusbar_priority_remaining <= 0
                text = find_hover_text(hovered_widget)
                # Matrix cells: check by position, cache cell to avoid redundant cell_get_name
                if text.nil? && (pos = @last_mouse_position)
                    @shapes.each do |shape|
                        if (adapter = shape.matrix_adapter) && (vm = adapter.virtual_matrix)
                            if vm.absolute_bounds.contains_point(pos)
                                if cell = vm.point_to_cell(pos)
                                    if cell != @last_hover_cell
                                        @last_hover_cell = cell
                                        @last_hover_cell_name = adapter.cell_get_name(cell[0], cell[1])
                                    end
                                    text = @last_hover_cell_name
                                    break
                                end
                            end
                        end
                    end
                else
                    @last_hover_cell = nil
                end
                new_text = text || ""
                if new_text != @statusbar_text
                    @statusbar_text = new_text
                    if sb = find("statusbar").as?(CrymbleUI::StatusBar)
                        sb.text = new_text
                    end
                end
            end
        end
    end

    # Walk up parent chain to find nearest hover_text or matrix cell name
    # Walk up parent chain to find nearest hover_text
    private def find_hover_text(widget : CrymbleUI::Widget?) : String?
        current = widget
        while current
            if ht = current.hover_text
                return ht
            end
            current = current.parent
        end
        nil
    end

    def app_background_color : CrymbleUI::Color?
        @bg_color
    end

    private def update_bg_color
        @bg_color = @dark_theme ? CrymbleUI::Color.new(0, 0, 0, 255) : CrymbleUI::Color.new(240, 240, 240, 255)
    end

    # Use inherited App.request_rebuild — sets @needs_rebuild flag so the
    # framework's event loop calls rebuild at the proper time.


    def build : CrymbleUI::Widget
        window("H3O Embrace", 1200, 900) do
            on_closed { do_quit }

            menubar do
                menu("File") do
                    menu_item("New file (empty)") { do_newfile_empty }
                    menu_item("New file (demo)") { do_newfile_demo }
                    menu_item("Load file...") { do_load }
                    menu_item("Save file as...") { do_save_as }
                    save_item = menu_item("Save file", "^S") { do_save(@filename.not_nil!) if @filename }
                    save_item.enabled = !@filename.nil?
                    menu_item("Quit", "^Q") { do_quit }
                end
                menu("View") do
                    menu_item("New Shape", "^N") { shape_add }
                    zoom_in_item = menu_item("Zoom in", "^+")
                    zoom_in_item.on_click_action = -> { CrymbleUI::FontSizing.zoom_in; root.try &.mark_needs_layout; nil }
                    zoom_out_item = menu_item("Zoom out", "^-")
                    zoom_out_item.on_click_action = -> { CrymbleUI::FontSizing.zoom_out; root.try &.mark_needs_layout; nil }
                    menu_item("Dark Theme", checked: @dark_theme) do
                        @dark_theme = !@dark_theme
                        CrymbleUI::Theme.set(@dark_theme ? :dark : :light)
                        update_bg_color
                        # Force matrix cells to recreate with new theme colors
                        @shapes.each { |s| s.matrix_adapter.try &.invalidate_all! }
                        request_rebuild
                    end
                end
                menu("Help") do
                    menu_item("About...") { @show_about = true; request_rebuild }
                end
            end

            # Render shapes as panels
            @shapes.each do |shape|
                next unless shape.open
                build_shape_panel(shape)
            end

            # CPU monitor always on top (debug/development only)
            {% unless flag?(:release) %}
                aligned_layer(align: CrymbleUI::Alignment::TopRight, margin: 4.0, z_index: 1_000_000) do
                    cpu_monitor
                end
            {% end %}

            # About dialog panel
            if @show_about
                window_panel("About Embrace", x: 150.0, y: 20.0, width: 700.0, height: 800.0, id: "about") do
                    on_closed { @show_about = false; request_rebuild }
                    register_shortcut("Escape") { @show_about = false; request_rebuild }
                    register_shortcut("Enter") { @show_about = false; request_rebuild }
                    scroll_view(id: "about_scroll") do
                        vstack(spacing: 5.0, padding: 10.0) do
                            image("resources/logo-embrace-h3o.png", id: "about_logo", width: 655.0, height: 655.0)
                            text("")
                            text("")
                            text("Version #{Constant::Version}")
                            text("Build version #{Constant::BuildVersion}, #{Constant::BuildMode}")
                            text("Build date #{Constant::BuildDate.to_s("%F")}")
                            text("Compiled with #{Crystal::DESCRIPTION.split("\n", remove_empty: true).join(", ")}")
                            text("Open source under the GNU Affero General Public License v3.")
                            text("Commercial & Enterprise licensing: h3o.de")
                            text("Patent pending")
                            text("H3O Embrace is a registered trademark")
                            text("")
                            text("Using:")
                            text("CrymbleUI (version #{CrymbleUI::VERSION}, MIT license)")
                            text("CSFML (version #{SF::VERSION}, Zlib license)")
                            text("SFML (version #{SF::SFML_VERSION}, Zlib license)")
                            text("Google Cousine-Regular font (version 1.21, Apache 2.0 license)")
                            text("crexcel (version #{Crexcel::VERSION}, MIT license)")
                            text("xlsx-parser (version #{XlsxParser::VERSION}, MIT license)")
                            text("")
                            button("Close") { @show_about = false; request_rebuild }
                        end
                    end
                end
            end

            # Confirm dialog panel
            if confirm = @pending_confirm
                msg, action = confirm
                wp = window_panel(msg, x: 300.0, y: 250.0, width: 500.0, height: 100.0, id: "confirm") do
                    register_shortcut("Enter") { @pending_confirm = nil; action.call; request_rebuild }
                    register_shortcut("Escape") { @pending_confirm = nil; request_rebuild }
                    hstack(spacing: 10.0, padding: 10.0) do
                        button("Ok", id: "confirm_ok") do
                            @pending_confirm = nil
                            action.call
                            request_rebuild
                        end
                        button("Cancel", id: "confirm_cancel") do
                            @pending_confirm = nil
                            request_rebuild
                        end
                    end
                end
                wp.title_bar_color = CrymbleUI::Theme.current["panel.title_bar_warning"]
                wp.background_color = CrymbleUI::Theme.current["panel.background_warning"]
            end

            # Render all active dialogs
            @dialogs.each do |dialog|
                next unless dialog.open
                build_dialog(dialog)
            end
            @dialogs.reject! { |d| !d.open }

            # Context menu: shown as Window overlay Popup (click-outside-to-close)
            # The popup is added/removed from the Window overlay list, not the DSL tree,
            # so notify_overlays_of_click triggers on_click_outside correctly.
            if ctx = @context_menu
                unless @context_menu_popup
                    cx, cy, title, items = ctx
                    popup_w = CrymbleUI::Popup.new(padding: 4.0, id: "context_menu")
                    popup_w.target_x = cx
                    popup_w.target_y = cy
                    popup_bg = CrymbleUI::Theme.current.popup_background
                    # Build items as 1-column RecursiveGrid (gives tight width to all children)
                    rows = Array(Array(CrymbleUI::Widget)).new
                    unless title.empty?
                        muted = CrymbleUI::Theme.current.text_default
                        muted = CrymbleUI::Color.new(muted.r, muted.g, muted.b, (muted.a // 2).to_u8)
                        title_w = CrymbleUI::Text.new(title, color: muted, font_scale: -1)
                        sep = CrymbleUI::Separator.new
                        rows << [title_w.as(CrymbleUI::Widget), CrymbleUI::Text.new("").as(CrymbleUI::Widget)]
                        rows << [sep.as(CrymbleUI::Widget), CrymbleUI::Text.new("").as(CrymbleUI::Widget)]
                    end
                    # Calculate max label width for shortcut alignment
                    max_label_w = items.max_of { |item| item[0].size } * 8.0 + 16.0
                    items.each_with_index do |item, i|
                        label = item[0]
                        shortcut = item[1]
                        enabled = item[2]
                        captured_action = item[3]
                        b = CrymbleUI::Button.new(label, padding: 2.0,
                            background_color: popup_bg, border_color: popup_bg,
                            text_color: CrymbleUI::Theme.current.text_default,
                            text_align: CrymbleUI::TextAlign::Left,
                            id: "ctx_#{i}") do
                            dismiss_context_menu
                            captured_action.call
                            request_rebuild
                        end
                        b.enabled = enabled
                        sc = CrymbleUI::Text.new(shortcut || "", font_scale: -1,
                            color: CrymbleUI::Theme.current.text_default)
                        sc.enabled = enabled
                        rows << [b.as(CrymbleUI::Widget), sc.as(CrymbleUI::Widget)]
                    end
                    grid = CrymbleUI::RecursiveGrid.new(content: rows, spacing: 1.0)
                    popup_w.add_child(grid)
                    popup_w.on_click_outside_callback = ->() {
                        dismiss_context_menu
                    }
                    @context_menu_popup = popup_w
                    find_window.try &.add_overlay(popup_w)
                end
            end

            display_text = if @statusbar_priority_remaining > 0
                "(#{@statusbar_priority_remaining}) #{@statusbar_priority_text}"
            else
                @statusbar_text
            end
            display_color = if @statusbar_priority_remaining > 0
                @statusbar_color
            else
                CrymbleUI::Theme.current.statusbar_text
            end
            statusbar(display_text, id: "statusbar", text_color: display_color)
        end
    end

    # === Shape Panel Builder ===

    # Resolve the focused shape's matrix cursor for a keyboard cell-op and
    # yield {adapter, vm, cursor_rc}. No-ops when the shape has no matrix yet
    # (e.g. no table selected). Runs at key-press time, so it reads the live
    # cursor.
    private def with_cell_cursor(shape : ShapeState) : Nil
        adapter = shape.matrix_adapter
        return unless adapter
        vm = adapter.virtual_matrix
        return unless vm
        yield adapter, vm, vm.cursor_rc
    end

    # Run a cursor cell mutation, swallowing the data layer's "can't do that
    # here" (ConditionsNotMet — header / aggregate / incompatible value type) so
    # a keyboard shortcut on an unsuitable cell no-ops; always reconcile +
    # repaint after (mirrors the rescue used by ShapeState's cell bridges).
    private def cell_op(shape : ShapeState)
        yield
    rescue ConditionsNotMet
        # cursor cell can't take this op — no-op
    ensure
        shape.update(true)
        request_rebuild
    end

    private def build_shape_panel(shape : ShapeState) : Nil
        shape.update
        shape.matrix_adapter.try { |a| a.on_data_changed = ->{ request_rebuild; nil } }
        idx = @shapes.index(shape) || 0
        step = 20.0
        cascade_x = step + step * (idx % 10) + 2 * step * (idx // 10)
        cascade_y = 2 * step + step * (idx % 10)
        # Allow tests to shrink the Shape panel via env var so small-viewport
        # regression scenarios (e.g. Amanita rank blank when matrix overflows)
        # can be reproduced without manual resizing.
        panel_width = (ENV["EMBRACE_SHAPE_PANEL_WIDTH"]?.try(&.to_f) || 1100.0)
        panel_height = (ENV["EMBRACE_SHAPE_PANEL_HEIGHT"]?.try(&.to_f) || 750.0)
        window_panel(shape.title, x: cascade_x, y: cascade_y, width: panel_width, height: panel_height, id: shape.id) do
            on_closed { shape.close; @shapes.reject! { |s| !s.open }; request_rebuild }
            register_shortcut("Alt+Left") { shape.navigate_history(-1); request_rebuild }
            register_shortcut("Alt+Right") { shape.navigate_history(1); request_rebuild }

            # Cell-op keyboard shortcuts (T-006): embrace owns the cell-op
            # meaning; these fire on the matrix cursor when the editor declines
            # the key (QuickEntry) — see with_cell_cursor. Mirror the cell
            # context-menu handlers; cell_op swallows ConditionsNotMet so a
            # shortcut on an unsuitable cursor cell (header / aggregate / wrong
            # type) no-ops cleanly.
            register_shortcut("Ctrl+X") do
                with_cell_cursor(shape) do |adapter, vm, rc|
                    if adapter.cell_has_content?(rc[0], rc[1])
                        @cut_cell = {shape.id, rc[0], rc[1]}
                        vm.drag_source_cell = {rc[0], rc[1]}
                        vm.mark_cursor_overlay_dirty
                        request_rebuild
                    end
                end
            end
            register_shortcut("Ctrl+V") do
                with_cell_cursor(shape) do |adapter, vm, rc|
                    if c = @cut_cell
                        cell_op(shape) { adapter.cell_move(c[1], c[2], rc[0], rc[1]) }
                        @cut_cell = nil
                        vm.drag_source_cell = nil
                    end
                end
            end
            register_shortcut("Insert") do
                with_cell_cursor(shape) { |adapter, _vm, rc| cell_op(shape) { adapter.cell_insert(rc) } }
            end
            register_shortcut("Delete") do
                with_cell_cursor(shape) { |adapter, _vm, rc| cell_op(shape) { adapter.cell_delete(rc) } }
            end
            register_shortcut("Ctrl+U") do
                with_cell_cursor(shape) { |adapter, _vm, rc| cell_op(shape) { adapter.cell_set_undefined(rc) } }
            end
            register_shortcut("Ctrl+T") do
                with_cell_cursor(shape) { |adapter, _vm, rc| cell_op(shape) { adapter.cell_assign(rc, true) } }
            end

            # Shape menubar
            menubar do
                menu("Edit") do
                    menu_item("Commit", "^O") { shape.do_commit; set_statusbar_info("Committed"); request_rebuild }
                    menu_item("Import table...") do
                        dialog = Dialogs::ImportTable.new("Import table...", "*.xlsx") do |filename, tablename|
                            begin
                                ctx = shape.context.dup
                                shape.persistency.contexts.push(ctx)
                                table_lid = shape.persistency.import(filename, tablename)
                                new_shape = ShapeState.new("Shape", shape.persistency, shape.persistency.context, table_lid)
                                @shapes << new_shape
                                shape.persistency.contexts.pop
                                set_statusbar_info("Import successful")
                            rescue ex
                                set_statusbar_warning("Import failed - format inappropriate")
                            end
                            request_rebuild
                        end
                        add_dialog(dialog)
                    end
                    menu_item("Add record", "^R") { shape.add_record; request_rebuild }
                end
                menu("View") do
                    # ^M is handled by sfml_renderer — show label only, no shortcut registration
                    maximize_item = menu_item("(De-)Maximize", "^M")
                    maximize_item.on_click_action = -> {
                        if panel = root.try(&.find_topmost_panel)
                            panel.toggle_maximize
                        end
                        nil
                    }
                    menu_item("Duplicate Shape", "^D") do
                        new_shape = shape.dup_shape("Shape")
                        @shapes << new_shape
                        request_rebuild
                    end
                    menu_item("Close Shape", "^W") do
                        shape.close
                        @shapes.reject! { |s| !s.open }
                        request_rebuild
                    end
                end
            end

            vstack(spacing: 5.0, padding: 5.0) do
                # History selection
                build_history_section(shape)

                separator

                # Table selection
                build_table_section(shape)

                separator

                # Configuration (VHTree)
                build_configurator_section(shape)

                separator

                # Fieldlist
                build_fieldlist_section(shape)

                separator

                # Filter (autofilter-style row filtering)
                build_filter_section(shape)

                separator

                # Matrix (data grid) — fills remaining panel space
                expanded do
                    build_matrix_section(shape)
                end

                # Diff-Shape only: flat list of records that exist at parent
                # but not at open commit, shown below the main matrix.
                if shape.diff_target_commit
                    build_diff_deleted_section(shape)
                end
            end
        end
    end

    private def build_history_section(shape : ShapeState) : Nil
        tn = tree_node("History selection", id: "history_#{shape.id}") do
            hstack(spacing: 5.0) do
                text("Branch:")
                branch_names = shape.branch_names
                if branch_names.size > 0
                    combo_box(items: branch_names, selected: shape.commit_leaf_rank, width: 120.0, id: "branch_#{shape.id}") do |index|
                        shape.select_branch(index)
                        request_rebuild
                    end
                end

                commit_idx = shape.current_commit_index
                path_size = shape.commit_path.size

                nav_back = button("<", padding: 3.0, id: "hist_back_#{shape.id}") { shape.navigate_history(-1); request_rebuild }
                nav_back.enabled = commit_idx > 0

                text("#{commit_idx + 1}/#{path_size} #{shape.is_last_commit? ? "(open)" : "(closed)"}")

                nav_fwd = button(">", padding: 3.0, id: "hist_fwd_#{shape.id}") { shape.navigate_history(1); request_rebuild }
                nav_fwd.enabled = !shape.is_last_commit?

                button("Commit!", padding: 3.0, id: "commit_#{shape.id}") do
                    # Gather the table LIDs the user unchecked for this shape
                    # — those will float forward instead of being committed.
                    defer_tables = @commit_deferred.select { |sid, _| sid == shape.id }.map { |_, tlid| tlid }.to_set
                    shape.do_commit(defer_tables)
                    # Reset this shape's selection state post-commit.
                    @commit_deferred.reject! { |sid, _| sid == shape.id }
                    if defer_tables.empty?
                        set_statusbar_info("Committed")
                    else
                        set_statusbar_info("Committed (#{defer_tables.size} table#{defer_tables.size == 1 ? "" : "s"} deferred)")
                    end
                    request_rebuild
                end

                # "Show changes" spawns a read-only diff-Shape: cells whose
                # value at the open commit differs from the parent commit are
                # highlighted; a separate section below lists records that
                # existed at the parent but not at the open commit.
                if shape.is_last_commit?
                    show_diff = button("Show changes", padding: 3.0, id: "show_diff_#{shape.id}") do
                        if diff = shape.spawn_diff_shape
                            @shapes << diff
                            request_rebuild
                        else
                            set_statusbar_warning("No open commit to diff against")
                        end
                    end
                    show_diff.hover_text = "Open a read-only diff-Shape: highlights cells whose value differs from the parent commit; lists records deleted in this commit separately"
                end
                # Diff-Shape: toggle "Only changed" vs "Show all records"
                if shape.diff_target_commit
                    label = shape.diff_show_changed_only ? "Show all records" : "Only changed"
                    toggle = button(label, padding: 3.0, id: "diff_toggle_#{shape.id}") do
                        shape.diff_show_changed_only = !shape.diff_show_changed_only
                        request_rebuild
                    end
                    toggle.hover_text = "Toggle between showing only records with writes in this commit and all records"
                end
            end

            # Pending-changes summary: one row per touched table, sorted by
            # name, with columns (checkbox+name | +R | +F | cells | → Shape).
            # Wrapped in a scroll_view so the history section stays bounded
            # when many tables are touched (defaults to ~200px height).
            if shape.is_last_commit?
                @persistency.contexts.push(shape.context)
                changes = @persistency.changes_in_open_commit
                @persistency.contexts.pop  # read-only: just discard (don't overwrite base context)
                non_empty = changes.select { |_, tc| !tc.empty? }
                # Resolve table names once + sort alphabetically (case-insensitive).
                named_changes = non_empty.map do |table_lid, tc|
                    name_raw = @persistency.get_value(MetaFieldLIDs::Names, table_lid)
                    name = name_raw.is_a?(String) ? name_raw : "?"
                    {table_lid, name, tc}
                end.sort_by { |_, name, _| name.downcase }
                # Tristate "commit all changes" header — only shown when ≥2 change rows.
                if named_changes.size >= 2
                    captured_shape_id = shape.id
                    deferred_count = named_changes.count { |t, _, _| @commit_deferred.includes?({captured_shape_id, t}) }
                    tri_state = if deferred_count == 0
                        CrymbleUI::CheckState::Checked
                    elsif deferred_count == named_changes.size
                        CrymbleUI::CheckState::Unchecked
                    else
                        CrymbleUI::CheckState::Indeterminate
                    end
                    captured_table_lids = named_changes.map { |t, _, _| t }
                    checkbox("commit all changes", state: tri_state, id: "changes_check_all_#{captured_shape_id}") do
                        if tri_state == CrymbleUI::CheckState::Checked
                            # Defer everything for this shape.
                            captured_table_lids.each { |t| @commit_deferred.add({captured_shape_id, t}) }
                        else
                            # Commit everything: clear all deferred entries for this shape.
                            captured_table_lids.each { |t| @commit_deferred.delete({captured_shape_id, t}) }
                        end
                        request_rebuild
                    end
                end
                # Sugared VirtualMatrix with sticky header, size-to-content
                # (200 px cap), content-fit columns.
                matrix(id: "changes_#{shape.id}", max_height: 200.0) do |m|
                    m.header "", "Table", "Records", "Fields", "Cells", ""
                    named_changes.each do |table_lid, table_name, tc|
                        captured_table_lid = table_lid
                        captured_shape_id = shape.id
                        checked = !@commit_deferred.includes?({captured_shape_id, captured_table_lid})
                        # git-style +/- for records and fields. Cells stay as
                        # a single counter — value-edit semantics don't have a
                        # natural add/remove split.
                        r_str = format_added_removed(tc.records_added, tc.records_removed)
                        f_str = format_added_removed(tc.fields_added, tc.fields_removed)
                        c_str = tc.cells_changed > 0 ? tc.cells_changed.to_s : ""
                        m.row do |r|
                            r << CrymbleUI::Checkbox.new(text: "", checked: checked, id: "changes_check_#{captured_shape_id}_#{captured_table_lid}") do
                                if checked
                                    @commit_deferred.add({captured_shape_id, captured_table_lid})
                                else
                                    @commit_deferred.delete({captured_shape_id, captured_table_lid})
                                end
                                request_rebuild
                            end.as(CrymbleUI::Widget)
                            r.text(table_name)
                            r.text(r_str)
                            r.text(f_str)
                            r.text(c_str)
                            r << CrymbleUI::Button.new("→ Shape", padding: 3.0, id: "changes_to_shape_#{captured_shape_id}_#{captured_table_lid}") do
                                shape_add_for_table(captured_table_lid)
                            end.as(CrymbleUI::Widget)
                        end
                    end
                end
            end
        end
        tn.children.first?.try &.hover_text = "Select history branch and/or generation in it ('H' in Shape)"
    end

    private def build_table_section(shape : ShapeState) : Nil
        tn = tree_node("Table selection", expanded: true, id: "table_#{shape.id}") do
            picker = shape.widget_table_picker
            hstack(spacing: 5.0) do
                text("Table:")
                cb = combo_box(items: picker.names, selected: picker.lid_index, width: 200.0, id: "tablepick_#{shape.id}") do |index|
                    picker.select_index(index)
                    shape.update(true)
                    request_rebuild
                end
                cb.on_right_click_handler = ->(pos : CrymbleUI::Vec2) {
                    if tlid = picker.lid
                        table_name = picker.names[picker.lid_index]? || "?"
                        show_table_context_menu(shape, nil, tlid, table_name, pos)
                    end
                    nil
                }

                if picker.allow_create?
                    button("Add table...", padding: 3.0, id: "addtable_#{shape.id}") do
                        captured_shape = shape
                        captured_picker = picker
                        dialog = Dialogs::Creator.new("Add table") do |name|
                            captured_picker.add_table(name)
                            captured_shape.update(true)
                            request_rebuild
                        end
                        add_dialog(dialog)
                    end
                end
            end
        end
        tn.children.first?.try &.hover_text = "Select initial table for upcoming exploration"
    end

    private def build_configurator_section(shape : ShapeState) : Nil
        tn = tree_node("Configuration", id: "config_#{shape.id}") do
            if shape.vhtree_adapter
                build_vhtree(shape)
            else
                text("(select a table first)")
            end
        end
        tn.children.first?.try &.hover_text = "Explore linked tables inside structure and select relevant fields ('S' in Shape)"
    end

    private def build_vhtree(shape : ShapeState) : Nil
        layout = VHTreeLayout.new(id: "vhtree_#{shape.id}")
        widget(layout)
        with_container(layout) do
            shape.dfs_tree do |node, level|
                layout.add_node_info(node, level)
                is_draggable = node.drag
                is_drop_target = !node.is_pseudo_field? && (node.is_table? ? node.is_expandable? : true)
                captured_node = node
                captured_shape = shape

                # Compute row background color for this node
                selected = node.is_selected?
                is_sel = (selected == true || selected == Some)
                row_bg = is_sel ? VHTreeLayout.selected_bg : VHTreeLayout.unselected_bg

                # Right-click handler for context menus + hover text
                right_click = make_vhtree_right_click_handler(captured_shape, captured_node)
                display = node.get_display_texts[1]? || ""
                hover = if node.is_a?(SimpleVHTreeAdapter)
                    a = node.as(SimpleVHTreeAdapter)
                    a.is_table? ? "table '#{display}'" : (a.is_pseudo_field? ? "pseudofield '#{display}'" : "field '#{display}'")
                else
                    display
                end

                if is_drop_target && is_draggable
                    dz = drop_zone(accept_types: ["vhtree_field"], on_drop: ->(data : CrymbleUI::DragData, pos : CrymbleUI::Vec2) {
                        handle_vhtree_drop(captured_shape, data, captured_node, pos)
                    }, background_color: row_bg, id: "dz_#{node.object_id}") do
                        draggable(data: VHTreeDragData.new(node.as(SimpleVHTreeAdapter)), id: "drag_#{node.object_id}") do
                            build_vhtree_row_content(shape, node, level)
                        end
                    end
                    dz.on_right_click_handler = right_click
                    dz.hover_text = hover
                elsif is_drop_target
                    dz = drop_zone(accept_types: ["vhtree_field"], on_drop: ->(data : CrymbleUI::DragData, pos : CrymbleUI::Vec2) {
                        handle_vhtree_drop(captured_shape, data, captured_node, pos)
                    }, background_color: row_bg, id: "dz_#{node.object_id}") do
                        build_vhtree_row_content(shape, node, level)
                    end
                    dz.on_right_click_handler = right_click
                    dz.hover_text = hover
                elsif is_draggable
                    dz = drop_zone(accept_types: [] of String, background_color: row_bg, id: "dz_#{node.object_id}") do
                        draggable(data: VHTreeDragData.new(node.as(SimpleVHTreeAdapter)), id: "drag_#{node.object_id}") do
                            build_vhtree_row_content(shape, node, level)
                        end
                    end
                    dz.on_right_click_handler = right_click
                    dz.hover_text = hover
                else
                    dz = drop_zone(accept_types: [] of String, background_color: row_bg, id: "dz_#{node.object_id}") do
                        build_vhtree_row_content(shape, node, level)
                    end
                    dz.on_right_click_handler = right_click
                    dz.hover_text = hover
                end
            end
        end
    end

    VHTREE_BTN_PAD = 2.0

    private def build_vhtree_row_content(shape : ShapeState, node : Interface::GUI::VHTreeAdapter, level : Int32 = 0) : Nil
        selectable = node.is_selectable?
        selected = node.is_selected?
        is_sel = (selected == true || selected == Some)
        check_state = case selected
                      when true then CrymbleUI::CheckState::Checked
                      when Some then CrymbleUI::CheckState::Indeterminate
                      else           CrymbleUI::CheckState::Unchecked
                      end
        row_bg = is_sel ? VHTreeLayout.selected_bg : VHTreeLayout.unselected_bg
        text_color = selectable ? VHTreeLayout.text_color : VHTreeLayout.text_color_dim
        hstack(spacing: 0.0, background_color: row_bg) do
            texts = node.get_display_texts

            # Expand/collapse arrow — only in referenced-table columns (halflevel > 0)
            # Field nodes with ► prefix get a clickable arrow; all other rows get a spacer
            has_arrow_prefix = texts.size >= 1 && (texts[0].includes?("►") || texts[0].includes?("◄"))
            if level // 2 > 0
                if has_arrow_prefix
                    arrow_char = texts[0].includes?("►") ? "►" : "◄"
                    button(arrow_char, padding: VHTREE_BTN_PAD,
                        text_color: text_color,
                        background_color: row_bg, border_color: row_bg,
                        id: "exp_#{node.object_id}") do
                        node.toggle_expand
                        shape.update(true)
                        request_rebuild
                    end
                else
                    # Spacer with same width as arrow button for alignment
                    button(" ", padding: VHTREE_BTN_PAD,
                        text_color: row_bg,
                        background_color: row_bg, border_color: row_bg,
                        id: "spc_#{node.object_id}") do
                    end
                end
            end

            # Selection checkbox (always shown; disabled when not selectable)
            cb = checkbox("", state: check_state, id: "sel_#{node.object_id}") do
                node.toggle_select
                shape.update(true)
                request_rebuild
            end
            cb.enabled = selectable

            # Name: in columns with arrow column, skip prefix (arrow handles it)
            name = if texts.size >= 2
                       level // 2 > 0 ? texts[1] : "#{texts[0]}#{texts[1]}"
                     elsif texts.size == 1
                       texts[0]
                     else
                       ""
                     end
            expanded do
                button(name, padding: VHTREE_BTN_PAD,
                    text_color: text_color,
                    text_align: CrymbleUI::TextAlign::Left,
                    background_color: row_bg, border_color: row_bg,
                    id: "name_#{node.object_id}") do
                    if selectable
                        node.toggle_select
                        shape.update(true)
                        request_rebuild
                    end
                end
            end

            # Links postfix (e.g., "◄0,►1 +") — also handles expand/collapse
            if texts.size >= 3 && texts[2] != ""
                button(texts[2], padding: VHTREE_BTN_PAD,
                    text_color: text_color,
                    background_color: row_bg, border_color: row_bg,
                    id: "links_#{node.object_id}") do
                    if node.is_expandable?
                        node.toggle_expand
                        shape.update(true)
                        request_rebuild
                    end
                end
            end
        end
    end

    private def build_fieldlist_section(shape : ShapeState) : Nil
        tn = tree_node("Field list", id: "fieldlist_#{shape.id}") do
            if adapter = shape.fieldlist_adapter
                vstack(spacing: 5.0) do
                    hstack(spacing: 5.0) do
                        button("Empty", padding: 3.0, id: "fl_empty_#{shape.id}") { shape.fieldlist_empty!; request_rebuild }
                        button("Normalize", padding: 3.0, id: "fl_norm_#{shape.id}") { shape.fieldlist_normalize!; request_rebuild }
                    end
                    hstack(spacing: 5.0) do
                        text("Mirror...")
                        button("horizontal", padding: 3.0, id: "fl_mirh_#{shape.id}") { shape.fieldlist_mirror_horizontal!; request_rebuild }
                        button("vertical", padding: 3.0, id: "fl_mirv_#{shape.id}") { shape.fieldlist_mirror_vertical!; request_rebuild }
                        button("diagonal", padding: 3.0, id: "fl_mird_#{shape.id}") { shape.fieldlist_mirror_diagonal!; request_rebuild }
                        checkbox("including aggregate?", checked: shape.mirror_aggregates, id: "fl_miragg_#{shape.id}") do
                            shape.mirror_aggregates = !shape.mirror_aggregates
                            request_rebuild
                        end
                    end
                    # Fieldlist grid (Milestone 1: simple table)
                    build_fieldlist_grid(shape, adapter)
                end
            else
                text("(select a table first)")
            end
        end
        tn.children.first?.try &.hover_text = "Configure roles of selected relevant fields for upcoming perspective"
    end

    # User-visible rendering of a cell value for the Filter UI.
    # ReferenceCell shows its referenced value; others use their native to_s.
    private def filter_value_display(value : Cell) : String
        value.is_a?(ReferenceCell) ? value.value.to_s : value.to_s
    end

    private def build_filter_section(shape : ShapeState) : Nil
        tn = tree_node("Filter", id: "filter_#{shape.id}") do
            if shape.matrix_adapter
                names = shape.column_names
                existing = shape.filter_state.map(&.column_index).to_set
                vstack(spacing: 5.0) do
                    # Header row: per-column "add filter" buttons + clear all
                    hstack(spacing: 5.0) do
                        text("Add filter:")
                        names.each_with_index do |col_name, i|
                            next if existing.includes?(i)
                            next if col_name.empty?
                            button(col_name, padding: 3.0, id: "filter_add_#{i}_#{shape.id}") do
                                # Default: all values selected (no rows hidden until user narrows)
                                all_values = shape.column_distinct_values(i).map(&.[0]).to_set
                                shape.filter_add(i, all_values)
                                request_rebuild
                            end
                        end
                        if !shape.filter_state.empty?
                            button("Clear all", padding: 3.0, id: "filter_clear_#{shape.id}") do
                                shape.filter_clear!
                                request_rebuild
                            end
                        end
                    end
                    if shape.filter_state.empty?
                        text("(no filters — all rows visible)")
                    else
                        # One section per active filter: column name + remove button, then
                        # per-value checkboxes chunked into rows so long value sets wrap.
                        shape.filter_state.each do |cf|
                            col_name = names[cf.column_index]? || "?"
                            # Sort lexicographically by display text so the picker is predictable
                            distinct = shape.column_distinct_values(cf.column_index).sort_by { |v, _| filter_value_display(v).downcase }
                            total_count = distinct.size
                            search_key = {shape.id, cf.column_index}
                            search_str = @filter_search[search_key]
                            # Narrow visible values by case-insensitive substring match.
                            search_lc = search_str.downcase
                            visible = search_lc.empty? ? distinct : distinct.select { |v, _| filter_value_display(v).downcase.includes?(search_lc) }
                            # Tristate state across visible values.
                            visible_values = visible.map(&.[0]).to_set
                            selected_visible = cf.selected_values & visible_values
                            tri_state = if selected_visible.empty?
                                CrymbleUI::CheckState::Unchecked
                            elsif selected_visible.size == visible_values.size
                                CrymbleUI::CheckState::Checked
                            else
                                CrymbleUI::CheckState::Indeterminate
                            end
                            tri_label = search_lc.empty? ? "all (#{total_count})" : "all (#{visible.size}/#{total_count})"
                            captured_col_idx = cf.column_index
                            captured_visible_values = visible_values
                            captured_search_key = search_key
                            vstack(spacing: 2.0, id: "filter_row_#{cf.column_index}_#{shape.id}") do
                                hstack(spacing: 8.0) do
                                    button("remove “#{col_name}” filter",
                                           padding: 3.0,
                                           id: "filter_remove_#{cf.column_index}_#{shape.id}") do
                                        shape.filter_remove(captured_col_idx)
                                        @filter_search.delete(captured_search_key)
                                        request_rebuild
                                    end
                                    text_input(value: search_str, width: 160.0, placeholder: "search…",
                                               id: "filter_search_#{cf.column_index}_#{shape.id}") do |new_value|
                                        @filter_search[captured_search_key] = new_value
                                        request_rebuild
                                    end
                                end
                                # Adaptive wrap: flow packs as many checkboxes per row as fit
                                # the panel width, reflows on resize. Tristate "all" is the
                                # first chip so it wraps naturally with the rest.
                                flow(hspacing: 8.0, vspacing: 4.0) do
                                    checkbox(tri_label, state: tri_state,
                                             id: "filter_all_#{cf.column_index}_#{shape.id}") do
                                        current = shape.filter_state[shape.filter_state.index! { |x| x.column_index == captured_col_idx }].selected_values.dup
                                        if tri_state == CrymbleUI::CheckState::Checked
                                            # Deselect all visible (leave hidden-but-selected alone)
                                            captured_visible_values.each { |v| current.delete(v) }
                                        else
                                            # Select all visible (add to existing)
                                            captured_visible_values.each { |v| current.add(v) }
                                        end
                                        shape.filter_set_values(captured_col_idx, current)
                                        request_rebuild
                                    end
                                    visible.each do |value, count|
                                        is_checked = cf.selected_values.includes?(value)
                                        label = "#{filter_value_display(value)} (#{count})"
                                        checkbox(label, checked: is_checked,
                                                 id: "filter_value_#{cf.column_index}_#{value.hash}_#{shape.id}") do
                                            cur = shape.filter_state[shape.filter_state.index! { |x| x.column_index == captured_col_idx }].selected_values.dup
                                            if cur.includes?(value)
                                                cur.delete(value)
                                            else
                                                cur.add(value)
                                            end
                                            shape.filter_set_values(captured_col_idx, cur)
                                            request_rebuild
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            else
                text("(select a table first)")
            end
        end
        tn.children.first?.try &.hover_text = "Narrow rows by column values (autofilter: OR within column, AND between columns)"
    end

    private def build_matrix_section(shape : ShapeState) : Nil
        tn = tree_node("Perspective", expanded: true, id: "matrix_#{shape.id}") do
            if shape.matrix_adapter
                vstack(spacing: 5.0) do
                    hstack(spacing: 5.0) do
                        button("Add field", padding: 3.0, id: "mx_addf_#{shape.id}") { shape.add_field_simple; request_rebuild }
                        button("...", padding: 3.0, id: "mx_addf_dlg_#{shape.id}") do
                            dialog = Dialogs::AddField.new("Add new field", shape.persistency, shape.context) do |name, ref_field_lid|
                                shape.add_field_custom(name, ref_field_lid)
                                request_rebuild
                            end
                            add_dialog(dialog)
                        end
                        button("Add record", padding: 3.0, id: "mx_addr_#{shape.id}") { shape.add_record; request_rebuild }
                    end

                    # Matrix grid via VirtualMatrix (virtual scrolling, sticky headers, cursor nav)
                captured_shape = shape
                expanded do
                    vm = widget(CrymbleUI::VirtualMatrix.new(
                        adapter: shape.matrix_adapter.not_nil!,
                        id: "matrix_grid_#{shape.id}",
                    ))
                    shape.matrix_adapter.try &.virtual_matrix = vm.as(CrymbleUI::VirtualMatrix)
                    # Restore cut highlight from @cut_cell (survives rebuild)
                    if (cc = @cut_cell) && cc[0] == shape.id
                        vm.as(CrymbleUI::VirtualMatrix).drag_source_cell = {cc[1], cc[2]}
                        vm.as(CrymbleUI::VirtualMatrix).drag_source_was_preexisting = true
                    end
                    vm.on_right_click_handler = ->(pos : CrymbleUI::Vec2) {
                        show_cell_context_menu(captured_shape, pos)
                        nil
                    }
                    vm.as(CrymbleUI::VirtualMatrix).on_cell_drop_handler = -> {
                        captured_shape.update(true)
                        request_rebuild
                        nil
                    }
                    # Double-click on a Drilldown cell (aggregate over >1 basic rows)
                    # spawns a new Shape with filters pre-populated from the cell's
                    # cluster keys. Returns true to suppress the default proxy
                    # forwarding (which would try to open edit/combo mode).
                    vm.as(CrymbleUI::VirtualMatrix).on_cell_activate = ->(rc : Tuple(Int32, Int32)) {
                        shape_drill_from_cell(captured_shape, rc) != nil
                    }
                end
                end # vstack
            else
                text("(select a table first)")
            end
        end
        tn.children.first?.try &.hover_text = "(Editable) perspective of prior selections ('P' and 'E' in Shape)"
    end

    # Format a (added, removed) count pair as "+a/-r", "+a", "-r", or "" when
    # both are zero. Used in the History changes summary, mirroring git's
    # +12/-3 notation alongside filenames.
    private def format_added_removed(added : Int32, removed : Int32) : String
        return "" if added == 0 && removed == 0
        return "+#{added}" if removed == 0
        return "-#{removed}" if added == 0
        "+#{added}/-#{removed}"
    end

    # Renders a flat read-only list of records that exist at the parent commit
    # but not at the open commit — i.e. records deleted during this commit.
    # Only meaningful on a diff-Shape; build_shape_panel guards the call.
    private def build_diff_deleted_section(shape : ShapeState) : Nil
        deleted = shape.diff_deleted_records
        label = "Records deleted (#{deleted.try(&.size) || 0})"
        expanded_default = deleted && !deleted.empty?
        tn = tree_node(label, expanded: expanded_default ? true : false, id: "diff_deleted_#{shape.id}") do
            if deleted && !deleted.empty?
                # Stable field order: the order persistency.get_field_lids returned
                # at parent context when the deleted map was built (Crystal Hash
                # preserves insertion order).
                deleted.each do |(rec_lid, field_values)|
                    hstack(spacing: 8.0, id: "diff_deleted_row_#{shape.id}_#{rec_lid.to_s}") do
                        field_values.each do |_fid, val|
                            text(val.to_s)
                        end
                    end
                end
            else
                text("(none — no records were deleted in this commit)")
            end
        end
        tn.children.first?.try &.hover_text = "Records present at the parent commit but absent at the open commit — deletions this commit"
    end

    # === Shape Management ===

    # shape_add, file ops, dialog/context menu helpers → extracted files
    # === Splash Overlay ===

    def overlay_primitives(window_width : Float64, window_height : Float64) : Array(CrymbleUI::DrawPrimitive)?
        # Lazy-start the splash timer on first render so it survives slow init.
        splash_start = (@splash_start ||= Time.instant)
        delta = (Time.instant - splash_start).total_seconds
        return nil if delta >= SPLASH_STAGES.last

        # Start splash animation timer on first call (scheduler not available in initialize)
        if @splash_timer_id.nil?
            @splash_timer_id = CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 33_000_000), repeating: true) do
                if (Time.instant - splash_start).total_seconds >= SPLASH_STAGES.last
                    if tid = @splash_timer_id
                        CrymbleUI::Widget.scheduler.cancel(tid)
                        @splash_timer_id = nil
                        # Force one clean redraw without overlay
                        root.try &.mark_needs_render
                    end
                end
            end
        end

        # Find current stage
        stage = SPLASH_STAGES.bsearch_index { |x| x > delta } || SPLASH_STAGES.size
        stage -= 1
        v1 = SPLASH_STAGES[stage]
        v2 = SPLASH_STAGES[stage + 1]?
        gain = v2 ? (delta - v1) / (v2 - v1) : 0.0

        # Calculate alpha values for logo and flash
        alpha1 = alpha2 = 0
        case stage
        when 0 then alpha1 = (255 * gain).to_i32     # Logo fade in
        when 1 then alpha1 = 255; alpha2 = (255 * gain).to_i32  # Logo + white flash in
        when 2 then alpha1 = 255; alpha2 = (255 * (1 - gain)).to_i32  # Logo + white flash out
        when 3 then alpha1 = 255                       # Logo hold
        when 4 then alpha1 = (255 * (1 - gain)).to_i32 # Logo fade out
        end

        prims = [] of CrymbleUI::DrawPrimitive

        # Logo image centered on screen
        if alpha1 > 0
            # Logo is 800x800, display at generous size
            logo_w, logo_h = 600.0, 600.0
            logo_x = (window_width - logo_w) / 2.0
            logo_y = (window_height - logo_h) / 2.0
            color = CrymbleUI::Color.new(255_u8, 255_u8, 255_u8, alpha1.clamp(0, 255).to_u8)
            prims << CrymbleUI::DrawImage.new("resources/logo-embrace-h3o.png",
                CrymbleUI::Rect.new(logo_x, logo_y, logo_w, logo_h), color)
        end

        # White flash overlay (full screen)
        if alpha2 > 0
            color = CrymbleUI::Color.new(255_u8, 255_u8, 255_u8, alpha2.clamp(0, 255).to_u8)
            prims << CrymbleUI::FillRect.new(
                CrymbleUI::Rect.new(0.0, 0.0, window_width, window_height), color)
        end

        prims.empty? ? nil : prims
    end

    # === Statusbar ===

    private def statusbar_info_color; CrymbleUI::Theme.current["statusbar.info"]; end
    private def statusbar_warning_color; CrymbleUI::Theme.current["statusbar.warning"]; end

    protected def set_statusbar_info(text : String)
        set_statusbar_priority(text, statusbar_info_color, 5)
    end

    protected def set_statusbar_warning(text : String)
        set_statusbar_priority(text, statusbar_warning_color, 5)
    end

    private def set_statusbar_priority(text : String, color : CrymbleUI::Color, duration : Int32)
        @statusbar_priority_text = text
        @statusbar_color = color
        @statusbar_priority_remaining = duration

        # Cancel old timer
        if old_tid = @statusbar_timer_id
            CrymbleUI::Widget.scheduler.cancel(old_tid)
        end

        # Schedule countdown via global scheduler (wakes SFML event loop)
        @statusbar_timer_id = CrymbleUI::Widget.scheduler.schedule(Time::Span.new(seconds: 1), repeating: true) do
            @statusbar_priority_remaining -= 1
            if @statusbar_priority_remaining <= 0
                @statusbar_priority_remaining = 0
                @statusbar_text = ""
                if tid = @statusbar_timer_id
                    CrymbleUI::Widget.scheduler.cancel(tid)
                    @statusbar_timer_id = nil
                end
            end
            # Update statusbar widget directly (render-only, no rebuild)
            if sb = find("statusbar").as?(CrymbleUI::StatusBar)
                if @statusbar_priority_remaining > 0
                    sb.text = "(#{@statusbar_priority_remaining}) #{@statusbar_priority_text}"
                    sb.text_color = @statusbar_color
                else
                    sb.text = ""
                    sb.text_color = CrymbleUI::Theme.current.statusbar_text
                end
            end
        end
    end

end
