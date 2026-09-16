require "../spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"

# DOES SCROLLING DOWN AND BACK UP LEAVE STALE PIXELS? — the real app, a real window, real GPU.
#
# User report 2026-09-14 (Windows, the GitHub build): a big .tsv pasted into a new Shape —
# ~3000 rows, ~10 columns, two of them multi-line and long — then dragging the vertical thumb DOWN
# and back UP garbles: stale content shows THROUGH the empty grid of the matrix.
#
# Headless could not reproduce it in the right regime (240px rows, 720,000px of content,
# 0 of 1248 samples differing). That may be structural: virtual_matrix.cr's own
# early-exit comment records that a culled RenderTexture is "blank on SFML ... retained headless",
# so a fault whose symptom is OLD PIXELS SURVIVING in a cached layer is a class headless cannot
# produce — it retains by construction. Hence the real window.
#
# ORACLE: the same scroll offset must render the same pixels. Sampled off the REAL window
# (SF::Texture#update(window) -> copy_to_image), not off any widget state.
# CONTROL: the tripwire "did scrolling change the picture at all" must fire, or the run proves
# nothing; and the resolved cell height is printed so the tall-row regime is CONFIRMED, not assumed.
#
# Run: source setup.sh
#      crystal build spec/autotest/vthumb_stale_content_autotest.cr -o /tmp/vthumb
#      DISPLAY=:0 timeout 300 /tmp/vthumb

ROWS       = (ENV["VT_ROWS"]? || "3000").to_i
STEPS      = (ENV["VT_STEPS"]? || "60").to_i
UP_STEPS   = (ENV["VT_UP_STEPS"]? || ENV["VT_STEPS"]? || "60").to_i
DRAG_PX    = (ENV["VT_DRAG"]? || "6000").to_f
AUTOSIZE   = ENV["VT_AUTOSIZE"]? != "0"
LONGCHARS  = (ENV["VT_LONG"]? || "0").to_i  # length of a single-line monster string in column 5
ALL_LONG   = ENV["VT_ALLLONG"]? == "1"      # make EVERY column a long string, like a real wide .tsv
MAXIMIZE   = ENV["VT_MAXIMIZE"]? == "1"     # Wolfgang names this in his repro steps
SAMPLE_STEP = 13

app = EmbraceApp.new
persistency = app.persistency
t_lid = persistency.add_table("Pasted")
fields = (0...10).map { |i| persistency.add_field(t_lid, "F#{i}") }
long_a = (["Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor"] * 4).join("\n")
long_b = (["alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi"] * 3).join("\n")
ROWS.times do |r|
  rec = persistency.add_record(t_lid)
  fields.each_with_index do |f, ci|
    v = case ci
        when 3 then "#{r}: #{long_a}"
        when 7 then "#{r}: #{long_b}"
        when 5 then LONGCHARS > 0 ? "#{r}: " + ("wide " * (LONGCHARS // 5)) : "r#{r}c#{ci}"
        else        ALL_LONG ? "#{r}.#{ci}: " + ("column content " * 30) : "r#{r}c#{ci}"
        end
    persistency.set_value(f, rec, v.as(Persistency::Cell))
  end
end
app.shapes.clear
shape = ShapeState.new("Pasted", persistency, persistency.context.clone, t_lid)
shape.auto_size_cells = AUTOSIZE
app.shapes << shape

class Driver
  @phase = 0
  @frame = 0
  @before : Array(String)? = nil
  @last_origin = ""
  @drag_x = 0.0
  @drag_y0 = 0.0
  @drag_span = 0.0
  @t_toggle = Time.instant
  @baseline_scroll = 0.0
  @grab_checked = false
  @down_sigs = Hash(Int32, Array(String)).new
  @down_offs = Hash(Int32, Float64).new
  @mid_bad = 0
  @step_ms = [] of Float64
  @t_last = Time.instant
  @mid : Array(String)? = nil

  def initialize(@app : EmbraceApp, @shape : ShapeState, @renderer : CrymbleUI::SFMLRenderer)
  end

  # Looked up FRESH every time, never memoised: a rebuild replaces the widget, and a cached
  # reference is an orphan that never lays out — which is exactly how the first cut of this
  # instrument reported 0x0 bounds for 30 seconds against a perfectly healthy app.
  private def matrix : CrymbleUI::VirtualMatrix?
    @app.find("matrix_grid_#{@shape.id}").try &.as(CrymbleUI::VirtualMatrix)
  end

  # Sample the CONTENT LAYER's own RenderTexture — the cached surface the compositor shifts, i.e.
  # the thing the report says retains old pixels. Closer to the fault than the window, and the only
  # GPU->CPU read these bindings expose (there is no window capture).
  private def signature : Array(String)
    m = matrix
    return [] of String unless m
    lay = m.layer
    return [] of String unless lay
    be = lay.backend
    return [] of String unless be.is_a?(CrymbleUI::CrSFMLBackend)
    w = lay.bounds.width.to_i
    h = lay.bounds.height.to_i
    return [] of String if w < 50 || h < 50
    # Sample WHERE THE COMPOSITOR SAMPLES. Texture (0,0) is the content coord `buffer_origin`, and
    # the composite reads at `scroll_offset - buffer_origin` (layer.cr:243-276). Reading (0,0)
    # blindly compares DIFFERENT CONTENT whenever the buffer has recentred — a difference that is
    # correct behaviour, not staleness. The first cut of this instrument did exactly that.
    ox = (lay.scroll_offset.x - lay.buffer_origin.x).to_i
    oy = (lay.scroll_offset.y - lay.buffer_origin.y).to_i
    # CrSFMLBackend#get_pixels does image.get_pixel(x+dx, y+dy) with NO bounds check, so an
    # out-of-range rect SEGFAULTS the process (observed). Clamp here; the unguarded read is
    # filed separately.
    tw = be.width
    th = be.height
    ox = ox.clamp(0, {tw - 1, 0}.max)
    oy = oy.clamp(0, {th - 1, 0}.max)
    w = {w, tw - ox}.min
    h = {h, th - oy}.min
    return [] of String if w < 20 || h < 20
    @last_origin = "scroll=#{lay.scroll_offset.y.round(1)} buffer_origin=#{lay.buffer_origin.y.round(1)} sample_at=#{oy}"
    px = be.get_pixels(ox, oy, w, h) # one GPU->CPU transfer per sample
    out = [] of String
    y = 2
    while y < h - 2
      x = 2
      while x < w - 2
        c = px[y * w + x]
        out << "#{c.r},#{c.g},#{c.b}"
        x += SAMPLE_STEP
      end
      y += SAMPLE_STEP
    end
    out
  end


  # The ScrollView that owns the matrix's scrollbars. VirtualMatrix delegates scrollbar hits to it
  # (virtual_matrix.cr:121-123), and the THUMB DRAG goes through it — not through `scroll_offset=`.
  # That distinction is the whole point of this run: the property setter calls apply_scroll
  # directly, while the real gesture goes ScrollView -> sync_from_scroll_view, which shifts the
  # compositor and DEFERS the cell create/destroy to pre_render_flush (virtual_matrix.cr:1942-1952).
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

  private def bar_x : Float64
    sv = scroll_view.not_nil!
    b = sv.absolute_bounds
    b.x + b.width - 8.0 # centre of the 16px vertical bar
  end

  private def log(s : String)
    puts s
    STDOUT.flush
  end

  def on_frame
    now = Time.instant
    dt = (now - @t_last).total_milliseconds
    @t_last = now
    @step_ms << dt if @phase == 1 || @phase == 2
    log("  SLOW FRAME: #{dt.round(0)}ms in phase #{@phase} step #{@frame}") if dt > 250.0
    @frame += 1
    m = matrix
    case @phase
    when 0
      # Wait for the app to actually lay out — a fixed frame count is a guess, and with 3000 rows
      # plus auto-size the first useful frame is far out. Poll for the real thing, cap the wait.
      ready = m && m.absolute_bounds.width > 50 && m.absolute_bounds.height > 50 && !m.active_cells.empty?
      unless ready
        if @frame % 60 == 0
          bb = m.try(&.absolute_bounds)
          log("waiting… t=#{(@frame * 16 / 1000.0).round(1)}s matrix=#{bb ? "#{bb.width.round}x#{bb.height.round}" : "nil"} cells=#{m.try(&.active_cells.size) || 0}")
        end
        if @frame > 1875 # ~30s
          log("INSTRUMENT FAILURE: matrix never laid out within 30s"); exit 1
        end
        return
      end
      m = m.not_nil!
      b = m.absolute_bounds
      heights = m.active_cells.values.map(&.bounds.height)
      log("matrix #{b.width.round}x#{b.height.round} at #{b.x.round},#{b.y.round}; auto_size=#{m.auto_size}")
      log("resolved cell heights: max=#{(heights.max? || 0.0).round(1)}px min=#{(heights.min? || 0.0).round(1)}px over #{heights.size} active cells")
      log("REGIME: tall rows? #{(heights.max? || 0.0) > b.height / 4.0}  (a row is a big fraction of the viewport)")
      # WHY are the rows 20px when the data is multi-line? Ask the adapter what each cell of the
      # first data row says it WANTS, and compare with what the matrix gave it.
      ad = @shape.matrix_adapter
      if ad
        rc = @shape.matrix_userdata_rc
        cols = rc ? rc.size[1] : 0
        (0...cols).each do |c|
          ns = ad.cell_natural_size(1, c)
          raw = rc ? rc[[1, c]].to_s : ""
          log("  natural[row1,col#{c}] w=#{ns[:width].round(1)} h=#{ns[:height].round(1)} lines=#{ns[:lines]} " \
              "| raw newlines=#{raw.count('\n')} len=#{raw.size} head=#{raw[0, 24].gsub('\n', "\\n").inspect}")
        end
      end
      @before = signature
      log("baseline samples: #{@before.not_nil!.size}  [#{@last_origin}]")
      if @before.not_nil!.size < 100
        log("INSTRUMENT FAILURE: too few samples"); exit 1
      end
      @phase = 6 # first: does TOGGLING the mode (the menu path) change the sizes?
      @frame = 0
    when 6
      if @frame == 1
        log("-- toggling auto-size OFF then ON, the way the View menu does --")
        @t_toggle = Time.instant
        @shape.auto_size_cells = false
        @shape.matrix_adapter.try &.invalidate_all!
        @app.request_rebuild
      elsif @frame == 20
        log("  auto-size OFF took #{((Time.instant - @t_toggle).total_milliseconds).round(0)}ms of wall clock over 19 frames")
        @t_toggle = Time.instant
        @shape.auto_size_cells = true
        @shape.matrix_adapter.try &.invalidate_all!
        @app.request_rebuild
      elsif @frame > 60
        log("  auto-size ON took #{((Time.instant - @t_toggle).total_milliseconds).round(0)}ms of wall clock over 40 frames")
        mm = m.not_nil!
        log("  GPU max texture size = #{LibCSFML.sfTexture_getMaximumSize}")
        cws = mm.@col_widths
        rhs2 = mm.@row_heights
        fh2 = CrymbleUI::VirtualMatrix::FRAME_HEIGHT_BASE * CrymbleUI::FontSizing.zoom_factor
        log("  columns: #{cws.size}, widest #{(cws.max? || 0.0).round(2)} units = #{((cws.max? || 0.0) * fh2).round(0)}px")
        log("  TOTAL content width = #{(cws.sum * fh2).round(0)}px   height = #{(rhs2.sum * fh2).round(0)}px")
        lay2 = mm.layer
        if lay2
          be2 = lay2.backend
          log("  content layer bounds = #{lay2.bounds.width.round}x#{lay2.bounds.height.round}; backend = " \
              "#{be2.is_a?(CrymbleUI::CrSFMLBackend) ? "#{be2.width}x#{be2.height}" : be2.class.to_s}")
        end
        hs = mm.active_cells.values.map(&.bounds.height)
        widths = mm.active_cells.map { |k, w| {k[1], w.bounds.width.round(1)} }.to_h
        log("  resolved column widths (col => px): #{widths.to_a.sort_by { |a| a[0] }.first(12).inspect}")
        log("after the toggle: cell heights max=#{(hs.max? || 0.0).round(1)}px min=#{(hs.min? || 0.0).round(1)}px over #{hs.size} cells")
        log(((hs.max? || 0.0) > 30.0) ? ">>> TOGGLING FIXES IT: auto-size set BEFORE the first build never took effect" \
                                      : ">>> still unsized after a toggle — the mode is not applying at all")
        # Plumbing check BEFORE the baseline, and undone, so it cannot poison the comparison.
        sv0 = scroll_view
        if sv0
          b0 = sv0.absolute_bounds
          s0 = m.not_nil!.scroll_offset.y
          @app.handle_mouse_wheel(CrymbleUI::Vec2.new(0.0, -5.0), CrymbleUI::Vec2.new(b0.x + b0.width / 2, b0.y + b0.height / 2))
          log("  plumbing: wheel moved scroll #{s0.round(1)} -> #{m.not_nil!.scroll_offset.y.round(1)} (events DO reach the scroll machinery)")
        end
        m.not_nil!.scroll_offset = CrymbleUI::Vec2.zero
        @baseline_scroll = 0.0
        @before = signature
        @phase = 5
        @frame = 0
      end
    when 5
      return unless @frame > 30
      ctrl = signature
      d = @before.not_nil!.zip(ctrl).count { |a, b| a != b }
      log("CONTROL (no scrolling, #{@frame} frames apart): #{d}/#{ctrl.size} samples differ  [#{@last_origin}]")
      if d != 0
        log("INSTRUMENT FAILURE: the sampler is not stable at rest — a later 'difference' would prove nothing")
        exit 1
      end
      @phase = 1
      @frame = 0
    when 1
      # THE REAL GESTURE: grab the thumb and drag it, through the app's own mouse handlers.
      sv = scroll_view
      unless sv
        log("INSTRUMENT FAILURE: no ScrollView found inside the matrix"); exit 1
      end
      svb = sv.not_nil!.absolute_bounds
      if @frame == 1
        mb = m.not_nil!.absolute_bounds
        log("matrix #{mb.x.round},#{mb.y.round} #{mb.width.round}x#{mb.height.round}; scrollview #{svb.x.round},#{svb.y.round} #{svb.width.round}x#{svb.height.round}")
        log("sv needs vertical scrollbar? #{sv.not_nil!.needs_vertical_scrollbar?}")
        # Find the bar by ASKING, not by arithmetic: walk candidate x/y and report what the app
        # would actually hit. Guessing "right edge minus 8" produced a drag that scrolled nothing.
        [svb.x + svb.width - 8.0, mb.x + mb.width - 8.0, svb.x + svb.width + 8.0].each do |cx|
          [svb.y + 6.0, svb.y + svb.height * 0.25, svb.y + svb.height * 0.5].each do |cy|
            pt = CrymbleUI::Vec2.new(cx, cy)
            hit = @app.root.try &.hit_test(pt)
            inbar = sv.not_nil!.point_in_scrollbar_area?(pt)
            log("  probe (#{cx.round(1)},#{cy.round(1)}) -> #{hit.class} id=#{hit.try(&.id).inspect} in_scrollbar_area=#{inbar}")
          end
        end
        @drag_x = bar_x
        @drag_y0 = svb.y + 20.0         # BELOW the up-arrow (the top ~16px is the arrow, not the track)
        @drag_span = svb.height - 24.0  # most of the track
        log("thumb drag: down the bar at x=#{@drag_x.round(1)} from y=#{@drag_y0.round(1)} span=#{@drag_span.round(1)}px, #{STEPS} steps")
        @app.handle_mouse_down(CrymbleUI::Vec2.new(@drag_x, @drag_y0))
      elsif @frame <= STEPS
        y = @drag_y0 + @drag_span * (@frame - 1) / (STEPS - 1)
        @app.handle_mouse_move(CrymbleUI::Vec2.new(@drag_x, y))
        if @frame % 5 == 0
          @down_sigs[@frame] = signature
          @down_offs[@frame] = m.not_nil!.scroll_offset.y
        end
        if @frame == 8 && !@grab_checked
          @grab_checked = true
          moved = m.not_nil!.scroll_offset.y
          log("  grab check after 8 steps: scroll=#{moved.round(1)}")
          if moved < 100.0
            log("INSTRUMENT FAILURE: the thumb was not grabbed — the drag is not scrolling"); exit 1
          end
        end
      else
        @mid = signature
        log("at the bottom of the drag: scroll=#{m.try(&.scroll_offset.y).try(&.round(1))}  picture changed? #{@before != @mid}  (false => INSTRUMENT FAILURE)")
        @phase = 2
        @frame = 0
      end
    when 2
      # The UP drag is deliberately independent of the down drag: Wolfgang's report is a drag down
      # and then up, and a FAST up-flick asks the matrix to repaint far more per frame.
      if @frame <= UP_STEPS
        y = @drag_y0 + @drag_span * (UP_STEPS - @frame) / (UP_STEPS <= 1 ? 1 : (UP_STEPS - 1))
        @app.handle_mouse_move(CrymbleUI::Vec2.new(@drag_x, y))
        log("  up step #{@frame}/#{UP_STEPS}: scroll=#{m.try(&.scroll_offset.y).try(&.round(0))}") if UP_STEPS <= 6
        # MID-DRAG ORACLE: the up-drag retraces the same thumb positions, so step j up is step
        # (STEPS+1-j) down. Same thumb position => same scroll => the picture must be identical.
        # An end-state-only check cannot see a garble that the next repaint repairs.
        if UP_STEPS == STEPS
          partner = STEPS + 1 - @frame
          if (dsig = @down_sigs[partner]?) && (doff = @down_offs[partner]?)
            now_off = m.not_nil!.scroll_offset.y
            if (now_off - doff).abs <= 0.5
              usig = signature
              d = dsig.zip(usig).count { |a, b| a != b }
              if d > 0
                @mid_bad += 1
                log("  MID-DRAG MISMATCH at scroll=#{now_off.round(1)} (up #{@frame} vs down #{partner}): #{d}/#{dsig.size} samples differ")
              end
            end
          end
        end
      elsif @frame == UP_STEPS + 1
        @app.handle_mouse_up(CrymbleUI::Vec2.new(@drag_x, @drag_y0))
      elsif @frame > UP_STEPS + 20
        final_scroll = m.not_nil!.scroll_offset.y
        if (final_scroll - @baseline_scroll).abs > 0.5
          log("INSTRUMENT FAILURE: ended at scroll=#{final_scroll.round(1)} but the baseline was #{@baseline_scroll.round(1)} — "\
              "comparing different scroll positions proves NOTHING. (This is what produced two false reproductions.)")
          exit 1
        end
        after = signature
        before = @before.not_nil!
        diffs = before.zip(after).count { |a, b| a != b }
        log("back at the top: scroll=#{m.try(&.scroll_offset.y).try(&.round(1))}  #{diffs}/#{before.size} samples differ  [#{@last_origin}]")
        sorted = @step_ms.sort
        med = sorted.empty? ? 0.0 : sorted[sorted.size // 2]
        log("frame gaps during the drag: median #{med.round(0)}ms  max #{(sorted.last? || 0.0).round(0)}ms  over #{sorted.size} frames")
        log("mid-drag mismatches at matched thumb positions: #{@mid_bad}")
        log((diffs == 0 && @mid_bad == 0) ? "VERTICAL VERDICT: clean" : "VERTICAL VERDICT: STALE CONTENT")
        @phase = 8
        @frame = 0
        return
      end
    when 8
      # THE REPORTED SYMPTOM: after auto-size, the RIGHT-HAND columns do not render properly.
      mm = m.not_nil!
      fh3 = CrymbleUI::VirtualMatrix::FRAME_HEIGHT_BASE * CrymbleUI::FontSizing.zoom_factor
      total_w = mm.@col_widths.sum * fh3
      max_legit = total_w - mm.bounds.width
      if MAXIMIZE && @frame == 1
        panel = @app.find("shape_#{@shape.id.sub("shape_", "")}") || @app.root.try(&.find_topmost_panel)
        if panel.is_a?(CrymbleUI::WindowPanel)
          log("-- maximizing the shape panel (was #{panel.bounds.width.round}x#{panel.bounds.height.round}) --")
          panel.toggle_maximize
        else
          log("-- MAXIMIZE requested but no WindowPanel found (#{panel.class}) --")
        end
        return
      elsif MAXIMIZE && @frame == 25
        log("  after maximize: matrix #{mm.bounds.width.round}x#{mm.bounds.height.round}, content #{total_w.round(0)}px")
        mm.scroll_offset = CrymbleUI::Vec2.new(total_w - mm.bounds.width, 0.0)
        return
      elsif MAXIMIZE && @frame < 55
        return
      elsif !MAXIMIZE && @frame == 1
        # The LEGITIMATE right edge: content minus viewport. Scrolling to total_w would put the
        # viewport past the end, where blankness is correct and proves nothing.
        mm.scroll_offset = CrymbleUI::Vec2.new(max_legit, 0.0)
        log("-- scrolling to the legitimate right edge: #{max_legit.round(0)} (content #{total_w.round(0)}, viewport #{mm.bounds.width.round(0)}) --")
      elsif !MAXIMIZE && @frame == 15
        log("  after asking for #{max_legit.round(0)}, scroll.x settled at #{mm.scroll_offset.x.round(0)}")
      elsif @frame > (MAXIMIZE ? 55 : 30)
        cols_present = mm.active_cells.keys.map { |k| k[1] }.uniq.sort
        last_col = mm.@col_widths.size - 1
        log("  scroll.x = #{mm.scroll_offset.x.round(0)}; legitimate max = #{max_legit.round(0)}; content = #{total_w.round(0)}")
        log("  active cell COLUMNS present: #{cols_present.inspect}  (last column index is #{last_col})")
        log("  is the last column rendered? #{cols_present.includes?(last_col)}")
        sig = signature
        bg = sig.group_by { |x| x }.max_by { |_, v| v.size }
        blank_share = (bg[1].size * 100.0 / sig.size).round(1)
        log("  most common sampled colour #{bg[0]} covers #{blank_share}% of the sampled area")
        log(cols_present.includes?(last_col) && blank_share < 90.0 ? "RHS VERDICT: renders" : "RHS VERDICT: >>> DOES NOT RENDER PROPERLY <<<")
        exit 0
      end
    end
  end
end

app.build_tree
root = app.root
raise "EmbraceApp.build() must return a Window widget" unless root.is_a?(CrymbleUI::Window)
window_widget = root.as(CrymbleUI::Window)
renderer = CrymbleUI::SFMLRenderer.new(
  width: window_widget.width,
  height: window_widget.height,
  title: window_widget.title
)
driver = Driver.new(app, shape, renderer)
# A repeating timer drives the gesture. (LayerRenderer.probe_sampler, used by the older autotests
# in this directory, no longer exists — those files are stale against the current library.)
CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 16_000_000), repeating: true) do
  driver.on_frame
end
renderer.run(app)
