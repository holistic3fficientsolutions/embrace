require "../spec_helper"
require "../../src/gui/embrace"

# SFML AUTOTEST — what one keystroke costs while a cell is being edited with auto-size on.
#
# Wolfgang, 2026-09-18: without --release every keystroke is slow; WITH --release typing is bearable
# but press-and-hold AUTOREPEAT stalls -- and BACKSPACE stays fast either way. This measures those
# four things in the shipped configuration, because a headless wall-clock around one call is a lower
# bound that models no font, no GPU and no compositing (docs/BUGFIXING.md: the SFML instruments
# exist for the axioms headless cannot model).
#
# MEASUREMENT, not a test, per docs/BUGFIXING.md -- the deterministic failing test is the headless
# counter version that follows once this says which counter to assert on.
#
# Run: source setup.sh
#      crystal build --release spec/autotest/autosize_keystroke_perf_autotest.cr -o /tmp/kperf
#      DISPLAY=:0 KPERF_TSV=/tmp/text.txt /tmp/kperf
# Env: KPERF_TSV (default /tmp/text.txt), KPERF_KEYS (default 40), KPERF_NOAUTOSIZE=1 for the control.
KPERF_PATH = ENV["KPERF_TSV"]? || "/tmp/text.txt"
KPERF_KEYS = (ENV["KPERF_KEYS"]? || "40").to_i
KPERF_AUTO = ENV["KPERF_NOAUTOSIZE"]? != "1"
# The machine's own autorepeat interval: `xset q` -> "repeat rate: 33" = 30.3 ms. Overridable so the
# budget can be stated explicitly rather than assumed from whatever X11 happens to be set to.
KPERF_INTERVAL_MS = (ENV["KPERF_INTERVAL_MS"]? || "30.3").to_f
KPERF_T0 = Time.instant

rows = TSV.decode(File.read(KPERF_PATH))
fields = rows.max_of(&.size)
app = EmbraceApp.new
cells = rows.map { |r| Array(Persistency::Cell).new(fields) { |i| (r[i]? || "").as(Persistency::Cell) } }
t = app.persistency.import_rows(cells, "", Array.new(fields, ""))
app.shapes.clear
shape = ShapeState.new("Perf", app.persistency, app.persistency.context.clone, t)
app.shapes << shape
puts "fixture: #{rows.size} records x #{fields} fields, auto-size #{KPERF_AUTO ? "ON" : "OFF"}"

class Driver
  @phase = 0
  @frame = 0
  @last_rebuilds = 0_i64
  @n = 0
  @samples = {} of String => Array(Float64)
  @label = ""
  @t_key = Time.instant
  @typed = 0
  @burst_start = Time.instant

  # THE SYMPTOM, not the cost: how far behind the keystroke schedule the app has fallen by the end
  # of the burst. X11 delivers key n at n * interval whatever we do; if we are later than that, the
  # queue is growing and the user sees a stall that outlives the key release.
  private def report_lag(what : String)
    # Print the burst in the work log's own clock so the log can be WINDOWED to it. Averaging a
    # whole run hides the burst: 20 expensive frames among 740 move the mean by nothing.
    log "  WINDOW #{what}: t_ms #{(@burst_start - KPERF_T0).total_milliseconds.round(0)} .. #{(Time.instant - KPERF_T0).total_milliseconds.round(0)}"
    elapsed = (Time.instant - @burst_start).total_milliseconds
    scheduled = KPERF_KEYS * KPERF_INTERVAL_MS
    lag = elapsed - scheduled
    log "  #{what}: #{KPERF_KEYS} keys scheduled over #{scheduled.round(0)}ms took #{elapsed.round(0)}ms" \
        " -> #{lag > 0 ? "LAGGING by #{lag.round(0)}ms" : "kept up"}" \
        " (#{(elapsed / scheduled).round(2)}x the delivery schedule)"
  end

  def initialize(@app : EmbraceApp, @shape : ShapeState, @auto : Bool)
  end

  private def matrix : CrymbleUI::VirtualMatrix?
    @app.find("matrix_grid_#{@shape.id}").try &.as(CrymbleUI::VirtualMatrix)
  end

  private def log(s : String); puts s; STDOUT.flush; end

  # The frame cost the user actually waits for: the renderer's own phase counters, which are what
  # CRYMBLE_PERF prints, so this attributes rather than just totals.
  # Wall clock between consecutive ticks. The scheduler fires once per frame, so a frame that
  # stalls stretches the gap -- and unlike the phase counters this cannot be read at the wrong
  # moment in the frame and silently return zero, which is exactly how the first version of this
  # harness reported 0.0 ms for everything.
  @t_prev : Time::Instant? = nil

  private def tick_ms : Float64
    now = Time.instant
    prev = @t_prev
    @t_prev = now
    prev ? (now - prev).total_milliseconds : 0.0
  end

  # NON-VACUITY: what the edited cell holds, so a run that typed into nothing is void rather than
  # fast. docs/BUGFIXING.md's parity sweep carries per-phase non-vacuity counters for this reason.
  private def edited_value : String
    if m = matrix
      if c = m.active_cells[@edited_rc]?
        return c.responds_to?(:value) ? c.value.to_s : ""
      end
    end
    ""
  end
  @edited_rc : Tuple(Int32, Int32) = {-1, -1}

  private def record(ms : Float64)
    (@samples[@label] ||= [] of Float64) << ms
  end

  # The project already counts the O(total rows) row-size cache rebuild
  # (virtual_matrix.cr, "perf-audit"). Per-keystroke DELTA of it says whether a keystroke drags the
  # whole table through the frame.
  @rowc_prev = 0

  private def rowc_delta : Int32
    now = CrymbleUI::VirtualMatrix.row_cache_rebuild_rows
    d = now - @rowc_prev
    @rowc_prev = now
    d
  end

  private def record_rowc(d : Int32)
    (@rowcs[@label] ||= [] of Int32) << d
  end
  @rowcs = {} of String => Array(Int32)

  # Full O(total rows) rebuilds of the pivot hierarchy since the previous key. THE metric for
  # this class of stall: it is what the row count multiplies, and unlike a millisecond figure it
  # is machine-independent — a keystroke that types into an open editor changes no structure and
  # must cost ZERO. Two per key (a read escaping the Shape's context, and the next render putting
  # it back) is what made press-and-hold typing stall while backspace stayed fluid.
  private def rebuild_delta : Int64
    now = Table::Lazy::Pivot::Hierarchic.rebuild_count
    d = now - @last_rebuilds
    @last_rebuilds = now
    d
  end

  private def record_rebuilds(d : Int64)
    (@rebuilds[@label] ||= [] of Int64) << d
  end
  @rebuilds = {} of String => Array(Int64)

  private def report
    log ""
    log "  #{"case".ljust(26)} #{"n".rjust(3)} #{"median".rjust(8)} #{"p90".rjust(8)} #{"max".rjust(8)}  (ms per keystroke frame)"
    @samples.each do |name, v|
      next if v.empty?
      s = v.sort
      med = s[s.size // 2]
      p90 = s[(s.size * 9 // 10).clamp(0, s.size - 1)]
      rc = @rowcs[name]? || [] of Int32
      rows_per_key = rc.empty? ? 0 : rc.sum // rc.size
      rb = @rebuilds[name]? || [] of Int64
      log "  #{name.ljust(26)} #{s.size.to_s.rjust(3)} #{med.round(2).to_s.rjust(8)} #{p90.round(2).to_s.rjust(8)} #{s.last.round(2).to_s.rjust(8)}" \
          "   O(rows) walks per key: #{rows_per_key}   pivot rebuilds: #{rb.sum} over #{rb.size} keys"
    end
  end

  def on_frame
    @frame += 1
    m = matrix
    case @phase
    when 0
      return unless m && !m.active_cells.empty?
      if @auto
        @shape.auto_size_cells = true
        @shape.matrix_adapter.try &.invalidate_all!
        @app.request_rebuild
      end
      @phase = 1
      @frame = 0
    when 1
      # auto-size on this fixture is a multi-second whole-table measure; wait it out
      if @frame > 240
        log "auto-size settled"
        # Click a data cell to give it focus, the way a user starts editing.
        if cell = m.try(&.active_cells.find { |k, _| k[0] > 0 && k[1] > 0 })
          b = cell[1].absolute_bounds
          @app.handle_mouse_down(CrymbleUI::Vec2.new(b.x + b.width / 2, b.y + b.height / 2))
          @app.handle_mouse_up(CrymbleUI::Vec2.new(b.x + b.width / 2, b.y + b.height / 2))
          @edited_rc = cell[0]
          log "editing cell #{cell[0]}, value before: #{edited_value.inspect}"
          if mm = matrix
            cl = mm.content_layer
            be = cl.try(&.backend)
            log "content layer bounds #{cl.try(&.bounds.width).try(&.round(0))}x#{cl.try(&.bounds.height).try(&.round(0))}" \
                "  backend #{be.try(&.width)}x#{be.try(&.height)}  viewport_cache=#{cl.try(&.viewport_cache)}" \
                "  cache_extent=#{cl.try(&.cache_extent)}"
            log "matrix content total: #{mm.@cached_total_height.try(&.round(0))}px over #{mm.@rows} rows; active cells #{mm.active_cells.size}"
          end
        end
        @label = "TYPE (autorepeat)"
        @burst_start = Time.instant
        @phase = 2
        @frame = 0
        @n = 0
      end
    when 2, 4
      # PRESS-AND-HOLD, at the machine's real autorepeat rate: X11 here reports
      # "auto repeat delay: 500  repeat rate: 33", i.e. one key every ~30.3 ms, and it keeps
      # arriving at that rate however slow the app is. Injecting ONE PER FRAME instead (the first
      # version of this harness) silently throttles input to the frame rate, so the queue never
      # builds and the stall cannot appear -- it measures per-keystroke COST but not the SYMPTOM.
      now = Time.instant
      due = (now - @burst_start).total_milliseconds >= (@n + 1) * KPERF_INTERVAL_MS
      # Three states, not two: a key is DUE, the burst is FINISHED, or we are simply early and must
      # do nothing. Folding "early" into the finished branch ended the burst on its first
      # not-yet-due frame and then looped forever.
      return if @n < KPERF_KEYS && !due
      if @n < KPERF_KEYS
        ms = tick_ms
        d = rowc_delta
        rbd = rebuild_delta
        if @n > 0 # this gap is the frame the PREVIOUS key caused
          record(ms)
          record_rowc(d)
          record_rebuilds(rbd)
        end
        # Marks the key in the frame log so `CRYMBLE_PERF=1` output can be windowed to ONE
        # keystroke, and carries the metric that actually explains the cost (below).
        STDERR.puts "[key] #{@label[0, 4].strip} #{@n} pivot_rebuilds=#{rbd}" if ENV["KPROBE"]?
        if @phase == 2
          CrymbleUI::Widget.focus_manager?.try &.handle_text_input('x')
        else
          CrymbleUI::Widget.focus_manager?.try &.handle_key_down(SF::Keyboard::Key::Backspace, false, false)
        end
        @n += 1
      else
        if @phase == 2
          log "after typing, value: #{edited_value.inspect}"
          @typed = edited_value.size
          report_lag("TYPE")
          @label = "BACKSPACE (autorepeat)"
          @phase = 4
          @n = 0
          @t_prev = nil
          @burst_start = Time.instant
        else
          log "after backspacing, value: #{edited_value.inspect}"
          report_lag("BACKSPACE")
          report
          log ""
          if @typed == 0
            log "  !! VOID RUN: typing changed nothing, so these numbers measure an idle app."
          end
          # `exit`, NOT handle_close_request. The close request is the USER's gesture, and embrace
          # answers it with "You have unsaved changes - are you sure to quit?" — a modal nothing in
          # a harness will ever answer, so the app hangs until the timeout kills it and leaves a
          # dialog sitting on the real desktop. A harness must never ask the app a question it
          # cannot answer. The cost is that CRYMBLE_WORKLOG is not flushed on this path; window the
          # burst with the WINDOW t_ms line above and take the counters from a headless run instead.
          exit(@typed == 0 ? 2 : 0)
        end
      end
    end
  end
end

app.build_tree
root = app.root.as(CrymbleUI::Window)
renderer = CrymbleUI::SFMLRenderer.new(width: root.width.to_i, height: root.height.to_i, title: root.title)
driver = Driver.new(app, shape, KPERF_AUTO)
CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 16_000_000), repeating: true) { driver.on_frame }
renderer.run(app)
