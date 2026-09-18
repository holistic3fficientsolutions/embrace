# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only
#
# DIAGNOSTIC BUILD ONLY — compiled in by `-Dprobe`, absent otherwise.
#
# Written for one shot: the user runs an instrumented release on his own machine and sends back a
# single log. There is no second round, so this over-collects on purpose and never caps the file.
#
# What it watches, and why each one is here rather than guessed at:
#   * CACHE DIVERGENCE — NOT in a build a human runs. `-Dcache_validation` is a HEADLESS gate
#     (tools/cv-coherency.sh): its capture_region_pixels does a GPU->CPU copy_to_image and then ONE
#     FFI get_pixel CALL PER PIXEL, per viewport-cache layer, twice a frame. Headless that is an
#     array index and costs nothing; on a GPU it is ~1.15M FFI calls per capture at 1440x800 and the
#     FIRST FRAME NEVER FINISHES — a black window and a log that stops after its header. That cost a
#     round-trip to the user's machine. The flag is kept below because the drain is correct when a
#     headless build sets it; never combine it with a build someone is meant to click on.
#     What it does when it does run: the immediate-mode validator re-renders every
#     viewport-cache CONTENT layer from scratch and compares it pixel-by-pixel with the cached
#     buffer. That IS "stale content showing through", as a mechanism the project already trusts
#     (tools/cv-coherency.sh). It records into CacheValidation.failures and only raises when a spec
#     calls assert_no_failures!, so an app build accumulates silently — this drains it every frame.
#   * THE VISIBLE-CELL INVARIANT — every visible (row, col) must have a live cell widget. This is
#     the signature of the blank-last-column bug: the matrix considered the column
#     visible and created nothing for it.
#   * THE REGION CACHE — the keys and both cumulative arrays. That bug's root cause was the key
#     computed in scroll space while the filter that decides the result reads physical space.
#   * FRAME GAPS — a multi-second gap is the auto-size whole-table re-measure,
#     which is what "the app freezes before you can scroll it" actually is.
#
# WHAT IT CANNOT SEE, stated here and in the log header so a quiet log is never read as a clean
# bill of health: the validator covers viewport-cache CONTENT layers only. STICKY layers are
# excluded (the immediate-mode path mispositions sticky cells, so they would be false positives),
# and non-matrix layers participate only if they opt in via Layer#cv_validate. A fault in a sticky
# row or column is invisible to this instrument.
{% if flag?(:probe) %}
module EmbraceProbe
  BUILD_REV = {{ (env("GITHUB_SHA") || `git rev-parse --short HEAD 2>/dev/null || echo unknown`.stringify.chomp) }}

  @@io : File? = nil
  @@frame = 0
  @@last = Time.instant
  @@last_shape_sig = Hash(String, String).new
  @@violations = 0
  @@last_flush = Time.instant
  @@sticky_sig = Hash(String, String).new
  @@sticky_clear = Hash(String, UInt64).new
  @@stable = Hash(String, Int32).new
  @@state_key = Hash(String, String).new
  @@settled = Hash(String, Array(String)).new

  def self.path : String
    return ENV["EMBRACE_PROBE_LOG"] if ENV.has_key?("EMBRACE_PROBE_LOG")
    dir = begin
      exe = Process.executable_path
      exe ? File.dirname(exe) : Dir.current
    rescue
      Dir.current
    end
    File.join(dir, "embrace-probe-#{Time.local.to_s("%Y%m%d-%H%M%S")}.log")
  end

  def self.log(s : String) : Nil
    if io = @@io
      io.puts(s)
      # Flush often enough to survive a crash, but NOT once per line: at 60fps with several lines a
      # frame that is hundreds of fsyncs a second, which on Windows is itself a stall.
      now = Time.instant
      if (now - @@last_flush).total_milliseconds > 400
        @@last_flush = now
        io.flush
      end
    end
  rescue
    # never let the instrument kill the app it is measuring
  end

  @@app : EmbraceApp? = nil
  @@armed = false

  # The scheduler does not exist until the renderer installs it (Widget.scheduler? is nil before
  # then, and the raising accessor is what made the first instrumented build die on startup with
  # "Scheduler not initialized" - a log file and no window). So start() only opens the log, and the
  # timer is armed from the first rendered frame, via EmbraceApp#overlay_primitives.
  def self.arm_if_needed : Nil
    return if @@armed
    sched = CrymbleUI::Widget.scheduler?
    return unless sched
    app = @@app
    return unless app
    @@armed = true
    log "probe armed - the renderer's scheduler is up; ticking every 16ms from here"
    sched.schedule(Time::Span.new(nanoseconds: 16_000_000), repeating: true) { tick(app) }
  rescue ex
    log "!! PROBE ARM FAILED #{ex.class}: #{ex.message}"
  end

  def self.start(app) : Nil
    @@app = app
    @@io = File.open(path, "w")
    log "== embrace probe log =="
    log "build          #{BUILD_REV}   embrace #{Constant::Version}"
    log "crystal        #{Crystal::VERSION}   host #{ {{ flag?(:win32) ? "windows" : (flag?(:darwin) ? "darwin" : "linux") }} }"
    log "started        #{Time.local}"
    begin
      log "max texture    #{LibCSFML.sfTexture_getMaximumSize}"
    rescue ex
      log "max texture    UNAVAILABLE (#{ex.message})"
    end
    {% if flag?(:cache_validation) %}
      log "cache-validation ON — re-renders and compares every cached layer per frame."
      log "               WARNING: unusable on a real GPU. capture_region_pixels does one FFI"
      log "               get_pixel call PER PIXEL, so the first frame never finishes: black"
      log "               window, log stops here. It is a HEADLESS gate only."
    {% else %}
      log "cache-validation OFF — deliberately. It is a headless-only gate (see probe.cr); in an"
      log "               app build it never completes a frame. So this log cannot see stale-cache"
      log "               divergence directly — it watches the invariant, the keys and frame gaps."
    {% end %}
    log "STICKY          the rank column and the header row live on SEPARATE layers, and the"
    log "               garbling reported 2026-09-16 is THERE, not in the content layer. They are"
    log "               excluded from the cache validator by design (it mispositions sticky cells),"
    log "               so this probe samples them itself - see 'sticky' lines below."
    # Route the library's sticky blit-path lines into THIS log. stderr is useless in a -Dgui build
    # on Windows, which is where the report came from.
    CrymbleUI::BlitProbe.sink = ->(line : String) { log("f#{@@frame}   #{line}"); nil }
    log "BLIT PATH      instrumented: per-cell moved/size_changed/render_fresh/cached_texture, and"
    log "               the row/col/corner ACTIVE verdict. A cell that MOVED on a layer that stayed"
    log "               INACTIVE is the case to look for - nothing then clears what it left behind."
    log "columns below  frame | dt_ms | shape | matrix wxh @scroll | layer wxh origin | keys | cells"
    log ""
    # NOT scheduled here on purpose - see arm_if_needed.
    arm_if_needed
  end

  # The composition check itself — see the call site in #tick for why it compares two surfaces in
  # one instant instead of one surface across time.
  #
  # Two questions, and they fail differently:
  #   (a) UNDER A WIDGET — does the layer hold what that widget's own cached texture holds? A
  #       mismatch means the blit put the wrong thing there, or put nothing there and old ink
  #       survived underneath.
  #   (b) UNDER NO WIDGET — the uncovered region has no author this frame, so every pixel of it must
  #       be the same colour. A minority colour there is ink from a cell that has since moved, which
  #       is precisely what "remnants of other numbers" looks like.
  #
  # Only FULLY OPAQUE texture pixels are compared in (a): the blit is a straight full-texture copy,
  # so wherever a source pixel is translucent the layer legitimately shows a blend with whatever was
  # below, and comparing those would manufacture mismatches.
  #
  # Every layer sample is taken in ONE get_pixels_at call. That call is one GPU->CPU copy_to_image
  # plus an FFI read per point, so per-cell calls would have paid one full-texture copy per cell.
  # Returns {widgets disagreeing, mismatched samples, stray uncovered samples, uncovered samples}.
  # Public and value-returning because spec/autotest/sticky_composition_autotest.cr asserts on it:
  # an oracle that only writes to a log can be calibrated by nobody.
  def self.check_composition(m, lyr, be, dump : Bool = false) : Tuple(Int32, Int32, Int32, Int32)
    # SAMPLE ONLY THE VISIBLE WINDOW. The backend texture is a BUFFER and is routinely taller than
    # the layer displays: measured here at 129x439 for a layer 367px tall. Everything below the
    # displayed height is simply never painted, so sizing the sample region from the texture made
    # the oracle report every partially-visible bottom row as "the layer lost this cell" — five of
    # twelve stops on the first calibration run, all of them the instrument's own fault.
    # buffer_origin is the content coord sitting at buffer (0,0); the sticky blit computes its
    # destinations without that term, which is only sound while it is zero. It always has been on
    # these layers - so assert it rather than invent a mapping that has never been exercised.
    origin = lyr.buffer_origin
    if origin.x != 0.0 || origin.y != 0.0
      log "f#{@@frame}   composition check SKIPPED: sticky_col buffer_origin=#{fmt(origin.x)},#{fmt(origin.y)} " \
          "is non-zero, and the blit's destination arithmetic has no term for it — the mapping this " \
          "check would need is unverified, so it reports nothing rather than guessing."
      return {0, 0, 0, 0}
    end
    lw = {be.width, CrymbleUI::PixelSnap.origin(lyr.bounds.width)}.min
    lh = {be.height, CrymbleUI::PixelSnap.origin(lyr.bounds.height)}.min
    return {0, 0, 0, 0} if lw < 8 || lh < 8

    vm_abs = m.absolute_bounds
    dx = vm_abs.x - lyr.bounds.x
    dy = vm_abs.y - lyr.bounds.y

    # Where each widget's texture lands on the layer, by the same arithmetic the blit uses
    # (blit_plan.cr: dest = PixelSnap.origin(vm_abs + widget.bounds - layer.bounds)).
    placed = lyr.widgets.map do |w|
      b = w.bounds
      ox = CrymbleUI::PixelSnap.origin(dx + b.x)
      oy = CrymbleUI::PixelSnap.origin(dy + b.y)
      {w, ox, oy, CrymbleUI::PixelSnap.origin(dx + b.x + b.width) - ox,
       CrymbleUI::PixelSnap.origin(dy + b.y + b.height) - oy}
    end

    # Plan every sample first, read the layer once.
    plans = [] of Tuple(CrymbleUI::Widget, Int32, Int32, Int32, Int32, CrymbleUI::CrSFMLBackend, Array(Tuple(Int32, Int32)))
    layer_pts = [] of Tuple(Int32, Int32)
    placed.each do |(w, px, py, pw, ph)|
      wb = w.widget_backend
      next unless wb.is_a?(CrymbleUI::CrSFMLBackend)
      tw = {wb.width, pw}.min
      th = {wb.height, ph}.min
      next if tw < 4 || th < 4

      local = [] of Tuple(Int32, Int32)
      ty = 2
      while ty < th - 1
        tx = 2
        while tx < tw - 1
          # Keep only points that land on the layer: a sticky cell scrolled half out of view is
          # clipped, and its off-layer half has nothing to be compared against.
          local << {tx, ty} if (px + tx) >= 0 && (py + ty) >= 0 && (px + tx) < lw && (py + ty) < lh
          tx += 4
        end
        ty += 4
      end
      next if local.size < 4
      plans << {w, px, py, pw, ph, wb, local}
      local.each { |(tx2, ty2)| layer_pts << {px + tx2, py + ty2} }
    end

    open_pts = [] of Tuple(Int32, Int32)
    uy = 1
    while uy < lh - 1
      ux = 1
      while ux < lw - 1
        unless placed.any? { |(_, px, py, pw, ph)| ux >= px && ux < px + pw && uy >= py && uy < py + ph }
          open_pts << {ux, uy}
        end
        ux += 3
      end
      uy += 3
    end
    open_at = layer_pts.size
    open_pts.each { |p| layer_pts << p }
    return {0, 0, 0, 0} if layer_pts.empty?
    layer_px = be.get_pixels_at(layer_pts)

    bad_cells = 0
    bad_px = 0
    shown = 0
    at = 0
    plans.each do |(w, px, py, pw, ph, wb, local)|
      want = wb.get_pixels_at(local)
      diff = 0
      first : Tuple(Tuple(Int32, Int32), CrymbleUI::Color, CrymbleUI::Color)? = nil
      want.each_with_index do |c, i|
        next unless c.a == 255_u8
        g = layer_px[at + i]
        # Alpha is part of the comparison. The sticky column is composited OVER the content layer,
        # so a sticky pixel that is not fully opaque lets the scrolling content beneath show
        # through - which is what "remnants of other numbers under each number" would look like
        # from the outside. An RGB-only check calls that clean.
        next if g.r == c.r && g.g == c.g && g.b == c.b && g.a == c.a
        diff += 1
        first = {local[i], c, g} if first.nil?
      end
      at += local.size
      next if diff == 0

      bad_cells += 1
      bad_px += diff
      next if shown >= 8
      shown += 1
      key = m.active_cells.key_for?(w)
      pt, cw, cg = first.not_nil!
      log "f#{@@frame}    cell #{key ? "#{key[0]},#{key[1]}" : w.class.name} at layer(#{px},#{py}) #{pw}x#{ph}, " \
          "texture #{wb.width}x#{wb.height}: #{diff}/#{want.size} differ, " \
          "first at texel(#{pt[0]},#{pt[1]}) want=#{cw.r},#{cw.g},#{cw.b},a#{cw.a} got=#{cg.r},#{cg.g},#{cg.b},a#{cg.a}"
      dump_surfaces(wb, be, px, py, pw, ph) if dump && bad_cells == 1
    end

    stray = 0
    tally = Hash(String, Int32).new(0)
    if open_pts.size > 8
      open_pts.each_index { |i| c = layer_px[open_at + i]; tally["#{c.r},#{c.g},#{c.b},a#{c.a}"] += 1 }
      if tally.size > 1
        dominant = tally.max_by { |_, n| n }[0]
        stray = open_pts.size - tally[dominant]
        open_pts.each_with_index do |p, i|
          c = layer_px[open_at + i]
          k = "#{c.r},#{c.g},#{c.b},a#{c.a}"
          next if k == dominant
          next if shown >= 12
          shown += 1
          log "f#{@@frame}    stray ink at layer(#{p[0]},#{p[1]}) = #{k}, outside every widget " \
              "(the clear colour here is #{dominant})"
        end
      end
    end

    if !tally.empty?
      ground = tally.max_by { |_, n| n }[0]
      if (m2 = ground.match(/a(\d+)$/)) && m2[1].to_i < 255
        log "f#{@@frame} !! THE STICKY COLUMN'S OWN GROUND IS TRANSLUCENT (#{ground}) — the content layer " \
            "beneath it shows through wherever no cell paints, and the content layer scrolls."
      end
    end

    if bad_cells > 0 || stray > 0
      @@violations += 1
      log "f#{@@frame} !! LAYER IS NOT THE COMPOSITION OF ITS WIDGETS (violation ##{@@violations})"
      log "f#{@@frame}    sticky_col visible #{lw}x#{lh} of texture #{be.width}x#{be.height}, " \
          "layer at #{fmt(lyr.bounds.x)},#{fmt(lyr.bounds.y)} sized #{fmt(lyr.bounds.width)}x#{fmt(lyr.bounds.height)}  " \
          "vm_abs #{fmt(vm_abs.x)},#{fmt(vm_abs.y)}  scroll=#{fmt(m.scroll_offset.y)}"
      log "f#{@@frame}    #{bad_cells} of #{plans.size} widget textures disagree with the layer " \
          "(#{bad_px} sampled pixels); #{stray} of #{open_pts.size} uncovered samples are not the clear colour"
      log "f#{@@frame}    uncovered colours: " + tally.to_a.sort_by { |(_, n)| -n }.first(6).map { |(k, n)| "#{k}x#{n}" }.join("  ")
      log "f#{@@frame}    sticky cells: " + m.active_cells.select { |k, _| k[1] < m.sticky_col_count }
        .to_a.sort_by { |(k, _)| k }.first(12).map { |(k, wg)| "#{k[0]}@#{fmt(wg.bounds.y)}" }.join(" ")
      @@io.try &.flush
    else
      log "f#{@@frame}   composition clean: #{plans.size} widget textures, #{open_pts.size} uncovered samples, scroll=#{fmt(m.scroll_offset.y)}"
    end
    {bad_cells, bad_px, stray, open_pts.size}
  end

  # Both surfaces side by side as glyph maps, for the first cell that disagrees. Colours are
  # reduced to three classes because the question is WHICH INK is where, not its exact value:
  # `.` the layer's own dark ground, `#` anything markedly brighter (a glyph or a highlight), `+`
  # anything else. A texture that reads as a different GLYPH from the layer is a recycled cell whose
  # cache was never repainted; the same glyph on a different ground is a highlight that one surface
  # has and the other does not.
  private def self.dump_surfaces(wb, be, px : Int32, py : Int32, pw : Int32, ph : Int32) : Nil
    tw = {wb.width, pw}.min
    th = {wb.height, ph}.min
    glyph = ->(c : CrymbleUI::Color) do
      lum = (c.r.to_i + c.g.to_i + c.b.to_i) // 3
      lum < 40 ? '.' : (lum > 90 ? '#' : '+')
    end
    ty = 0
    while ty < th
      pts = [] of Tuple(Int32, Int32)
      tx = 0
      while tx < tw
        pts << {tx, ty}
        tx += 2
      end
      tex = wb.get_pixels_at(pts)
      lay = be.get_pixels_at(pts.map { |(ax, ay)| {px + ax, py + ay} })
      log "f#{@@frame}      y=#{ty.to_s.rjust(2)}  texture |#{tex.map { |c| glyph.call(c) }.join}|  layer |#{lay.map { |c| glyph.call(c) }.join}|"
      ty += 2
    end
  end

  # The same check addressed by matrix alone, for callers that have not dug out the layer.
  # Returns nil when there is nothing to check (no sticky column, or not an SFML backend).
  def self.check_sticky_composition(m, dump : Bool = false) : Tuple(Int32, Int32, Int32, Int32)?
    check_one_sticky(m, "col", dump)
  end

  # All three sticky layers, so the question "is this only the row headers?" is answered by
  # measurement. The column headers live on sticky_row_layer and the cluster corner on
  # sticky_corner_layer; all three are non-viewport_cache and all three are repainted by the same
  # two passes, so the same hole should reach them on a fast HORIZONTAL jump.
  def self.check_all_sticky(m, dump : Bool = false) : Hash(String, Tuple(Int32, Int32, Int32, Int32))
    out = Hash(String, Tuple(Int32, Int32, Int32, Int32)).new
    {"col", "row", "corner"}.each do |which|
      if v = check_one_sticky(m, which, dump)
        out[which] = v
      end
    end
    out
  end

  private def self.check_one_sticky(m, which : String, dump : Bool) : Tuple(Int32, Int32, Int32, Int32)?
    sv = m.content_scroll_view
    return nil unless sv
    lyr = case which
          when "row"    then sv.sticky_row_layer
          when "corner" then sv.sticky_corner_layer
          else               sv.sticky_col_layer
          end
    return nil unless lyr
    be = lyr.backend
    return nil unless be.is_a?(CrymbleUI::CrSFMLBackend)
    check_composition(m, lyr, be, dump)
  end

  private def self.fmt(v) : String
    v.nil? ? "-" : v.to_s
  end

  def self.tick(app) : Nil
    now = Time.instant
    dt = (now - @@last).total_milliseconds
    @@last = now
    @@frame += 1

    {% if flag?(:cache_validation) %}
      fails = CrymbleUI::CacheValidation.failures
      unless fails.empty?
        fails.each do |f|
          x, y, cached, uncached = f.first_mismatch
          log "f#{@@frame} !! CACHE DIVERGENCE level=#{f.cache_level} layer=#{f.layer_id} " \
              "cv_frame=#{f.frame} mismatches=#{f.mismatch_count}/#{f.total_pixels} " \
              "first=(#{x},#{y}) cached=0x#{cached.to_s(16)} uncached=0x#{uncached.to_s(16)}"
        end
        CrymbleUI::CacheValidation.clear_failures!
      end
    {% end %}

    log "f#{@@frame} SLOW dt=#{dt.round(0)}ms  (auto-size whole-table re-measure looks like this)" if dt > 250.0

    app.shapes.each do |shape|
      w = app.find("matrix_grid_#{shape.id}")
      next unless w.is_a?(CrymbleUI::VirtualMatrix)
      m = w.as(CrymbleUI::VirtualMatrix)
      b = m.bounds
      lay = m.layer
      vis_r = m.@visible_rows
      vis_c = m.@visible_cols

      # THE INVARIANT. Every visible (row, col) needs a live widget.
      missing = [] of Tuple(Int32, Int32)
      vis_r.each { |r| vis_c.each { |c| missing << {r, c} unless m.@active_cells.has_key?({r, c}) } }

      line = "f#{@@frame} dt=#{dt.round(0)} #{shape.id} " \
             "m=#{b.width.round(0)}x#{b.height.round(0)}@#{m.scroll_offset.x.round(0)},#{m.scroll_offset.y.round(0)} " \
             "lay=#{lay ? "#{lay.bounds.width.round(0)}x#{lay.bounds.height.round(0)}" : "-"}" \
             "#{lay ? "org#{lay.buffer_origin.x.round(0)},#{lay.buffer_origin.y.round(0)}" : ""} " \
             "ckey=#{fmt(m.@last_creation_col_key)}/#{fmt(m.@last_creation_row_key)} " \
             "dkey=#{fmt(m.@last_destruction_col_key)}/#{fmt(m.@last_destruction_row_key)} " \
             "vis=#{vis_r.size}x#{vis_c.size} cells=#{m.@active_cells.size} autosize=#{m.auto_size}"
      log line

      # THE STICKY LAYERS. The rank column is one; the reported garbling is old glyphs surviving
      # there. They carry their own buffers, so their geometry and their PIXELS have to be watched
      # separately from the content layer - sampling only m.layer is what made an earlier hunt
      # report "clean" while the rank column was visibly wrong.
      if sv = m.content_scroll_view
        {"col", sv.sticky_col_layer, "row", sv.sticky_row_layer}.each_slice(2) do |pair|
          nm = pair[0].as(String)
          lyr = pair[1].as(CrymbleUI::Layer?)
          next unless lyr
          log "f#{@@frame}   sticky_#{nm} #{lyr.bounds.width.round(0)}x#{lyr.bounds.height.round(0)} " \
              "scroll=#{lyr.scroll_offset.y.round(1)} origin=#{lyr.buffer_origin.y.round(1)}"
        end
        # THE DETECTOR. The reported garbling is old rank numbers surviving UNDER the new ones, which
        # is not a pixel-identity question but a clear-before-redraw one: the sticky layer being
        # re-rendered without its buffer being cleared first. Layer#clear_rev is a monotonic count of
        # clear events, so the rule needs no GPU readback at all:
        #
        #   if the sticky cells MOVED but clear_rev did NOT advance, whatever was there before is
        #   still there underneath.
        #
        # The pixel hash below cannot make that call - the rank column carries the selection
        # highlight, so it changes legitimately when the cursor moves, and two runs of the app showed
        # exactly that ambiguity.
        if lyr = sv.sticky_col_layer
          sticky_cells = m.active_cells.select { |k, _| k[1] < m.sticky_col_count }
          sig = sticky_cells.keys.sort.map { |k| "#{k[0]}@#{m.active_cells[k].bounds.y.round(1)}" }.join(",")
          key = "#{shape.id}"
          prev_sig = @@sticky_sig[key]?
          prev_clear = @@sticky_clear[key]?
          now_clear = lyr.clear_rev
          if prev_sig && prev_clear && sig != prev_sig && now_clear == prev_clear
            @@violations += 1
            log "f#{@@frame} !! STICKY REDRAWN WITHOUT A CLEAR (violation ##{@@violations})"
            log "f#{@@frame}    clear_rev stayed #{now_clear} while the sticky cells moved"
            log "f#{@@frame}    was: #{prev_sig[0, 160]}"
            log "f#{@@frame}    now: #{sig[0, 160]}"
            log "f#{@@frame}    scroll=#{m.scroll_offset.y.round(1)} layer_scroll=#{lyr.scroll_offset.y.round(1)} origin=#{lyr.buffer_origin.y.round(1)}"
            @@io.try &.flush
          end
          @@sticky_sig[key] = sig
          @@sticky_clear[key] = now_clear
        end

        # COMPOSITION ORACLE. A layer must BE the composition of the widgets on it: every pixel
        # either lies under one of them and equals that widget's own cached texture at the same
        # offset, or lies under none and carries whatever the clear left behind. Both surfaces are
        # read in the SAME INSTANT, which is the entire point. The oracle this replaced compared the
        # layer with ITSELF twenty frames apart and fired twice on Wolfgang's run; both times it was
        # embrace's change-highlight fade (Shape::HIGHLIGHT_STAGES spans three seconds) repainting a
        # cell inside the window - the app working correctly. A fade moves the cell's texture and
        # the layer together, so it cannot produce a mismatch here.
        #
        # Runs once per settled state (nothing changed for 20 frames): the reads cost one
        # copy_to_image per texture, which is far too much per frame and nothing at all once.
        if lyr2 = sv.sticky_col_layer
          skey = "#{shape.id}"
          state = "#{m.scroll_offset.y.round(0)}|#{m.@col_widths.hash}|#{lyr2.bounds.width.round(0)}x#{lyr2.bounds.height.round(0)}|#{m.active_cells.size}"
          if @@state_key[skey]? == state
            @@stable[skey] = (@@stable[skey]? || 0) + 1
          else
            @@state_key[skey] = state
            @@stable[skey] = 0
          end

          if @@stable[skey]? == 20
            be2 = lyr2.backend
            check_composition(m, lyr2, be2) if be2.is_a?(CrymbleUI::CrSFMLBackend)
          end
        end

        # Pixel fingerprint of the sticky COLUMN, every 20th frame. At the SAME scroll offset it
        # must not change; if it does, something is drawing over stale content. Kept to one narrow
        # layer and one frame in twenty because each sample is an FFI call per pixel.
        if @@frame % 20 == 0
          lyr = sv.sticky_col_layer
          be = lyr.try &.backend
          if lyr && be.is_a?(CrymbleUI::CrSFMLBackend)
            w = {be.width, 80}.min
            h = {be.height, 400}.min
            if w > 4 && h > 4
              px = be.get_pixels(0, 0, w, h)
              hsh = 0_u64
              px.each_with_index { |c, i| hsh = (hsh &* 31 &+ (c.r.to_u64 << 16 | c.g.to_u64 << 8 | c.b.to_u64)) if i % 7 == 0 }
              log "f#{@@frame}   sticky_col_pixels #{shape.id} hash=#{hsh} scroll=#{m.scroll_offset.y.round(1)} " \
                  "(same scroll + different hash = STALE CONTENT on the sticky layer)"
            end
          end
        end
      end

      unless missing.empty?
        @@violations += 1
        cols_missing = missing.map { |x| x[1] }.uniq.sort
        log "f#{@@frame} !! VISIBLE CELLS WITH NO WIDGET: #{missing.size} " \
            "columns=#{cols_missing.inspect} rows=#{missing.map { |x| x[0] }.uniq.sort.first(8).inspect} " \
            "(violation ##{@@violations})"
        log "f#{@@frame}    visible_cols=#{vis_c.inspect} visible_rows=#{vis_r.first(12).inspect}"
        log "f#{@@frame}    col_widths=#{m.@col_widths.map(&.round(2)).inspect}"
        log "f#{@@frame}    col_cumulative=#{fmt(m.@cached_col_cumulative)}"
        log "f#{@@frame}    col_physical=#{fmt(m.@cached_col_physical_cum)}"
        log "f#{@@frame}    col_scroll_rank=#{fmt(m.@cached_col_scroll_rank)}"
        log "f#{@@frame}    row_cumulative=#{m.@cached_row_cumulative.try(&.first(16)).inspect}"
        log "f#{@@frame}    CREATION_BUFFER=#{CrymbleUI::VirtualMatrix::CREATION_BUFFER}"
        @@io.try &.flush # a violation is the payload; never risk losing it to a crash
      end

      # The geometry arrays are large; log them whenever they CHANGE, so every state the matrix
      # was in is recoverable without repeating them 60 times a second.
      sig = "#{m.@col_widths.hash}/#{m.@row_heights.size}/#{b.width}/#{b.height}"
      if @@last_shape_sig[shape.id]? != sig
        @@last_shape_sig[shape.id] = sig
        log "f#{@@frame} ~~ GEOMETRY CHANGED #{shape.id}"
        log "f#{@@frame}    col_widths=#{m.@col_widths.map(&.round(2)).inspect}"
        log "f#{@@frame}    col_cumulative=#{fmt(m.@cached_col_cumulative)}"
        log "f#{@@frame}    col_physical=#{fmt(m.@cached_col_physical_cum)}"
        log "f#{@@frame}    col_scroll_rank=#{fmt(m.@cached_col_scroll_rank)}"
        log "f#{@@frame}    rows=#{m.@row_heights.size} total_h=#{m.@row_heights.sum.round(1)}"
      end
    end
  rescue ex
    log "f#{@@frame} !! PROBE ERROR #{ex.class}: #{ex.message}"
  end
end
{% end %}
