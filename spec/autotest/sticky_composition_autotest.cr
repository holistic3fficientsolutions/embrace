require "../spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "../../src/gui/probe"

# CALIBRATES the composition oracle (EmbraceProbe.check_composition) against a real SFML sticky
# column, and scrolls one the way the symptom needs.
#
# The symptom: after scrolling, the rank column (c1) shows each number with REMNANTS OF OTHER
# NUMBERS under it (Wolfgang, screenshot 2026-09-16). Four previous instruments read the CONTENT
# layer and found nothing; a fifth compared the sticky layer with ITSELF twenty frames apart and
# reported the change-highlight fade as a fault. This one compares the sticky layer against the
# cached textures of the very widgets that are on it, in one instant — see probe.cr.
#
# The run has three parts and the middle one is the point:
#   CONTROL  — deliberately paint a block of wrong ink onto the sticky layer and assert the oracle
#              SEES it. An instrument that has never failed is not known to be able to.
#   SWEEP    — scroll through many offsets, including the big jump back to the top that the first
#              probe caught, and check composition at every settled stop.
#   VERDICT  — exit 1 if any stop disagreed, so this is a test and not a log to read.
#
# Run: source setup.sh
#      crystal build spec/autotest/sticky_composition_autotest.cr -Dprobe -o /tmp/stickycomp
#      DISPLAY=:0 /tmp/stickycomp
# Env: SC_ROWS (default 400), SC_NOAUTOSIZE=1 to skip the auto-size toggle.

ROWS = (ENV["SC_ROWS"]? || "400").to_i
DO_AUTOSIZE = ENV["SC_NOAUTOSIZE"]? != "1"
# SC_TSV points at Wolfgang's own pasted table. It matters and is not interchangeable with generated
# rows: his has 2561 records x 7 fields with one cell of 2647 characters over 37 lines, so auto-size
# produces rows far taller than the viewport, and the rank column is correspondingly wide. The
# generated fixture below scrolls the same code and has never reproduced the fault.
tsv_path = ENV["SC_TSV"]?

app = EmbraceApp.new
persistency = app.persistency
if tsv_path
    rows = TSV.decode(File.read(tsv_path))
    fields = rows.max_of(&.size)
    cells = rows.map { |r| Array(Persistency::Cell).new(fields) { |i| (r[i]? || "").as(Persistency::Cell) } }
    puts "fixture: #{rows.size} records x #{fields} fields from #{tsv_path}"
    t_lid = persistency.import_rows(cells, "", Array.new(fields, ""))
else
    # Varied text per row: the fault is remnants of OTHER rows' glyphs, so rows whose sticky cell
    # paints the same pixels could hide it. Row numbers already differ in width; the body widens them.
    # SC_COLS exists to make the HORIZONTAL precondition reachable. The fault needs every sticky cell
    # on a layer destroyed and recreated in one frame; with a handful of fields the column headers
    # are all alive all the time and no horizontal gesture can trigger it, which is why Wolfgang's
    # 7-field table shows the fault only on the rank column.
    cols = (ENV["SC_COLS"]? || "3").to_i
    cells = Array(Array(Persistency::Cell)).new(ROWS) do |i|
        Array(Persistency::Cell).new(cols) { |c| (c == 0 ? "row #{i}" : "r#{i}c#{c}").as(Persistency::Cell) }
    end
    puts "fixture: #{ROWS} generated records x #{cols} fields"
    t_lid = persistency.import_rows(cells, "", Array.new(cols) { |c| "field #{c}" })
end
app.shapes.clear
shape = ShapeState.new("Sticky", persistency, persistency.context.clone, t_lid)
app.shapes << shape

class Driver
    @phase = 0
    @frame = 0
    @stops = 0
    @bad_stops = 0
    @control_seen = false
    @gestures = [] of Tuple(Int32, Bool)
    @drags = [2, 3, 5, 8, 2, 3, 12, 2]
    @drag = 0
    @broken_layers = Hash(String, Int32).new
    @hjumps = [3300, -3300, 1650, -3300, 900, -3300]
    @hj = 0
    @tick = 0

    def initialize(@app : EmbraceApp, @shape : ShapeState)
    end

    private def matrix : CrymbleUI::VirtualMatrix?
        @app.find("matrix_grid_#{@shape.id}").try &.as(CrymbleUI::VirtualMatrix)
    end

    private def log(s : String); puts s; STDOUT.flush; end

    # The ScrollView that owns the matrix's scrollbars. The THUMB DRAG goes through it, not through
    # scroll_offset= — the real gesture runs ScrollView -> sync_from_scroll_view, which defers the
    # cell create/destroy to pre_render_flush.
    private def scroll_view : CrymbleUI::ScrollView?
        m = matrix
        return nil unless m
        mb = m.absolute_bounds
        best : CrymbleUI::ScrollView? = nil
        @app.find_all { |w| w.is_a?(CrymbleUI::ScrollView) }.each do |w|
            sv = w.as(CrymbleUI::ScrollView)
            b = sv.absolute_bounds
            next unless b.width > 100 && b.height > 100
            next unless b.x >= mb.x - 2 && b.y >= mb.y - 2 &&
                        b.x + b.width <= mb.x + mb.width + 2 && b.y + b.height <= mb.y + mb.height + 2
            best = sv if best.nil? || b.width * b.height > best.not_nil!.absolute_bounds.width * best.not_nil!.absolute_bounds.height
        end
        best
    end

    # All three sticky layers, not just the column: "is this only the row headers?" is a question to
    # measure, not to reason about. Column headers ride sticky_row_layer, the cluster corner rides
    # sticky_corner_layer.
    private def check(tag : String) : Nil
        m = matrix
        return unless m
        all = EmbraceProbe.check_all_sticky(m, dump: true)
        if all.empty?
            log("INSTRUMENT FAILURE: no sticky layer with an SFML backend"); exit 1
        end
        @stops += 1
        broken = [] of String
        parts = [] of String
        all.each do |which, (bad_cells, bad_px, stray, open_n)|
            if bad_cells > 0 || stray > 0
                broken << "#{which}: #{bad_cells} widgets (#{bad_px} px), #{stray}/#{open_n} stray"
                @broken_layers[which] = (@broken_layers[which]? || 0) + 1
            else
                parts << "#{which} clean"
            end
        end
        pos = "x=#{m.scroll_offset.x.round(0)} y=#{m.scroll_offset.y.round(0)}"
        if broken.empty?
            log("#{tag}: #{pos} #{parts.join(", ")}")
        else
            @bad_stops += 1
            log("#{tag}: #{pos} >>> BROKEN  #{broken.join(" | ")}#{parts.empty? ? "" : "  (" + parts.join(", ") + ")"}")
        end
    end

    # THE CONTROL. Paint a block of unmistakable ink straight onto the sticky layer's buffer, on top
    # of a real sticky cell, and require the oracle to report it. If this does not fire, every
    # "clean" below means only that the instrument is blind.
    #
    # It has to land ON A CELL WITH A CACHED TEXTURE and INSIDE the layer's visible window. The first
    # version of this control painted at the bottom of the BUFFER, which is taller than the window,
    # so the ink went somewhere the oracle correctly does not look — and the control failed for a
    # reason that had nothing to do with the oracle's sensitivity.
    private def corrupt_and_verify : Nil
        m = matrix
        return unless m
        sv = m.content_scroll_view
        lyr = sv.try(&.sticky_col_layer)
        be = lyr.try(&.backend)
        unless lyr && be.is_a?(CrymbleUI::CrSFMLBackend)
            log("INSTRUMENT FAILURE: no sticky column layer to corrupt"); exit 1
        end
        vm_abs = m.absolute_bounds
        dx = vm_abs.x - lyr.bounds.x
        dy = vm_abs.y - lyr.bounds.y
        clip_w = {be.width, CrymbleUI::PixelSnap.origin(lyr.bounds.width)}.min
        clip_h = {be.height, CrymbleUI::PixelSnap.origin(lyr.bounds.height)}.min
        target = lyr.widgets.find do |w|
            wb = w.widget_backend
            next false unless wb.is_a?(CrymbleUI::CrSFMLBackend)
            px = CrymbleUI::PixelSnap.origin(dx + w.bounds.x)
            py = CrymbleUI::PixelSnap.origin(dy + w.bounds.y)
            px >= 0 && py >= 0 && px + 12 < clip_w && py + 12 < clip_h
        end
        unless target
            log("INSTRUMENT FAILURE: no sticky cell with a cached texture inside the visible window")
            exit 1
        end
        px = CrymbleUI::PixelSnap.origin(dx + target.bounds.x)
        py = CrymbleUI::PixelSnap.origin(dy + target.bounds.y)
        w = {CrymbleUI::PixelSnap.origin(target.bounds.width), clip_w - px, 12}.min
        h = {CrymbleUI::PixelSnap.origin(target.bounds.height), clip_h - py, 12}.min
        ink = Array(CrymbleUI::Color).new(w * h) { CrymbleUI::Color.new(255_u8, 0_u8, 255_u8, 255_u8) }
        be.set_pixels(px, py, w, h, ink)
        be.display
        v = EmbraceProbe.check_sticky_composition(m, dump: true)
        bad_cells, bad_px, stray, open_n = v || {0, 0, 0, 0}
        if bad_cells > 0 || stray > 0
            @control_seen = true
            log("CONTROL: magenta #{w}x#{h} over cell #{m.active_cells.key_for?(target).inspect} at " \
                "layer(#{px},#{py}) -> SEEN (#{bad_cells} widgets, #{bad_px} px, #{stray}/#{open_n} uncovered) " \
                "— the oracle can fail")
        else
            log("CONTROL: magenta #{w}x#{h} at layer(#{px},#{py}) -> NOT SEEN")
            log("INSTRUMENT FAILURE: the oracle cannot see ink it was handed. Every clean verdict")
            log("                    below would be worthless, so this run stops here.")
            exit 1
        end
        @app.request_rebuild # let the app repaint over the block before the sweep starts
    end

    def on_frame
        @frame += 1
        m = matrix
        case @phase
        when 0
            ready = m && m.absolute_bounds.width > 50 && !m.active_cells.empty? && m.sticky_col_count > 0
            unless ready
                if @frame > 2000
                    log("INSTRUMENT FAILURE: matrix never laid out with a sticky column")
                    log("  matrix=#{m ? "yes" : "no"} sticky_col_count=#{m.try(&.sticky_col_count).inspect}")
                    exit 1
                end
                return
            end
            mm0 = m.not_nil!
            sv0 = mm0.content_scroll_view
            counts = {"col" => sv0.try(&.sticky_col_layer).try(&.widgets.size),
                      "row" => sv0.try(&.sticky_row_layer).try(&.widgets.size),
                      "corner" => sv0.try(&.sticky_corner_layer).try(&.widgets.size)}
            # A layer with no widgets is trivially "the composition of its widgets". Print the counts
            # so a clean verdict on the row/corner layers is never mistaken for evidence about them.
            log("laid out: sticky_col_count=#{mm0.sticky_col_count} sticky_row_count=#{mm0.sticky_row_count}, " \
                "#{mm0.active_cells.size} active cells; widgets per sticky layer: #{counts}")
            @phase = DO_AUTOSIZE ? 1 : 2
            @frame = 0
        when 1
            if @frame == 1
                log("-- Auto-size ON (his state: tall, unequal rows) --")
                @shape.auto_size_cells = true
                @shape.matrix_adapter.try &.invalidate_all!
                @app.request_rebuild
            elsif @frame > 240
                log("auto-size settled")
                @phase = 2
                @frame = 0
            end
        when 2
            if @frame == 8
                check("baseline")
                corrupt_and_verify
            elsif @frame == 24
                check("after the control repainted")
                # WHEEL EVENTS, not scroll_offset =. Assigning the offset skips ScrollView ->
                # sync_from_scroll_view, which is the path that shifts the buffer and picks the blit
                # plan — so a sweep that assigns exercises the reposition fallback and calls the
                # fast path untested. The first version of this sweep did exactly that and was
                # clean for a reason that had nothing to do with the bug.
                # Signed tick counts: down, back up, small nudges, and the long run back to the top
                # that the first probe caught repositioning every sticky cell at once.
                # {ticks, instant}. INSTANT matters and is the whole reproduction: 700 wheel
                # events scroll THROUGH the table, so cells are recycled a row at a time and the
                # blit path (which clears the buffer) keeps running. Wolfgang's log caught rows
                # 438-454 becoming rows 0-19 in ONE frame - every sticky cell destroyed and
                # recreated at once, so nothing MOVED (reposition clears nothing) and nothing had a
                # cached texture (the blit path does not run either).
                @gestures = [{3, false}, {12, false}, {40, false}, {-40, false},
                             {3300, true}, {-3300, true}, {3300, true}, {-1650, true},
                             {900, true}, {-3300, true}, {120, false}, {-3300, true}]
                log("-- sweep: #{@gestures.size} wheel gestures --")
                @phase = 3
                @frame = 0
            end
        when 3
            mm = m.not_nil!
            g = @gestures[@tick]?
            unless g
                log("-- wheel sweep done; now the thumb drags --")
                @phase = 4
                @frame = 0
                return
            end
            ticks, instant = g
            n = ticks.abs
            dir = ticks > 0 ? -1.0 : 1.0 # a wheel delta of -1 scrolls DOWN
            c = mm.absolute_bounds
            centre = CrymbleUI::Vec2.new(c.x + c.width / 2, c.y + c.height / 2)
            events = instant ? 1 : n
            if @frame <= events
                delta = instant ? dir * 5.0 * n : dir * 5.0
                @app.handle_mouse_wheel(CrymbleUI::Vec2.new(0.0, delta), centre)
            elsif @frame == events + 14
                check("gesture #{@tick + 1} (#{ticks > 0 ? "down" : "up"} #{n}#{instant ? " AT ONCE" : ""})")
                @tick += 1
                @frame = 0
            end
        when 4
            # WOLFGANG'S ACTUAL GESTURE: "I drag the thumb down quickly and quickly to the very top
            # again." Quickly is the operative word - few, large steps, so whole screenfuls of rows
            # are destroyed and recreated between frames rather than recycled a row at a time. The
            # wheel sweep above never reproduced it because 700 wheel events scroll THROUGH the
            # table and keep the blit path (which clears the buffer) running.
            sv = scroll_view
            unless sv
                log("INSTRUMENT FAILURE: no ScrollView inside the matrix"); exit 1
            end
            steps = @drags[@drag]?
            unless steps
                log("-- thumb drags done; now HORIZONTAL jumps (column headers + cluster corner) --")
                @phase = 5
                @frame = 0
                return
            end
            b = sv.not_nil!.absolute_bounds
            x = b.x + b.width - 8.0     # centre of the 16px vertical bar
            y0 = b.y + 20.0             # below the up-arrow
            span = b.height - 24.0
            if @frame == 1
                @app.handle_mouse_down(CrymbleUI::Vec2.new(x, y0))
            elsif @frame <= 1 + steps
                i = @frame - 1
                @app.handle_mouse_move(CrymbleUI::Vec2.new(x, y0 + span * i / steps))
            elsif @frame <= 1 + 2 * steps
                i = @frame - 1 - steps
                # Overshoot above the track on the last step: "to the very top" is a real user
                # slamming the thumb into the end stop, which clamps the scroll to 0.
                yy = i == steps ? y0 - 40.0 : y0 + span * (steps - i) / steps
                @app.handle_mouse_move(CrymbleUI::Vec2.new(x, yy))
            elsif @frame == 2 + 2 * steps
                @app.handle_mouse_up(CrymbleUI::Vec2.new(x, y0 - 40.0))
            elsif @frame == 2 + 2 * steps + 16
                check("thumb drag #{@drag + 1} (#{steps} steps down, #{steps} back to the top)")
                @drag += 1
                @frame = 0
            end
        when 5
            # The same gesture on the OTHER axis. If the mechanism is what the code says it is, a
            # jump that recreates every sticky-ROW cell at once should leave the same ink in the
            # column headers' grid strips as the vertical jump left in the rank column's.
            j = @hjumps[@hj]?
            unless j
                log("")
                log("=== #{@stops} stops checked, #{@bad_stops} broken; control #{@control_seen ? "SEEN" : "MISSED"} ===")
                log("=== broken by layer: #{@broken_layers.empty? ? "none" : @broken_layers.map { |k, v| "#{k}x#{v}" }.join(", ")} ===")
                exit(@bad_stops > 0 ? 1 : 0)
            end
            mm = m.not_nil!
            c = mm.absolute_bounds
            centre = CrymbleUI::Vec2.new(c.x + c.width / 2, c.y + c.height / 2)
            if @frame == 1
                # shift+wheel is the horizontal gesture
                @app.handle_mouse_wheel(CrymbleUI::Vec2.new(0.0, (j > 0 ? -5.0 : 5.0) * j.abs), centre, shift: true)
            elsif @frame == 16
                check("h-jump #{@hj + 1} (#{j > 0 ? "right" : "left"} #{j.abs} AT ONCE)")
                @hj += 1
                @frame = 0
            end
        end
    end
end

app.build_tree
root = app.root
raise "expected a Window" unless root.is_a?(CrymbleUI::Window)
w = root.as(CrymbleUI::Window)
renderer = CrymbleUI::SFMLRenderer.new(width: w.width.to_i, height: w.height.to_i, title: w.title)
# Open the probe log so check_composition's per-widget detail lines (which name the disagreeing
# widget and the first differing texel) are written somewhere. Without this @@io is nil and the
# oracle reports only its counts.
EmbraceProbe.start(app)
driver = Driver.new(app, shape)
CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 16_000_000), repeating: true) { driver.on_frame }
renderer.run(app)
