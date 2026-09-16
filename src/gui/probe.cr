# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only
#
# DIAGNOSTIC BUILD ONLY — compiled in by `-Dprobe`, absent otherwise.
#
# Written for one shot: the user runs an instrumented release on his own machine and sends back a
# single log. There is no second round, so this over-collects on purpose and never caps the file.
#
# What it watches, and why each one is here rather than guessed at:
#   * CACHE DIVERGENCE — with `-Dcache_validation` the immediate-mode validator re-renders every
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
      io.flush # a crash must not take the log with it — this build exists to survive one
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
      log "cache-validation ON — every viewport-cache CONTENT layer is re-rendered and compared per frame"
    {% else %}
      log "cache-validation OFF — this build cannot see stale-cache divergence (rebuild with -Dcache_validation)"
    {% end %}
    log "COVERAGE GAP   sticky layers are NOT validated (false positives); non-matrix layers only if"
    log "               they opt into Layer#cv_validate. A quiet log means 'nothing seen in the"
    log "               covered layers', NOT 'nothing wrong'."
    log "columns below  frame | dt_ms | shape | matrix wxh @scroll | layer wxh origin | keys | cells"
    log ""
    # NOT scheduled here on purpose - see arm_if_needed.
    arm_if_needed
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
