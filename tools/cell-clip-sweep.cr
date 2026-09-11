require "../src/gui/embrace"

# Cell-clip sweep — the APP-LEVEL half of the clip-containment evidence.
#
#   crystal build tools/cell-clip-sweep.cr -o bin/cell-clip-sweep
#   DISPLAY=:0 ./bin/cell-clip-sweep <columns> <text_len> <multiline 0|1> <col1_plain_len> [header 0|1] [promote_row]
#
# WHAT IT MEASURES: how far a cell's glyph ink runs past the right edge of its column,
# in a REAL embrace window, through the real paste path. It exists because a cell's text
# used to escape its clip and paint across its neighbours into empty panel space, and
# because no headless spec can see that (TestRenderBackend clips in software, with no GL
# context). The backend-level witness lives in crymbleui: tools/clip-containment-probe.cr.
#
# It is IN-PROCESS end to end: the payload is fed via `Widget.clipboard.text=` (no OS
# clipboard, so the run is deterministic and needs no system tools) and the pixels are
# read back with `SFMLRenderer#capture_composited_frame`. Desktop screenshots are not
# admissible here — they are what produced two confident wrong diagnoses in this arc.
#
# HOW TO READ IT: `OVERSHOOT` is ink_right minus the last column's fill edge. 1 px is
# anti-aliasing and is what a correctly-clipped column reports. The historical failure
# read 35, 283, 443 px depending on how long COLUMN 1's text was — the escaping cell is
# the FIRST one drawn into the layer, not the last one; the last column merely has
# nothing painted after it to hide the spill.
#
# SELF-VALIDATION (it refuses to report rather than report vacuously): it needs glyph ink
# in the band, a cell-fill colour distinguishable from the panel fill, and a GLYPH-FREE
# scanline to read the column edge from. That last one is load-bearing — anti-aliased
# glyph pixels land within tolerance of the cell fill, so measuring the edge on any row
# tracked the ink instead of the cell and reported "contained" on a case that was plainly
# spilling.

COLS  = (ARGV[0]? || "2").to_i
TLEN  = (ARGV[1]? || "44").to_i
MULTI = (ARGV[2]? || "1") == "1"
# Length of a PLAIN (unquoted, single-line) value in column 1; 0 = column 1 gets the
# same value as the rest. The original field repro is cols=2 len=44 multi=1 plain1=29,
# and column widths turned out to depend on it, so it has to be a parameter.
PLAIN1 = (ARGV[3]? || "0").to_i
# Measure the sticky HEADER band instead of the first data row.
HEADER = (ARGV[4]? || "0") == "1"
HROW   = (ARGV[5]? || "0").to_i # which matrix row to promote to field names

BRIGHT = 150 # dark theme: backgrounds top out at 103, glyphs start at 167

STDOUT.sync = true # the probe is killed while blocked in the event loop; unflushed output is lost

def payload : String
  long = "a" * TLEN
  cell = MULTI ? "\"#{long}\nb\nc\"" : long
  row1 = Array.new(COLS) { |i| i == 0 && PLAIN1 > 0 ? "a" * PLAIN1 : cell }.join("\t")
  row2 = Array.new(COLS) { "a" }.join("\t")
  "#{row1}\n#{row2}\n#{row2}"
end

class CompositeProbe < EmbraceApp
  @paste_scheduled = false
  @measured = false
  @round = 0

  def build : CrymbleUI::Widget
    if !@paste_scheduled && (sched = CrymbleUI::Widget.scheduler?)
      @paste_scheduled = true
      sched.schedule(Time::Span.new(nanoseconds: 3000_i64 * 1_000_000)) do
        CrymbleUI::Widget.clipboard.text = payload
        paste_clipboard_as_new_table
        @shapes.shift if @shapes.size > 1
        request_rebuild
        # HEADER mode: promote row 1 (which holds the long values) to field names, so the
        # sticky HEADER band carries a too-long label. The fix changes the first draw of
        # EVERY layer, not just the matrix content layer, and a truncated field name has
        # no edit-mode workaround — so the header band has to be measured, not assumed.
        if HEADER
          sched.schedule(Time::Span.new(nanoseconds: 900_i64 * 1_000_000)) do
            if (r = self.root) && (m = find_matrix(r)) && (ad = m.adapter)
              ad.cell_transform_to_name({HROW, 0}) if ad.responds_to?(:cell_transform_to_name)
              request_rebuild
            end
          end
        end
        sched.schedule(Time::Span.new(nanoseconds: 2500_i64 * 1_000_000)) { measure }
      end
    end
    super
  end

  private def find_matrix(w : CrymbleUI::Widget) : CrymbleUI::VirtualMatrix?
    return w.as(CrymbleUI::VirtualMatrix) if w.is_a?(CrymbleUI::VirtualMatrix)
    w.children.each { |c| if m = find_matrix(c)
      return m
    end }
    nil
  end

  private def lum(c) : Int32
    (c.r.to_i * 299 + c.g.to_i * 587 + c.b.to_i * 114) // 1000
  end

  private def near?(c, r : Int32, g : Int32, b : Int32) : Bool
    (c.r.to_i - r).abs <= 4 && (c.g.to_i - g).abs <= 4 && (c.b.to_i - b).abs <= 4
  end

  private def measure
    return if @measured
    @measured = true
    root = self.root
    renderer = CrymbleUI.renderer
    unless root && renderer
      puts "MEASURE: missing root/renderer"
      return
    end
    all = CrymbleUI::Layer.active_layers(root).sort_by(&.z_index)
    grid = all.find { |l| l.id.starts_with?("matrix_content_") }
    sticky_col = all.find { |l| l.id.starts_with?("sticky_col_") }
    sticky_row = all.find { |l| l.id.starts_with?("sticky_row_") }
    unless grid && sticky_col && sticky_row
      puts "INSTRUMENT: INVALID -- matrix content / sticky layers not found"
      return
    end

    # Data columns begin where the sticky rank column ends, data rows where the
    # sticky header row ends. Read off the live layers; nothing hardcoded.
    ax0 = (sticky_col.bounds.x + sticky_col.bounds.width).to_i
    ax1 = Math.min(1199, (grid.bounds.x + grid.bounds.width).to_i)
    if HEADER
      ay0 = sticky_row.bounds.y.to_i
      ay1 = (sticky_row.bounds.y + sticky_row.bounds.height).to_i - 1
    else
      ay0 = (sticky_row.bounds.y + sticky_row.bounds.height).to_i
      ay1 = ay0 + 19
    end

    img = renderer.capture_composited_frame(self)

    # Modal colour over a rectangle — the cell fill and the panel fill are each the
    # dominant colour of their own region, whereas "brightest sub-glyph pixel" picks
    # up glyph anti-aliasing (it sampled 133,133,133 and made the edge unmeasurable).
    modal = ->(x_lo : Int32, x_hi : Int32) do
      tally = Hash(Tuple(Int32, Int32, Int32), Int32).new(0)
      (ay0..ay1).each do |y|
        (x_lo..x_hi).each do |x|
          next if x < 0 || x >= img.size.x.to_i
          p = img.get_pixel(x, y)
          tally[{p.r.to_i, p.g.to_i, p.b.to_i}] += 1
        end
      end
      tally.max_by { |_, n| n }[0]
    end

    f = modal.call(ax0, ax0 + 40)      # inside the first data cell
    panel = modal.call(ax1 - 100, ax1) # empty panel space at the far right
    if f == panel
      puts "INSTRUMENT: INVALID -- cell fill and panel fill sampled identical #{f}"
      return
    end

    # The column's right edge MUST be read off a glyph-free scanline. Anti-aliased
    # glyph pixels land within tolerance of the cell fill colour, so "any row in the
    # band" tracked the ink instead of the cell and reported overshoot 0 on a case the
    # pixel map plainly shows spilling.
    ink_rows = Set(Int32).new
    (ay0..ay1).each do |y|
      (ax0..ax1).each do |x|
        if lum(img.get_pixel(x, y)) > BRIGHT
          ink_rows << y
          break
        end
      end
    end
    clean_rows = (ay0..ay1).reject { |y| ink_rows.includes?(y) }
    if clean_rows.empty?
      puts "INSTRUMENT: INVALID -- every row in the band has glyphs; no clean row to read the cell edge from"
      return
    end

    fill_right = -1
    ink_right = -1
    ink_n = 0
    segments = [] of Tuple(Int32, Int32)
    (ax0..ax1).each do |x|
      has_ink = false
      clean_rows.each do |y|
        fill_right = x if near?(img.get_pixel(x, y), f[0], f[1], f[2])
      end
      (ay0..ay1).each do |y|
        if lum(img.get_pixel(x, y)) > BRIGHT
          has_ink = true
          ink_n += 1
        end
      end
      next unless has_ink
      ink_right = x
      # Merge into the previous segment across the inter-glyph gaps (<= 6px).
      if (last = segments.last?) && x - last[1] <= 6
        segments[-1] = {last[0], x}
      else
        segments << {x, x}
      end
    end

    puts "CONFIG cols=#{COLS} len=#{TLEN} multi=#{MULTI} header=#{HEADER} " \
         "cell_fill=#{f} panel=#{panel} band_y=#{ay0}..#{ay1}"
    if ink_n == 0 || fill_right < 0
      puts "  INSTRUMENT: INVALID -- ink_n=#{ink_n} fill_right=#{fill_right}"
    else
      puts "  last_cell_fill_right=#{fill_right}  ink_right=#{ink_right}  " \
           "OVERSHOOT=#{ink_right - fill_right}  ink_px=#{ink_n}"
      puts "  ink segments: " + segments.map { |a, b| "#{a}..#{b}" }.join(" ")
      # ASCII map of the band around the last column's edge. A single scanline is not
      # enough: the mid-row read as "glyphs on panel background past the cell", which
      # the aggregate contradicts, so show every row.
      mx0 = Math.max(ax0, fill_right - 60)
      mx1 = Math.min(ax1, fill_right + 30)
      puts "  MAP x=#{mx0}..#{mx1}  ('#'=glyph  'F'=cell fill  '.'=panel  '?'=other)"
      (ay0..ay1).each do |y|
        line = String.build do |s|
          (mx0..mx1).each do |x|
            p = img.get_pixel(x, y)
            s << (lum(p) > BRIGHT ? '#' : near?(p, f[0], f[1], f[2]) ? 'F' : near?(p, panel[0], panel[1], panel[2]) ? '.' : '?')
          end
        end
        puts "   y=#{y} #{line}"
      end
    end
    STDOUT.flush
    # Round 2: paste again to force a SECOND cell-render frame. Whether the first
    # cell loses the scissor test again decides if the reset is once-per-texture or
    # once-per-render — and that decides what shape the fix has to take.
    @round += 1
    if @round == 1
      @measured = false
      if sched = CrymbleUI::Widget.scheduler?
        sched.schedule(Time::Span.new(nanoseconds: 500_i64 * 1_000_000)) do
          CrymbleUI::Widget.clipboard.text = payload
          paste_clipboard_as_new_table
          @shapes.shift if @shapes.size > 1
          request_rebuild
          sched.schedule(Time::Span.new(nanoseconds: 2500_i64 * 1_000_000)) { measure }
        end
      end
      return
    end
    exit 0
  end
end

CrymbleUI.run(CompositeProbe.new)
