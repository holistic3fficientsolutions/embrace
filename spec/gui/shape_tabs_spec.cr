require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# View > "Shape config on one page" (main window, global).
#
# ON (the default) is the layout embrace has always had: table picker, configurator, fieldlist
# and filter stacked directly above the perspective, so a change and its effect are visible in
# the same frame. That is what makes a screenshot or a video teach, and it is why the config was
# never tucked away in the first place.
#
# OFF puts config on its own tab and gives the perspective the whole panel. History stays
# outside the tabs either way: it is navigation, and its effect on the perspective is as
# immediate as the configurator's.
private def make_app : Tuple(EmbraceApp, CrymbleUI::Testing::TestRenderer)
    app = EmbraceApp.new
    p = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        Notes
        Name | Body
        Al | alpha
        Bo | beta
    EOT
    app.shapes.clear
    app.shapes << ShapeState.new("N", p, p.context.clone, hash["Notes"].as(TableLID))
    app.request_rebuild
    renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
    renderer.settle_rendering(app)
    {app, renderer}
end

private def toggle_tabs(app, renderer)
    app.find("shape_config_one_page").not_nil!.as(CrymbleUI::MenuItem).trigger_click
    renderer.settle_rendering(app)
end

describe "Shape config on one page" do
    original_font = CrymbleUI::Widget.font
    before_each { CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new }
    after_each { CrymbleUI::Widget.font = original_font }

    it "is on by default, and the panel then has no tabs" do
        app, _ = make_app
        shape = app.shapes.first
        app.find("shape_tabs_#{shape.id}").should be_nil
        app.find("filter_#{shape.id}").should_not be_nil # config is on the page
    end

    it "moves config onto a tab when switched off, leaving the perspective forward" do
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)

        tabs = app.find("shape_tabs_#{shape.id}")
        tabs.should_not be_nil
        tabs.not_nil!.as(CrymbleUI::Tabs).active.should eq(0) # perspective is tab 0
    end

    it "puts history on the Config tab too - the panel title already summarises it" do
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)

        history = app.find("hist_back_#{shape.id}").not_nil!
        # INSIDE the tab set: walked, not assumed.
        tabs = app.find("shape_tabs_#{shape.id}").not_nil!
        inside = false
        ancestor = history.parent
        while ancestor
            inside = true if ancestor.same?(tabs)
            ancestor = ancestor.parent
        end
        inside.should be_true
    end

    it "drops the Perspective tree node in tab mode - the tab already says it" do
        app, renderer = make_app
        shape = app.shapes.first
        app.find("matrix_#{shape.id}").should_not be_nil # one-page keeps it

        toggle_tabs(app, renderer)

        app.find("matrix_#{shape.id}").should be_nil
        app.find("matrix_grid_#{shape.id}").should_not be_nil # the grid itself is still there
    end

    it "opens every config section in tab mode, so nothing needs a click to be seen" do
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)

        {"history", "table", "config", "fieldlist", "filter"}.each do |section|
            node = app.find("#{section}_#{shape.id}")
            node.should_not be_nil
            node.not_nil!.as(CrymbleUI::TreeNode).expanded.should be_true
        end
    end

    it "keeps the hidden config tab's widgets findable, so nothing in it goes dark" do
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)

        # The perspective is forward; every config widget still exists in the tree.
        app.find("filter_#{shape.id}").should_not be_nil
    end

    it "actually gives the perspective more room - the point of the mode" do
        # The reason to switch it off at all. Asserted on the LAID-OUT grid, not on the layout
        # code's intentions: a tab page is a vstack, and a vstack measured loosely returns its
        # natural height, which would leave the matrix short despite every other example passing.
        app, renderer = make_app
        shape = app.shapes.first
        vm = app.find("matrix_grid_#{shape.id}").not_nil!
        one_page_height = vm.bounds.height
        one_page_height.should be > 0.0 # instrument

        toggle_tabs(app, renderer)

        tabbed_height = app.find("matrix_grid_#{shape.id}").not_nil!.bounds.height
        tabbed_height.should be > one_page_height
    end

    it "scrolls the Config tab, because every section is open at once" do
        # With all five sections open the config easily outgrows the panel — in the field report
        # it was cut off mid-Configuration. It has to scroll, or the sections below the fold are
        # simply unreachable.
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)

        scroll = app.find("shape_config_scroll_#{shape.id}")
        scroll.should_not be_nil
        scroll.not_nil!.should be_a(CrymbleUI::ScrollView)

        # The history changes table scrolls WITH the rest, which is only true because it is a
        # layer-free RecursiveGrid. As a VirtualMatrix it owned layers, and a layer never draws
        # into the ScrollView's cached buffer — it stayed nailed in place while its neighbours
        # moved. If anyone makes it a matrix again, this fails.
        changes = app.find("changes_#{shape.id}")
        changes.should_not be_nil
        changes.not_nil!.should be_a(CrymbleUI::RecursiveGrid)
        inside_changes = false
        ancestor = changes.not_nil!.parent
        while ancestor
            inside_changes = true if ancestor.same?(scroll.not_nil!)
            ancestor = ancestor.parent
        end
        inside_changes.should be_true

        # And the config really is inside it, not merely next to it.
        filter = app.find("filter_#{shape.id}").not_nil!
        inside = false
        ancestor = filter.parent
        while ancestor
            inside = true if ancestor.same?(scroll.not_nil!)
            ancestor = ancestor.parent
        end
        inside.should be_true
    end

    it "keeps the perspective toolbar laid out DURING a resize, not just after it" do
        # Field report: resizing a tabbed Shape makes "Add field / ... / Add record" vanish for
        # the duration of the drag and come back when it settles. A test that only looks at the
        # settled layout cannot see that, so this one asserts at every step of the drag.
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)

        toolbar = ->{ {"mx_addf_#{shape.id}", "mx_addf_dlg_#{shape.id}", "mx_addr_#{shape.id}"}.map { |i| app.find(i) } }
        toolbar.call.each { |b| b.should_not be_nil } # instrument: they exist before the drag

        panel = app.find(shape.id).not_nil!
        right = panel.absolute_bounds.x + panel.absolute_bounds.width
        mid_y = panel.absolute_bounds.y + panel.absolute_bounds.height / 2
        renderer.mouse_down(right, mid_y)
        renderer.render_frame(app)

        widths = [] of Float64
        6.times do |i|
            renderer.mouse_move(right - (i + 1) * 30.0, mid_y)
            renderer.render_frame(app)
            toolbar.call.each do |b|
                b.should_not be_nil # still in the tree mid-drag
                widths << b.not_nil!.bounds.width
            end
        end
        renderer.mouse_up(right - 180.0, mid_y)
        renderer.render_frame(app)

        # Not "they are back afterwards" — they must never have gone.
        widths.count(&.<=(0.0)).should eq(0)
    end

    # CONTROL for the example below: does the same drag lose the toolbar with tabs OFF? If it
    # does, the tabs are innocent and this is embrace's resize repaint, not this feature.
    it "CONTROL: one-page mode, same drag, same sampling" do
        app, renderer = make_app
        shape = app.shapes.first
        panel = app.find(shape.id).not_nil!
        layer = panel.as(CrymbleUI::WindowPanel).layer.not_nil!
        want = CrymbleUI::Theme.current.button_background

        sample = ->{
            backend = layer.backend.not_nil!.as(CrymbleUI::Testing::TestRenderBackend)
            btn = app.find("mx_addf_#{shape.id}")
            if btn
                b = btn.absolute_bounds
                bx = (b.x + btn.bounds.width / 2 - layer.bounds.x - layer.buffer_origin.x).to_i
                by = (b.y + btn.bounds.height / 2 - layer.bounds.y - layer.buffer_origin.y).to_i
                (bx >= 0 && by >= 0 && bx < backend.width && by < backend.height) ? backend.get_pixel(bx, by) : nil
            end
        }
        sample.call.should eq(want)

        right = panel.absolute_bounds.x + panel.absolute_bounds.width
        mid_y = panel.absolute_bounds.y + panel.absolute_bounds.height / 2
        renderer.mouse_down(right, mid_y)
        renderer.render_frame(app)
        missing = [] of String
        6.times do |i|
            renderer.mouse_move(right - (i + 1) * 30.0, mid_y)
            renderer.render_frame(app)
            px = sample.call
            missing << "step #{i}: #{px.inspect}" unless px == want
        end
        renderer.mouse_up(right - 180.0, mid_y)
        renderer.render_frame(app)
        # One page never lost it; that is what proved the tabs were to blame rather than
        # embrace's resize repaint.
        missing.should be_empty
    end

    it "keeps the perspective toolbar PAINTED during a resize" do
        # The bounds survive the drag (above) — so if the buttons disappear on screen, they are
        # being laid out and not painted, and only pixels can say so. Samples the middle of "Add
        # field" in the panel's own buffer at every step.
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)

        panel = app.find(shape.id).not_nil!
        layer = panel.as(CrymbleUI::WindowPanel).layer.not_nil!
        want = CrymbleUI::Theme.current.button_background

        sample = ->{
            backend = layer.backend.not_nil!.as(CrymbleUI::Testing::TestRenderBackend)
            btn = app.find("mx_addf_#{shape.id}")
            if btn
                b = btn.absolute_bounds
                bx = (b.x + btn.bounds.width / 2 - layer.bounds.x - layer.buffer_origin.x).to_i
                by = (b.y + btn.bounds.height / 2 - layer.bounds.y - layer.buffer_origin.y).to_i
                if bx >= 0 && by >= 0 && bx < backend.width && by < backend.height
                    backend.get_pixel(bx, by)
                else
                    nil
                end
            else
                nil
            end
        }

        sample.call.should eq(want) # instrument: painted before the drag, or the test is blind

        right = panel.absolute_bounds.x + panel.absolute_bounds.width
        mid_y = panel.absolute_bounds.y + panel.absolute_bounds.height / 2
        renderer.mouse_down(right, mid_y)
        renderer.render_frame(app)

        missing = [] of String
        6.times do |i|
            renderer.mouse_move(right - (i + 1) * 30.0, mid_y)
            renderer.render_frame(app)
            px = sample.call
            missing << "step #{i}: #{px.inspect}" unless px == want
        end
        renderer.mouse_up(right - 180.0, mid_y)
        renderer.render_frame(app)

        missing.should be_empty
    end

    it "shows EVERY config section on the tab, not just the first one" do
        # Written after shipping a Config tab that showed History and nothing else: the scroll
        # direction had been changed to Both, which broke the vertical stacking, and the only
        # test looking at the tab measured the FIRST section — the one thing still visible. A
        # tab that silently loses four of its five sections must fail here.
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)
        app.find("shape_tabs_#{shape.id}_tab_1").not_nil!.as(CrymbleUI::TabHeader).trigger_click
        renderer.settle_rendering(app)

        missing = [] of String
        {"history", "table", "config", "fieldlist", "filter"}.each do |section|
            w = app.find("#{section}_#{shape.id}")
            if w.nil?
                missing << "#{section}: absent"
            elsif w.bounds.width <= 0.0 || w.bounds.height <= 0.0
                missing << "#{section}: #{w.bounds}"
            end
        end
        missing.should be_empty
    end

    # ScrollView#min_intrinsic_width is 0.0 BY DESIGN — "the OPT-IN escape valve: embed shrinkable
    # content in a ScrollView and the panel can shrink past it" — which is right for a viewport
    # over something large, and wrong for a vertically-scrolling column of controls that cannot
    # scroll sideways. The Config tab opts out via keep_content_width, so the floor that protects
    # one-page mode protects the tab too.
    it "does not let the Config tab crush its content when the panel is narrowed" do
        # Field report: in tab mode the panel can be dragged narrow enough that the config is
        # squeezed to shreds — "Allocations" down to "Allo", buttons to "Sha". One page cannot do
        # that, because each section reports a minimum width and the panel cannot go below it;
        # ScrollView#min_intrinsic_width returns 0.0 by design, which cuts that chain.
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)
        # Bring Config forward — on the hidden page every widget is correctly zero-bounded, so
        # measuring there would measure nothing at all.
        app.find("shape_tabs_#{shape.id}_tab_1").not_nil!.as(CrymbleUI::TabHeader).trigger_click
        renderer.settle_rendering(app)

        # The FIRST section, so it is above the fold and genuinely laid out — a section below it
        # is legitimately unmeasured and would prove nothing.
        picker = app.find("history_#{shape.id}")
        picker.should_not be_nil
        floor = picker.not_nil!.min_intrinsic_width(0.0)
        floor.should be > 0.0 # instrument: the widget does demand a width

        panel = app.find(shape.id).not_nil!
        right = panel.absolute_bounds.x + panel.absolute_bounds.width
        mid_y = panel.absolute_bounds.y + panel.absolute_bounds.height / 2
        renderer.mouse_down(right, mid_y)
        renderer.render_frame(app)
        renderer.mouse_move(panel.absolute_bounds.x + 120.0, mid_y) # drag it very narrow
        renderer.render_frame(app)
        renderer.mouse_up(panel.absolute_bounds.x + 120.0, mid_y)
        renderer.settle_rendering(app)

        live = app.find("history_#{shape.id}")
        live.not_nil!.bounds.width.should be >= floor
    end

    it "still fires the Shape's keyboard shortcuts in tab mode" do
        # Shortcuts are registered at build time and dispatched by PANEL, so restructuring a
        # panel's body into tabs must not disturb which panel a shortcut belongs to. ^R (Add
        # record) is declared in the Shape's own menubar, outside the tab strip; the config
        # tab's own widgets are covered by crymble-ui's tabs_spec, which pins that a hidden
        # page's shortcuts keep firing.
        # The manager has to exist BEFORE the tree is built: the DSL registers shortcuts as it
        # builds, so installing it afterwards would leave it empty and the example would prove
        # nothing.
        manager = CrymbleUI::ShortcutManager.new
        CrymbleUI::Widget.shortcut_manager = manager
        app, renderer = make_app
        shape = app.shapes.first
        adapter = shape.matrix_adapter.not_nil!
        toggle_tabs(app, renderer)

        rows_before = adapter.get_scrollorder[0].size
        panel = app.find(shape.id).not_nil!

        event = SF::Event::KeyPressedEvent.new
        {% if flag?(:darwin) %}
            event.system = true
            event.control = false
        {% else %}
            event.control = true
            event.system = false
        {% end %}
        event.alt = false
        event.shift = false
        event.code = SF::Keyboard::Key::R

        manager.handle_key_event(event, panel).should be_true
        renderer.settle_rendering(app)
        adapter.get_scrollorder[0].size.should be > rows_before
    end

    it "switches back to one page when switched on again" do
        app, renderer = make_app
        shape = app.shapes.first
        toggle_tabs(app, renderer)
        toggle_tabs(app, renderer)

        app.find("shape_tabs_#{shape.id}").should be_nil
        app.find("filter_#{shape.id}").should_not be_nil
    end
end
