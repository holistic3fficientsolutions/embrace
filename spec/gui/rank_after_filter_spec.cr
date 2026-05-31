require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Regression spec for the user-reported "Amanita Rank blank after filter
# deselect" scenario. Reproduces the exact GUI sequence from the screenshot
# /tmp/2026-04-22_06-51.png:
#   load demo (do_newfile_demo) → Allocations Shape → expand Projects filter
#   (all values selected) → type "c" in filter search → deselect Curiosity →
#   wheel-scroll Perspective down.
# The bug: the last visible row's first data cell (c1 = Rank) renders BLANK
# while all other rank cells show their values.

# Replicates do_newfile_demo (src/gui/embrace_file_ops.cr:80) verbatim, so
# the persistency state matches what the user sees. Returns the Allocations
# TableLID so the test can select it as the primary Shape table.
private def make_demo_app : {EmbraceApp, TableLID}
    app = EmbraceApp.new
    persistency = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Cities
        City | Country
        Arizona | USA
        Boston | USA
        Chicago | USA
        Dalbreck | Remnant Kingdoms
        Mordor | Middle-earth
        Morrighan | Remnant Kingdoms
        New York | USA
        Reykjavik | Iceland
        San Francisco | USA
        Shire | Middle-earth
        Venda | Remnant Kingdoms
        unknown | unknown

        Times
        Time
        Former
        Future
        Present

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

        Persons
        Person | City_City
        Alan | Boston
        Amanita | San Francisco
        Denny | Boston
        Helen | New York
        Jared | Arizona
        Jezelia | Morrighan
        Kaden | Venda
        Max | New York
        Melanie | Arizona
        Rafferty | Dalbreck
        Riley | Reykjavik
        Samwise | Shire
        Sauron | Mordor
        Wanda | unknown
        Will | Chicago

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
    alloc_lid = hash["Allocations"].as(TableLID)
    app.shapes.clear
    ctx = persistency.context.clone
    app.shapes << ShapeState.new("Allocations", persistency, ctx, alloc_lid)
    app.request_rebuild
    {app, alloc_lid}
end

private def scroll_perspective_down(app : EmbraceApp, ticks : Int32, delta : Float64 = -1.0) : Nil
    shape = app.shapes.first
    vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
    pt = CrymbleUI::Vec2.new(
        vm.absolute_bounds.x + vm.absolute_bounds.width / 2,
        vm.absolute_bounds.y + vm.absolute_bounds.height / 2,
    )
    ticks.times do
        vm.on_mouse_wheel(CrymbleUI::Vec2.new(0.0, delta), pt)
        app.request_rebuild
    end
end

private def scroll_perspective_up(app : EmbraceApp, ticks : Int32, delta : Float64 = 1.0) : Nil
    shape = app.shapes.first
    vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
    pt = CrymbleUI::Vec2.new(
        vm.absolute_bounds.x + vm.absolute_bounds.width / 2,
        vm.absolute_bounds.y + vm.absolute_bounds.height / 2,
    )
    ticks.times do
        vm.on_mouse_wheel(CrymbleUI::Vec2.new(0.0, delta), pt)
        app.request_rebuild
    end
end

private def click_widget(app : EmbraceApp, id : String) : Nil
    w = app.find(id) || raise "Widget '#{id}' not found"
    bounds = w.absolute_bounds
    center = CrymbleUI::Vec2.new(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
    app.handle_mouse_down(center)
    app.handle_mouse_up(center)
end

# Drive the filter flow the user's way: click the "Project" filter-add
# button, type "c" into the search input, then click the Curiosity
# checkbox to deselect. All via the full event path (not direct APIs) so
# rebuild timing and widget invalidation match the real GUI.
private def apply_projects_minus_curiosity(app : EmbraceApp, renderer : CrymbleUI::Testing::TestRenderer) : Nil
    shape = app.shapes.first
    project_col = shape.column_names.index("Project") || shape.column_names.index("Project_Project")
    raise "Project column not found" if project_col.nil?

    # Step 0: expand the "Filter" tree_node (collapsed by default) — the
    # user's "expand filter" step. Without this, the filter_add buttons
    # aren't rendered yet.
    click_widget(app, "filter_#{shape.id}")
    renderer.settle_rendering(app)

    # Step 1: click the "Project" button in the "Add filter" row.
    filter_add_id = "filter_add_#{project_col}_#{shape.id}"
    click_widget(app, filter_add_id)
    renderer.settle_rendering(app)

    # Step 2: focus the search input and type "c" one character at a time
    # through the focus manager — each char triggers its own rebuild, exactly
    # as typing does in the real GUI.
    search_id = "filter_search_#{project_col}_#{shape.id}"
    search_widget = app.find(search_id) || raise "search input '#{search_id}' not found"
    bounds = search_widget.absolute_bounds
    app.handle_mouse_down(CrymbleUI::Vec2.new(bounds.x + 5, bounds.y + bounds.height / 2))
    app.handle_mouse_up(CrymbleUI::Vec2.new(bounds.x + 5, bounds.y + bounds.height / 2))
    renderer.settle_rendering(app)
    CrymbleUI::Widget.focus_manager.handle_text_input('c')
    app.request_rebuild
    renderer.settle_rendering(app)

    # Step 3: find Curiosity's ReferenceCell and click its checkbox (by hash).
    all_values = shape.column_distinct_values(project_col).map(&.[0]).to_set
    curiosity = all_values.find do |v|
        v.is_a?(ReferenceCell) ? v.value.to_s.includes?("Curiosity") : v.to_s.includes?("Curiosity")
    end
    raise "Curiosity value not found" if curiosity.nil?
    curiosity_id = "filter_value_#{project_col}_#{curiosity.hash}_#{shape.id}"
    click_widget(app, curiosity_id)
    renderer.settle_rendering(app)
end

describe "Amanita Rank cell after filter deselect" do
    # Reproduce the user's Shape panel size from /tmp/2026-04-22_06-51.png —
    # significantly smaller than the hardcoded 1100×750, so the matrix
    # viewport barely fits 13 rows and deselecting Curiosity (14 records →
    # 1-row overflow) requires scrolling, triggering the cache bug.
    around_all do |example|
        ENV["EMBRACE_SHAPE_PANEL_WIDTH"] = "680"
        ENV["EMBRACE_SHAPE_PANEL_HEIGHT"] = "550"
        # FocusManager is normally initialized by SfmlRenderer; TestRenderer
        # doesn't, so typed text input via Widget.focus_manager would crash.
        CrymbleUI::Widget.focus_manager = CrymbleUI::FocusManager.new
        example.run
        ENV.delete("EMBRACE_SHAPE_PANEL_WIDTH")
        ENV.delete("EMBRACE_SHAPE_PANEL_HEIGHT")
    end

    it "(a) adapter returns a non-nil Rank value for every visible row" do
        app, _lid = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        apply_projects_minus_curiosity(app, renderer)
        renderer.settle_rendering(app)
        scroll_perspective_down(app, 3)
        renderer.settle_rendering(app)

        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        matrix_size = shape.matrix_userdata_rc.not_nil!.size
        matrix_size[0].times do |row|
            adapter.cell_read({row, 0}).should_not be_nil, "row #{row}: Rank is nil"
        end
    end

    it "(b) every visible row has a widget in @active_cells (incl. last row)" do
        app, _lid = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        apply_projects_minus_curiosity(app, renderer)
        renderer.settle_rendering(app)
        scroll_perspective_down(app, 3)
        renderer.settle_rendering(app)

        shape = app.shapes.first
        vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
        matrix_size = shape.matrix_userdata_rc.not_nil!.size
        last_row = matrix_size[0] - 1
        col0_keys = vm.active_cells.keys.select { |k| k[1] == 0 }.sort
        col0_keys.should contain({last_row, 0}),
            "Amanita's Rank cell (#{last_row}, 0) missing from active_cells"
    end

    it "(c) sticky_col backend has ink for every visible rank row" do
        app, _lid = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        # Pre-populate widget_backend cache by scrolling up/down BEFORE filter.
        # This ensures cells have wb that then gets invalidated by filter change —
        # matches the real GUI state where user has been looking around before filtering.
        scroll_perspective_down(app, 3)
        renderer.settle_rendering(app)
        scroll_perspective_up(app, 3)
        renderer.settle_rendering(app)

        {% if flag?(:cache_validation) %}
            CrymbleUI::CacheValidation.enable_all
            CrymbleUI::CacheValidation.clear_failures!
        {% end %}
        apply_projects_minus_curiosity(app, renderer)
        renderer.settle_rendering(app)
        # Tiny sub-pixel scroll ticks: trigger blit-plan fast path between
        # row-materialization events. With small deltas, many consecutive
        # frames hit the early-exit path where sticky_cells_can_use_blit_plan?
        # is the sole compositing decision.
        30.times do
            scroll_perspective_down(app, 1, delta: -0.2)
            renderer.settle_rendering(app)
        end
        10.times do
            scroll_perspective_up(app, 1, delta: 0.2)
            renderer.settle_rendering(app)
        end
        30.times do
            scroll_perspective_down(app, 1, delta: -0.2)
            renderer.settle_rendering(app)
        end

        # Structural invariant: compute_sticky_blit_plans records a cv
        # LayoutCache failure whenever any active sticky cell's widget.bounds
        # diverges from its canonical scroll-derived position. This catches
        # the "stale widget.bounds → widget renders at wrong/off-screen
        # coordinates" class at its source — one frame after the offending
        # layout, identically in headless and real GUI.
        {% if flag?(:cache_validation) %}
            layout_failures = CrymbleUI::CacheValidation.failures.select do |f|
                f.cache_level == CrymbleUI::CacheValidation::CacheLevel::LayoutCache
            end
            layout_failures.empty?.should be_true,
                "stale widget.bounds in active_cells over #{layout_failures.size} frame(s); see /tmp/embrace_cv_trace.log for per-cell diff. Example: #{layout_failures.first?.inspect}"
        {% end %}

        shape = app.shapes.first
        vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
        sc_layer = vm.@content_scroll_view.not_nil!.sticky_col_layer.not_nil!
        be = sc_layer.backend.not_nil!.as(CrymbleUI::Testing::TestRenderBackend)
        bg = CrymbleUI::Theme.current.grid_content_background

        vm_abs = vm.absolute_bounds
        rows_missing_ink = [] of Int32
        vm.active_cells.keys.select { |k| k[1] == 0 }.sort.each do |key|
            row, _ = key
            next if row == 0  # column-header row
            widget = vm.active_cells[key]
            abs = widget.absolute_bounds
            # Only user-visible rows (partially inside VM viewport).
            next if abs.y + abs.height <= vm_abs.y || abs.y >= vm_abs.y + vm_abs.height
            # Backend is layer-local; widget.abs gives global → subtract layer.bounds.
            cx = (abs.x - sc_layer.bounds.x + abs.width / 2).to_i
            cy = (abs.y - sc_layer.bounds.y + abs.height / 2).to_i
            next if cx < 0 || cy < 0 || cx >= be.width || cy >= be.height

            any_ink = false
            (-5..5).each do |dy|
                (-30..30).each do |dx|
                    px = be.get_pixel(cx + dx, cy + dy)
                    next unless px
                    dr = (px.r.to_i - bg.r.to_i).abs
                    dg = (px.g.to_i - bg.g.to_i).abs
                    db = (px.b.to_i - bg.b.to_i).abs
                    any_ink = true if dr + dg + db > 30
                end
            end
            rows_missing_ink << row unless any_ink
        end
        rows_missing_ink.empty?.should be_true,
            "rank rows with no ink (blank): #{rows_missing_ink.inspect}"
    end
end
