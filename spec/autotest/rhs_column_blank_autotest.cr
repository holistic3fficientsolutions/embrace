require "../spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "../../src/gui/probe"

# THE REPORTED SYMPTOM, from Wolfgang's own data (/tmp/text.txt, screenshots 2026-09-15):
# paste a big .tsv, switch on Auto-size, widen the Shape — and the LAST column (c8) renders as flat
# dark grey: its header is drawn, its body cells are not there at all. Ctrl+0 does not help; zooming
# does, and zoom is one of the three sites that re-arm @auto_size_pending (virtual_matrix.cr:1571),
# so the state right after auto-size is wrong and a re-measure repairs it.
#
# The data matters and is NOT synthetic here: 2561 records x 7 fields, and field 7 (the app's c8) is
# EMPTY in 1697 of them while holding one cell of 2647 chars across 37 LINES — a row ~900px tall in
# a ~370px viewport. Built through the real paste path (TSV.decode -> import_rows), not by API.
#
# Run: source setup.sh
#      crystal build spec/autotest/rhs_column_blank_autotest.cr -o /tmp/rhs
#      DISPLAY=:0 timeout 300 /tmp/rhs
# Env: RHS_TSV (default /tmp/text.txt), RHS_NOAUTOSIZE=1 to skip the toggle (control).

TSV_PATH = ENV["RHS_TSV"]? || "/tmp/text.txt"
DO_AUTOSIZE = ENV["RHS_NOAUTOSIZE"]? != "1"

text = File.read(TSV_PATH)
rows = TSV.decode(text)
width = rows.max_of(&.size)
puts "fixture: #{rows.size} records x #{width} fields from #{TSV_PATH}"

app = EmbraceApp.new
persistency = app.persistency
cells = rows.map do |row|
  Array(Persistency::Cell).new(width) { |i| (row[i]? || "").as(Persistency::Cell) }
end
t_lid = persistency.import_rows(cells, "", Array.new(width, ""))
app.shapes.clear
shape = ShapeState.new("Pasted", persistency, persistency.context.clone, t_lid)
app.shapes << shape

class Driver
  @phase = 0
  @frame = 0
  def initialize(@app : EmbraceApp, @shape : ShapeState)
  end

  private def matrix : CrymbleUI::VirtualMatrix?
    @app.find("matrix_grid_#{@shape.id}").try &.as(CrymbleUI::VirtualMatrix)
  end

  private def log(s : String); puts s; STDOUT.flush; end

  # Which columns have BODY cells (row > 0), and which have only a header.
  private def report(tag : String)
    m = matrix
    return unless m
    cols = m.@col_widths.size
    fh = CrymbleUI::VirtualMatrix::FRAME_HEIGHT_BASE * CrymbleUI::FontSizing.zoom_factor
    body = Hash(Int32, Int32).new(0)
    head = Hash(Int32, Int32).new(0)
    m.active_cells.each { |k, _| (k[0] == 0 ? head : body)[k[1]] += 1 }
    log("#{tag}: matrix #{m.bounds.width.round}x#{m.bounds.height.round}, #{cols} columns, " \
        "widths(px)=#{m.@col_widths.map { |w| (w * fh).round(0).to_i }.inspect}")
    log("#{tag}: BODY cells per column = #{(0...cols).map { |c| {c, body[c]} }.to_h}")
    log("#{tag}: HEADER cells per column = #{(0...cols).map { |c| {c, head[c]} }.to_h}")
    last = cols - 1
    # Is the last column even IN VIEW? A column entirely past the right edge having no cells is
    # correct virtualisation, not the symptom. The screenshot shows c8's HEADER drawn with dark grey
    # underneath, so the symptom requires overlap with the viewport.
    x0 = (0...last).sum { |c| m.@col_widths[c] } * fh
    x1 = x0 + m.@col_widths[last] * fh
    vx0 = m.scroll_offset.x
    vx1 = vx0 + m.bounds.width
    overlaps = x1 > vx0 && x0 < vx1
    # DIRECT OBSERVATION of the creation-region cache (virtual_matrix.cr:2860-2882). The cells come
    # from here, NOT from visible_cols. Key is {ns, ib} where
    #   max_pos = scroll_pos + viewport_size + CREATION_BUFFER
    #   ib      = cumulative.bsearch_index { |p| p > max_pos }
    # so it records WHICH COLUMN BOUNDARY the viewport edge falls past, not the viewport size.
    ckey = m.@last_creation_col_key
    cres = m.@last_creation_col_result
    vpw = m.layer.try(&.bounds.width) || m.bounds.width
    maxpos = (m.scroll_offset.x + vpw + CrymbleUI::VirtualMatrix::CREATION_BUFFER).ceil.to_i
    log("#{tag}: CREATION-REGION CACHE key=#{ckey.inspect} result=#{cres.inspect} " \
        "| viewport_for_key=#{vpw.round(0)} max_pos=#{maxpos} | last column in creation region? " \
        "#{cres.try(&.includes?(m.@col_widths.size - 1)).inspect}")
    # THE TWO ARRAYS THE KEY AND THE FILTER USE. Built at virtual_matrix.cr:2248-2251 —
    #   cumulative   = scroll_order.map{sizes}.accumulate{ }   (NO leading 0)
    #   physical_cum = sizes.accumulate(0){ }                  (WITH a leading 0)
    # The key bsearches `cumulative`; the filter indexes `physical_cum`. Different orders AND
    # different index spaces.
    log("#{tag}: col scroll_rank  = #{m.@cached_col_scroll_rank.inspect}")
    log("#{tag}: col cumulative   = #{m.@cached_col_cumulative.inspect}")
    log("#{tag}: col physical_cum = #{m.@cached_col_physical_cum.inspect}")
    log("#{tag}: row scroll_rank  = #{m.@cached_row_scroll_rank.try(&.first(8)).inspect}…")
    log("#{tag}: row cumulative   = #{m.@cached_row_cumulative.try(&.first(8)).inspect}…")
    # ROW AXIS — the same function serves rows (virtual_matrix.cr:2369-2371). If the fault is in
    # compute_region_cached rather than in the column case, a huge ROW must reproduce it vertically.
    rkey = m.@last_creation_row_key
    rres = m.@last_creation_row_result
    vph = m.layer.try(&.bounds.height) || m.bounds.height
    rmaxpos = (m.scroll_offset.y + vph + CrymbleUI::VirtualMatrix::CREATION_BUFFER).ceil.to_i
    rows_present = m.active_cells.keys.map { |k| k[0] }.uniq.sort
    log("#{tag}: ROW CACHE key=#{rkey.inspect} result=#{rres.inspect} | viewport_h=#{vph.round(0)} max_pos=#{rmaxpos}")
    log("#{tag}: rows with cells = #{rows_present.first(40).inspect}#{rows_present.size > 40 ? "…" : ""}")
    lay = m.layer
    log("#{tag}: matrix #{m.bounds.width.round}x#{m.bounds.height.round} | CONTENT LAYER " \
        "#{lay ? "#{lay.bounds.width.round}x#{lay.bounds.height.round}" : "nil"} " \
        "| visible_cols=#{m.@visible_cols.inspect} last_key=#{m.@last_visible_key.inspect}")
    log("#{tag}: last column spans #{x0.round(0)}..#{x1.round(0)}px; viewport #{vx0.round(0)}..#{vx1.round(0)}px; in view? #{overlaps}")
    verdict = if !overlaps
                "(off-screen — no cells is CORRECT, proves nothing)"
              elsif body[last] == 0
                "<<< IN VIEW WITH NO BODY CELLS — SYMPTOM REPRODUCED"
              else
                "renders"
              end
    log("#{tag}: >>> LAST COLUMN c#{last}: header=#{head[last]} body=#{body[last]} #{verdict}")
  end

  def on_frame
    @frame += 1
    m = matrix
    case @phase
    when 0
      ready = m && m.absolute_bounds.width > 50 && !m.active_cells.empty?
      unless ready
        log("waiting… #{(@frame * 16 / 1000.0).round(1)}s") if @frame % 120 == 0
        if @frame > 5600 # ~90s: this fixture is big and auto-size is O(table)
          log("INSTRUMENT FAILURE: matrix never laid out"); exit 1
        end
        return
      end
      report("BEFORE auto-size")
      unless DO_AUTOSIZE
        log("(RHS_NOAUTOSIZE=1 — stopping here, this is the control)")
        exit 0
      end
      @phase = 1
      @frame = 0
    when 1
      if @frame == 1
        log("-- switching Auto-size ON (the View-menu path) --")
        @t = Time.instant
        @shape.auto_size_cells = true
        @shape.matrix_adapter.try &.invalidate_all!
        @app.request_rebuild
      elsif @frame > 400 # auto-size on 2561 rows takes seconds; give it room
        log("auto-size settled after #{((Time.instant - @t).total_seconds).round(1)}s")
        report("AFTER auto-size")
        @phase = 2
        @frame = 0
      end
    when 2
      # Wolfgang WIDENED the Shape — his c8 header is visible with dark grey under it. Maximize so
      # the last column actually overlaps the viewport, which is the only state that can show the bug.
      if @frame == 1
        panel = @app.root.try(&.find_topmost_panel)
        if panel.is_a?(CrymbleUI::WindowPanel)
          if ENV["RHS_AXIS"]? == "row"
            log("-- growing the Shape's HEIGHT only (was #{panel.bounds.height.round}px) --")
            panel.height = panel.height + 200.0
            panel.mark_needs_layout
          else
            log("-- maximizing the Shape (was #{panel.bounds.width.round}px wide) --")
            panel.toggle_maximize
          end
        end
      elsif @frame == 60
        report("AFTER widening")
        # and scroll right so the last column is definitely in view
        mm = m.not_nil!
        fh2 = CrymbleUI::VirtualMatrix::FRAME_HEIGHT_BASE * CrymbleUI::FontSizing.zoom_factor
        total = mm.@col_widths.sum * fh2
        mm.scroll_offset = CrymbleUI::Vec2.new({total - mm.bounds.width, 0.0}.max, 0.0)
        log("-- scrolled right to #{mm.scroll_offset.x.round(0)} --")
      elsif @frame == 120
        report("AFTER widening + scroll right")
        @phase = 3
        @frame = 0
      end
    when 3
      # Wolfgang: "Ctrl+0 doesn't help; I need to e.g. zoom". Zoom re-arms the re-measure.
      if @frame == 1
        log("-- zooming (the thing that repairs it for him) --")
        CrymbleUI::FontSizing.zoom_in
        @app.request_rebuild
      elsif @frame > 300
        report("AFTER zoom")
        exit 0
      end
    end
  end
  @t = Time.instant
end

app.build_tree
root = app.root
raise "expected a Window" unless root.is_a?(CrymbleUI::Window)
w = root.as(CrymbleUI::Window)
# Wolfgang's window is ~1700px wide: wide enough that the last column STARTS inside the viewport
# and runs off the right edge — its header drawn, its body the thing in question. At 1100px the
# column begins past the edge and is legitimately absent, which proves nothing.
win_w = (ENV["RHS_W"]? || w.width.to_i.to_s).to_i
win_h = (ENV["RHS_H"]? || w.height.to_i.to_s).to_i
renderer = CrymbleUI::SFMLRenderer.new(width: win_w, height: win_h, title: w.title)
{% if flag?(:probe) %}
  # Validate the shipping instrument on a bug we can produce on demand: build this autotest with
  # -Dprobe against the UNFIXED library and the probe's visible-cell detector must fire.
  EmbraceProbe.start(app)
{% end %}
driver = Driver.new(app, shape)
CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 16_000_000), repeating: true) { driver.on_frame }
renderer.run(app)
