require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/gui/cell"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"
require "crymble-ui/testing/test_font"
require "./support/fixtures"

include Persistency

# Field report 2026-09-03: "drag-and-drop in Perspective has proper coloring (user-visible) - but
# not in Field list (merely slightly lighter)".
#
# The two panels signal the same thing by different means. The Perspective paints an OPAQUE decal
# (VirtualMatrix cursor_overlay's DRAG_HIGHLIGHT_COLOR) on the matrix's additive overlay layer, so
# it reads on any cell. The Field list goes through DragManager's generic highlight layer, an
# ordinary alpha composite, where the target's `highlight_opacity` is multiplied INTO the colour's
# own alpha. It asked for #4060B0C8 at the library default 0.4 and rendered at 0.314 — over section
# backgrounds that are themselves saturated (green Rows, blue Columns, brown Aggregates), and in a
# blue that the Columns section already is.
private def dragging_app : {EmbraceApp, CrymbleUI::Testing::TestRenderer, CrymbleUI::DropZoneBox}
    app = Fixtures.app(<<-EOT)[0]
        Items
        ab | Val
        a | 1
        b | 2
    EOT
    renderer = Fixtures.renderer(app, 1114, 705)
    shape = app.shapes.first
    Fixtures.open_fieldlist(app, renderer)

    root = app.find("fieldlist_#{shape.id}").not_nil!
    drags = [] of CrymbleUI::DraggableBox
    zones = [] of CrymbleUI::DropZoneBox
    stack = [root.as(CrymbleUI::Widget)]
    while w = stack.pop?
        drags << w if w.is_a?(CrymbleUI::DraggableBox)
        zones << w if w.is_a?(CrymbleUI::DropZoneBox)
        w.children.each { |c| stack << c }
    end
    src = drags.first
    tgt = zones.max_by(&.absolute_bounds.height)
    sc = src.absolute_bounds.center
    tc = tgt.absolute_bounds.center
    renderer.mouse_down(sc.x, sc.y)
    renderer.mouse_move(sc.x, sc.y + CrymbleUI::DragState::DRAG_THRESHOLD + 1.0) # commits the drag
    renderer.mouse_move(tc.x, tc.y)
    renderer.render_frame(app)
    {app, renderer, tgt}
end

describe "the Field list's drop feedback is as visible as the Perspective's" do
    # The highlight covers what SHOWS of its target, and a zone of text is 0 wide where text measures 0 (core
    # specs have no font) - there would be nothing to highlight. Measure text here, for these examples only.
    around_each do |example|
        font = CrymbleUI::Widget.font
        CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new
        example.run
    ensure
        CrymbleUI::Widget.font = font
    end

    it "paints the drop target at all (instrument: a drag is actually in flight)" do
        app, _, _ = dragging_app
        app.drag_manager.dragging?.should be_true
        app.drag_manager.highlight_layer.not_nil!.composite_anchor.should_not be_nil # shown, over its target
    end

    it "renders it at a strength the composite survives, not the library default" do
        # The user-visible quantity is the product, which is why neither half alone is asserted:
        # the colour's alpha times the layer opacity. At 0.314 it read as "merely slightly lighter".
        app, _, tgt = dragging_app
        layer = app.drag_manager.highlight_layer.not_nil!
        widget = layer.widgets.first
        fill = widget.to_primitives(widget.bounds)
            .select(&.is_a?(CrymbleUI::FillRect)).map(&.as(CrymbleUI::FillRect)).first
        effective = (fill.color.a / 255.0) * layer.opacity
        # The bar is the library's GENERIC drag-feedback strength: this panel paints over saturated
        # section colours, so it must come out STRONGER than a neutral-background default, never
        # weaker. Expressed against the theme rather than a number, so retuning the theme retunes
        # the test with it.
        generic = CrymbleUI::Theme.current.brightness_drag_opacity
        effective.should be > generic,
            "drop highlight renders at #{effective.round(3)}, no stronger than the generic #{generic}"
    end

    it "uses the SAME signal colour as the Perspective's decal" do
        # One meaning, one colour — and this ties the two definitions together, so changing either
        # the matrix decal or embrace's token without the other fails here instead of drifting into
        # two different "this is where it lands" colours.
        _, _, tgt = dragging_app
        decal = CrymbleUI::VirtualMatrix::DRAG_HIGHLIGHT_COLOR
        c = tgt.highlight_color
        {c.r, c.g, c.b}.should eq({decal.r, decal.g, decal.b})
    end
end
