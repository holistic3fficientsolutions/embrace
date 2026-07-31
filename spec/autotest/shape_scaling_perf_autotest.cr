require "../spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"

# HOW DOES EMBRACE SCALE WITH THE NUMBER OF OPEN SHAPES? — the real app, a real window, real GPU.
#
# User report 2026-07-27: "performance is usually good, but with 10+ Shapes open it is really
# getting slow. Is this merely the linear slowdown, or is there more?"
#
# That question is only answerable by measuring the SLOPE, so this walks a ladder of shape counts
# and reports, for each rung, the median cost of the two frame kinds that matter:
#
#   REBUILD frame  — a menu action / dialog / tree-expand: the whole widget tree is reconstructed
#                    but NO data changed, so each Shape's version gate stays shut and the matrices
#                    keep their buffers. Five buckets: build (widget-tree reconstruction + every
#                    ShapeState#update — this runs in the run loop OUTSIDE render_frame and is
#                    therefore invisible to the [PERF] line), then layout/render/composite/display.
#   EDIT frame     — a real cell commit through the production path (adapter#cell_assign →
#                    on_data_changed → request_rebuild). Persistency's version moves, so EVERY
#                    open Shape's gate fires and every matrix invalidates. The worst case, and the
#                    one the user feels while entering data.
#   COMPOSITE-only — what merely HAVING N panels costs on a frame where nothing changed. Every
#                    collected layer is blitted to the window unconditionally (layer_renderer.cr
#                    composite loop; no occlusion culling), so this is the pure fill-rate floor.
#
# The verdict is the PER-SHAPE cost across the ladder. Flat per-shape ⇒ linear (N shapes cost N×).
# Rising per-shape ⇒ superlinear, and the bucket that rises names the mechanism.
#
# Instrumented by patching, not by editing the library: LayerRenderer.reset_frame_counters is the
# one place that runs exactly once per rendered frame AFTER every counter is final (render_frame
# zeroes them there), so the sample is taken in front of it. App#rebuild is timed separately
# because it runs before render_frame and lands in no bucket.
#
# Run: source setup.sh
#      crystal build --release spec/autotest/shape_scaling_perf_autotest.cr -o /tmp/shape_scaling
#      DISPLAY=:0 timeout 600 /tmp/shape_scaling
#      DISPLAY=:0 SCALING_NO_GC=1 /tmp/shape_scaling      # the collector's share of the slope
#      DISPLAY=:0 CRYMBLE_PERF=1 /tmp/shape_scaling       # adds a per-layer [LAYER] ms breakdown
# MUST be --release on a QUIET box: a concurrent spec run inflated N>=12 by 2-3x and moved the
# composite bucket 6-fold, which reads exactly like a GPU cliff and is not one.
#
# BASELINE 2026-07-27 (this box, Mesa Intel, 20-row table, default 1100x750 panels in 1200x900):
#   shapes    1     4     8    10    16          per shape: 3.8 -> 11.2 -> 13.4 -> 13.6 -> 15.7 ms
#   rebuild 3.8  44.7 107.2 135.7 251.4 ms       layers +9 / widgets +82 / GPU +29 MB per shape
#   With SCALING_NO_GC=1 the per-shape cost is FLAT at 11.6 ms from 4 to 10 shapes (13.8 at 16), so
#   the slope is ~linear and the residual rise is the collector working against a heap that grows
#   per shape (each shape allocates 2.75 MB per rebuild frame).
#   ATTRIBUTION: render ~75% of the frame, layout ~13%, tree reconstruction ~17%, composite <1%.
#   Per shape per rebuild: matrix_content 5.9 ms + sticky_col 2.4 + panel chrome 2.0 + cursor 0.6.
#   THE FINDING: on a rebuild that changes NO data the adapter's invalidate_all! fires ZERO times,
#   yet 8 of every shape's 9 layers still fully re-render. embrace never asks for it — a
#   viewport_cache layer's staleness key (content_rev) sums PER-INSTANCE widget counters that
#   copy_state_from does not carry, so it can never match across a rebuild.

include Persistency

PAGE_SIZE = 4096_i64

def rss_mb : Float64
  (File.read("/proc/self/statm").split[1].to_i64 * PAGE_SIZE) / 1_048_576.0
end

# --- GPU texture accounting (same probe as shape_memory_rss_autotest) -------------------------
class SF::RenderTexture
  @@probe_live_bytes = 0_i64
  @@probe_sizes = {} of UInt64 => Int64
  @@probe_live_count = 0

  def self.probe_live_mb : Float64
    @@probe_live_bytes / 1_048_576.0
  end

  def self.probe_live_count
    @@probe_live_count
  end

  def initialize(width : Int, height : Int, settings : SF::ContextSettings? = nil)
    previous_def
    bytes = width.to_i64 * height.to_i64 * 4
    @@probe_sizes[object_id] = bytes
    @@probe_live_bytes += bytes
    @@probe_live_count += 1
  end

  def destroy! : Nil
    unless destroyed?
      @@probe_sizes.delete(object_id).try { |b| @@probe_live_bytes -= b }
      @@probe_live_count -= 1
    end
    previous_def
  end
end

# NOTE on the "build" bucket: App#rebuild runs in the run loop BEFORE render_frame, so it lands in
# none of the four phase counters. It is not timed by patching App#rebuild — `previous_def` re-emits
# the original body in the patch's lexical scope, and that body's bare `Widget` reference then fails
# to resolve. It is derived instead as wall-minus-buckets ("other"), which is exactly the tree
# reconstruction plus every ShapeState#update plus ~1 ms of loop/timer overhead.

# --- how much of the rebuild is the DATA pipeline (pivot/commit walk) vs the widget tree -------
class ShapeState
  @@probe_update_ms = 0.0

  def self.probe_update_ms
    @@probe_update_ms
  end

  def self.probe_update_reset
    @@probe_update_ms = 0.0
  end

  def update(force_update = false) : Nil
    t = Time.instant
    previous_def
    @@probe_update_ms += (Time.instant - t).total_milliseconds
  end
end

# Expose the REAL demo dataset (File > New demo) rather than hand-cloning its heredoc — core's own
# T-079 sweep flags drifted fixture clones as a defect, and the whole point of a demo-scale run is to
# measure what the user actually sees. protect_unsaved_changes yields straight through at startup
# (@last_save_version == @persistency.version), so no dialog intervenes.
class EmbraceApp
  def probe_build_demo
    do_newfile_demo
  end

  # do_newfile_demo ends with set_statusbar_info, which schedules a countdown timer — and the
  # scheduler only exists once the renderer is running, so the fixture build would die on
  # "Scheduler not initialized". Neutralised for the whole probe run; the statusbar has no bearing
  # on what is being measured.
  protected def set_statusbar_info(text : String)
  end

  protected def set_statusbar_warning(text : String)
  end
end

# --- who tells the matrices to re-render? -----------------------------------------------------
# If a data-unchanged rebuild still re-renders every matrix_content layer WITHOUT this counter
# moving, the push came from crymble-ui's reconcile, not from embrace's version gate.
module Probe
  class_property invalidations = 0
  # EXCLUSIVE per-stage time. The stages nest — Pivot#update reads its parent, which triggers
  # VirtualTable#update, which calls complex_query — so each hook subtracts whatever nested hooks
  # consumed inside it. Without that, one edit's cost would be counted three times over.
  class_property nested_ms = 0.0
  class_property vt_ms = 0.0
  class_property vt_calls = 0
  class_property query_ms = 0.0
  class_property query_calls = 0
  class_property query_rows = 0
  class_property pivot_ms = 0.0
  class_property pivot_calls = 0
  class_property version_ms = 0.0
  class_property version_calls = 0
  class_property refs_ms = 0.0
  class_property refs_calls = 0
  class_property rework_ms = 0.0
  class_property rework_calls = 0
  class_property hier_ms = 0.0
  class_property hier_calls = 0
  # CUMULATIVE across the whole run (never reset): which source line issues each complex_query, so
  # "8 calls per shape per rebuild" gets an owner instead of a guess. Independent of the VT hooks —
  # if sites inside virtualtable.cr appear here, VirtualTable#update demonstrably RAN, and a zero
  # from the VT hook is the hook's fault rather than the method's.
  class_property query_sites = Hash(String, Tuple(Int32, Float64)).new

  def self.note_site(site : String, ms : Float64)
    n, t = @@query_sites[site]? || {0, 0.0}
    @@query_sites[site] = {n + 1, t + ms}
  end

  def self.reset_stages
    @@vt_ms = @@query_ms = @@pivot_ms = @@nested_ms = 0.0
    @@version_ms = @@refs_ms = @@rework_ms = @@hier_ms = 0.0
    @@vt_calls = @@query_calls = @@query_rows = @@pivot_calls = 0
    @@version_calls = @@refs_calls = @@rework_calls = @@hier_calls = 0
  end
end

# Timing wrapper with EXCLUSIVE attribution: subtract whatever nested hooks consumed inside.
macro timed_stage(ms_prop, calls_prop)
  outer = Probe.nested_ms
  Probe.nested_ms = 0.0
  t = Time.instant
  result = previous_def
  elapsed = (Time.instant - t).total_milliseconds
  Probe.{{ms_prop.id}} = Probe.{{ms_prop.id}} + elapsed - Probe.nested_ms
  Probe.{{calls_prop.id}} = Probe.{{calls_prop.id}} + 1
  Probe.nested_ms = outer + elapsed
  result
end

# The three stages the 20-row baseline could not see. All are LAZY — pulled by the first data
# access — so a timer on ShapeState#update (the gate) misses every one of them.
class VirtualTable(T, U)
  # `update` is PRIVATE and reported 0 calls in the previous run, which is arithmetically impossible
  # (Hierarchic#update reads @parent.version, and version calls update). Hooking the PUBLIC `version`
  # alongside it is the discriminator: version fires + update doesn't ⇒ the private override is the
  # problem; NEITHER fires ⇒ this reopen isn't reaching the type the Shapes actually use.
  def version : Int32
    timed_stage(version_ms, version_calls)
  end

  private def update
    timed_stage(vt_ms, vt_calls)
  end

  # The two stages the 1730 ms was attributed to by subtraction. Measured directly now.
  private def update_references
    timed_stage(refs_ms, refs_calls)
  end

  private def update_rework_table
    timed_stage(rework_ms, rework_calls)
  end
end

class Table::Lazy::Pivot::Hierarchic(T, U, V)
  private def update
    timed_stage(hier_ms, hier_calls)
  end
end

class Table::Lazy::Pivot::Simple(T, U)
  private def update
    timed_stage(pivot_ms, pivot_calls)
  end
end

module Persistency::Generic::Basics(T)
  # The signature must match persistency.cr:897 EXACTLY. An untyped `query` param does not override
  # it — Crystal treats it as a second, less-specific OVERLOAD, so every real call still goes to the
  # original and the probe reads a silent, plausible-looking zero. (Measured: 0 calls on both
  # fixtures, when the TablePicker alone guarantees one per shape per rebuild.)
  def complex_query(query : {table_lids: Array(TableLID), field_lids: Array(Array(FieldLID)), table_joins: Array({Int32, Int32}), where_not_nil_columns: Array(Int32)}, where_not_nil_anding : Bool) : Array(Array(T))
    outer = Probe.nested_ms
    Probe.nested_ms = 0.0
    t = Time.instant
    res = previous_def
    elapsed = (Time.instant - t).total_milliseconds
    Probe.query_ms += elapsed - Probe.nested_ms
    Probe.query_calls += 1
    Probe.query_rows += res.size
    Probe.nested_ms = outer + elapsed
    # Name the caller. The first frame outside this probe file is the issuing site.
    site = caller.find { |f| !f.includes?("shape_scaling_perf_autotest") } || "unknown"
    Probe.note_site(site.split(" in ").first.sub(/^.*\/(?=[a-z_]+\.cr)/, ""), elapsed)
    res
  end
end

class SimpleMatrixAdapter(T, U, V)
  # `super`, not previous_def: invalidate_all! comes from crymble-ui's MatrixAdapter module, so
  # this is an override of an ancestor's method, not a redefinition in the same type.
  def invalidate_all!
    Probe.invalidations += 1
    super
  end
end

# --- one sample per rendered frame, taken before the counters are zeroed ----------------------
record FrameSample,
  wall : Float64,
  build : Float64,
  layout : Float64,
  render : Float64,
  composite : Float64,
  display : Float64,
  shape_update : Float64,
  widgets : Int32,
  layers : Int32,
  layers_rendered : Int32,
  invalidations : Int32,
  alloc_mb : Float64,
  vt_ms : Float64,
  vt_calls : Int32,
  query_ms : Float64,
  query_calls : Int32,
  query_rows : Int32,
  pivot_ms : Float64,
  pivot_calls : Int32,
  version_ms : Float64,
  version_calls : Int32,
  refs_ms : Float64,
  refs_calls : Int32,
  rework_ms : Float64,
  rework_calls : Int32,
  hier_ms : Float64,
  hier_calls : Int32

module CrymbleUI
  module LayerRenderer
    class_property probe_sampler : Proc(Nil)? = nil

    def self.reset_frame_counters
      LayerRenderer.probe_sampler.try &.call
      previous_def
    end
  end
end

LOG = "/tmp/shape_scaling.log"
File.write(LOG, "")

def log(msg : String)
  File.open(LOG, "a") { |f| f.puts msg }
  puts msg
  STDOUT.flush
end

def median(xs : Array(Float64)) : Float64
  return 0.0 if xs.empty?
  s = xs.sort
  s[s.size // 2]
end

# --- the dataset ------------------------------------------------------------------------------
# SCALING_ROWS   row count of the table the Shapes open on (default 20 = the committed baseline)
# SCALING_LINKED 1 = demo-shaped multi-table structure with REFERENCE columns, Shapes opened on the
#                fact table. A single flat table gives complex_query no join work to do, so the
#                unlinked fixture under-measures the very stage this run exists to size.
# SCALING_SHAPES comma list overriding the shape ladder (keeps runtime sane at large row counts)
# SCALING_FILE   load a real .embrace file instead of generating (Shapes open on its first table)
ROWS = (ENV["SCALING_ROWS"]? || "20").to_i

app = EmbraceApp.new
t_lid = uninitialized TableLID

if ENV["SCALING_DEMO"]? == "1"
  app.probe_build_demo
  persistency = app.persistency
  tables = persistency.get_table(MetaFieldLIDs::TableLastTable) # [lid, _, name]
  alloc = tables.find { |r| r[2].to_s == "Allocations" }
  t_lid = (alloc || tables.first)[0].as(TableLID)
  log("REAL demo dataset (File > New demo): #{tables.size} tables, Shapes on " \
      "#{(alloc || tables.first)[2]} (3 reference columns)")
elsif file = ENV["SCALING_FILE"]?
  raise "SCALING_FILE: could not load #{file}" unless app.load_document(file)
  persistency = app.persistency
  tables = persistency.get_table(MetaFieldLIDs::TableLastTable) # same idiom as the TablePicker
  raise "SCALING_FILE: #{file} has no tables" if tables.empty?
  t_lid = tables.first[0].as(TableLID)
  log("loaded #{file}: #{tables.size} tables, opening Shapes on the first")
else
  persistency = app.persistency
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  if ENV["SCALING_LINKED"]? == "1"
    # Demo-shaped: Cities/Times/Projects are dimensions, Persons references Cities, and the fact
    # table Allocations references three tables — so the join is 4-wide, as in a real model.
    cities = (1..(Math.max(4, ROWS // 50))).map { |i| "City#{i} | Country#{i % 7}" }.join("\n")
    projects = (1..(Math.max(4, ROWS // 100))).map { |i| "Project#{i}" }.join("\n")
    persons = (1..(Math.max(4, ROWS // 10))).map { |i| "Person#{i} | City#{(i % Math.max(4, ROWS // 50)) + 1}" }.join("\n")
    allocs = (1..ROWS).map do |i|
      "Person#{(i % Math.max(4, ROWS // 10)) + 1} | Time#{(i % 3) + 1} | " \
      "Project#{(i % Math.max(4, ROWS // 100)) + 1} | #{i % 100}"
    end.join("\n")
    help << "Cities\nCity | Country\n#{cities}"
    help << "Times\nTime\nTime1\nTime2\nTime3"
    help << "Projects\nProject\n#{projects}"
    help << "Persons\nPerson | City_City\n#{persons}"
    help << "Allocations\nPerson_Person | Time_Time | Project_Project | Allocation\n#{allocs}"
    t_lid = hash["Allocations"].as(TableLID)
    log("linked fixture: #{ROWS} allocations over #{Math.max(4, ROWS // 10)} persons / " \
        "#{Math.max(4, ROWS // 50)} cities / #{Math.max(4, ROWS // 100)} projects")
  else
    rows = (1..ROWS).map { |i| "a#{i} | b#{i} | c#{i}" }.join("\n")
    help << "T\nA | B | C\n#{rows}"
    t_lid = hash["T"].as(TableLID)
    log("flat fixture: #{ROWS} rows x 3 columns (NO joins — complex_query has nothing to join)")
  end
end

record Rung,
  n : Int32,
  rebuild : Array(FrameSample),
  edit : Array(FrameSample),
  composite : Array(FrameSample),
  tex_mb : Float64,
  tex_count : Int32,
  heap_mb : Float64,
  rss : Float64

class Driver
  LADDER  = (ENV["SCALING_SHAPES"]? || "1,2,4,6,8,10,12,16").split(",").map(&.to_i)
  WARM    = 4  # discarded frames after a shape-count change (caches settle, first-render pays once)
  MEASURE = 12

  @rung = 0
  @kind = :warm_rebuild
  @count = 0
  @rebuild_samples = [] of FrameSample
  @edit_samples = [] of FrameSample
  @composite_samples = [] of FrameSample
  @rungs = [] of Rung
  @last_frame_at : Time::Instant
  @last_total_bytes = 0_i64
  @edit_cell : {Int32, Int32}? = nil
  @edit_toggle = false
  @edit_failed = false
  # SCALING_NO_GC=1 disables the collector for the measured windows. If the per-shape cost flattens,
  # the superlinear term is GC (heap grows with shapes, allocation rate grows with shapes).
  @no_gc : Bool = ENV["SCALING_NO_GC"]? == "1"
  @gc_disabled : Bool = false

  def initialize(@app : EmbraceApp, @persistency : Persistency::Default, @t_lid : TableLID)
    @last_frame_at = Time.instant
    @last_total_bytes = GC.stats.total_bytes.to_i64
  end

  private def target_n : Int32
    LADDER[@rung]
  end

  # Every rung holds exactly n shapes on the fixture's table. Any Shape the app made for itself is
  # dropped in `start` first: the start-up one is built against an empty new-file (no table, no
  # matrix), and counting it as a shape made the N=1 rung ~7x cheaper and faked a superlinear curve.
  private def grow_to(n : Int32)
    while @app.shapes.size < n
      @app.shapes << ShapeState.new("T", @persistency, @persistency.context.clone, @t_lid)
    end
  end

  # One directly-assignable data cell in the first Shape's matrix. Located once; the same cell is
  # rewritten on every edit frame, which is exactly what re-typing a value does.
  private def edit_cell : {Int32, Int32}?
    return @edit_cell if @edit_cell
    shape = @app.shapes.first?
    return nil unless shape
    rc = shape.matrix_userdata_rc
    adapter = shape.matrix_adapter
    return nil unless rc && adapter
    rows, cols = adapter.size
    # BOUNDED: on a large fixture the grid is huge and every probe pulls a cell through the whole
    # lazy stack, so an unbounded scan would itself cost more than the frames being measured.
    (0...Math.min(rows, 60)).each do |r|
      (0...Math.min(cols, 60)).each do |c|
        next if adapter.cell_get_header_info({r, c})
        if rc.get_assignability([r, c]) == Table::Lazy::Pivot::Assignability::Directly
          return @edit_cell = {r, c}
        end
      end
    end
    nil
  end

  # The production edit path: the adapter commits, bumps persistency's version and fires
  # on_data_changed → request_rebuild. Returns false if no cell could be edited.
  private def do_edit : Bool
    cell = edit_cell
    return false unless cell
    shape = @app.shapes.first?
    return false unless shape
    adapter = shape.matrix_adapter
    return false unless adapter
    before = @persistency.version
    @edit_toggle = !@edit_toggle
    adapter.cell_assign(cell[0], cell[1], @edit_toggle ? "e1" : "e2")
    @app.request_rebuild # production also gets here via on_data_changed; idempotent
    @persistency.version != before
  end

  # Called once per rendered frame, with every counter still valid.
  def on_frame : Nil
    now = Time.instant
    wall = (now - @last_frame_at).total_milliseconds
    @last_frame_at = now

    layout = CrymbleUI::LayerRenderer.phase_layout_ms
    render = CrymbleUI::LayerRenderer.phase_render_ms
    composite = CrymbleUI::LayerRenderer.phase_composite_ms
    display = CrymbleUI::LayerRenderer.phase_display_ms

    total_bytes = GC.stats.total_bytes.to_i64
    sample = FrameSample.new(
      wall: wall,
      build: wall - (layout + render + composite + display), # tree reconstruction + shape updates
      layout: layout,
      render: render,
      composite: composite,
      display: display,
      shape_update: ShapeState.probe_update_ms,
      widgets: CrymbleUI::LayerRenderer.frame_widget_count,
      layers: CrymbleUI::LayerRenderer.frame_layers_total,
      layers_rendered: CrymbleUI::LayerRenderer.frame_layers_needing_render,
      invalidations: Probe.invalidations,
      alloc_mb: (total_bytes - @last_total_bytes) / 1_048_576.0,
      vt_ms: Probe.vt_ms,
      vt_calls: Probe.vt_calls,
      query_ms: Probe.query_ms,
      query_calls: Probe.query_calls,
      query_rows: Probe.query_rows,
      pivot_ms: Probe.pivot_ms,
      pivot_calls: Probe.pivot_calls,
      version_ms: Probe.version_ms,
      version_calls: Probe.version_calls,
      refs_ms: Probe.refs_ms,
      refs_calls: Probe.refs_calls,
      rework_ms: Probe.rework_ms,
      rework_calls: Probe.rework_calls,
      hier_ms: Probe.hier_ms,
      hier_calls: Probe.hier_calls,
    )
    @last_total_bytes = total_bytes
    ShapeState.probe_update_reset
    Probe.invalidations = 0
    Probe.reset_stages

    advance(sample)
  end

  private def advance(sample : FrameSample) : Nil
    case @kind
    when :warm_rebuild
      @count += 1
      if @count > WARM
        @kind = :measure_rebuild
        @count = 0
        collector_off
      end
      @app.request_rebuild
    when :measure_rebuild
      @rebuild_samples << sample
      @count += 1
      if @count >= MEASURE
        @kind = :warm_edit
        @count = 0
        collector_on
      end
      @app.request_rebuild
    when :warm_edit
      @count += 1
      if @count > WARM
        @kind = :measure_edit
        @count = 0
        collector_off
      end
      unless do_edit
        @edit_failed = true
        @app.request_rebuild # never stall the ladder on an unavailable edit cell
      end
    when :measure_edit
      @edit_samples << sample
      @count += 1
      if @count >= MEASURE
        @kind = :warm_composite
        @count = 0
        collector_on
        @app.request_rebuild
      else
        unless do_edit
        @edit_failed = true
        @app.request_rebuild # never stall the ladder on an unavailable edit cell
      end
      end
    when :warm_composite
      @count += 1
      if @count > WARM
        @kind = :measure_composite
        @count = 0
      end
      @app.request_composite
    when :measure_composite
      # A composite-only frame must not have rendered any layer; if one did, the app was still
      # settling and the sample is not a pure fill-rate reading.
      @composite_samples << sample if sample.layers_rendered == 0
      @count += 1
      if @count >= MEASURE
        finish_rung
      else
        @app.request_composite
      end
    end
  end

  # GC.enable raises unless the collector is actually disabled, so the paired state is tracked
  # explicitly — finish_rung and the end of a measured window both reach here.
  private def collector_off : Nil
    return if !@no_gc || @gc_disabled
    GC.disable
    @gc_disabled = true
  end

  private def collector_on : Nil
    return unless @gc_disabled
    GC.enable
    @gc_disabled = false
    GC.collect
  end

  private def finish_rung : Nil
    collector_on
    GC.collect
    stats = GC.stats
    @rungs << Rung.new(
      n: target_n,
      rebuild: @rebuild_samples.dup,
      edit: @edit_samples.dup,
      composite: @composite_samples.dup,
      tex_mb: SF::RenderTexture.probe_live_mb,
      tex_count: SF::RenderTexture.probe_live_count,
      heap_mb: (stats.heap_size - stats.free_bytes) / 1_048_576.0,
      rss: rss_mb,
    )
    report_rung(@rungs.last)
    @rebuild_samples.clear
    @edit_samples.clear
    @composite_samples.clear
    @rung += 1
    if @rung >= LADDER.size
      report_summary
      exit(0)
    end
    grow_to(target_n)
    @kind = :warm_rebuild
    @count = 0
    @app.request_rebuild
  end

  def start : Nil
    @app.shapes.clear # drop whatever the app opened for itself; the ladder owns the shape list
    grow_to(target_n)
    @kind = :warm_rebuild
    @count = 0
    @app.request_rebuild
  end

  private def bucket_line(label : String, s : Array(FrameSample)) : String
    return "   %-14s: (no sample)" % label if s.empty?
    "   %-14s: wall %6.1f ms | other %6.1f (shape.update %5.1f) layout %5.1f render %6.1f composite %4.1f display %4.1f" % [
      label, median(s.map(&.wall)), median(s.map(&.build)), median(s.map(&.shape_update)),
      median(s.map(&.layout)), median(s.map(&.render)), median(s.map(&.composite)),
      median(s.map(&.display))]
  end

  private def report_rung(r : Rung) : Nil
    reb = r.rebuild
    log("N=%2d shapes" % r.n)
    log(bucket_line("rebuild frame", r.rebuild))
    log(bucket_line("edit frame", r.edit))
    if r.composite.empty?
      log("   composite-only: (no clean sample — layers kept re-rendering)")
    else
      log("   composite-only: wall %6.1f ms | composite %4.1f display %4.1f" % [
        median(r.composite.map(&.wall)), median(r.composite.map(&.composite)),
        median(r.composite.map(&.display))])
    end
    log("   volumes       : widgets %5d | layers %3d (rendered %3d) | GPU tex %7.1f MB in %4d | heap %6.1f MB | RSS %7.1f MB" % [
      reb.empty? ? 0 : reb.map(&.widgets).sort[reb.size // 2], reb.empty? ? 0 : reb.map(&.layers).sort[reb.size // 2],
      reb.empty? ? 0 : reb.map(&.layers_rendered).sort[reb.size // 2],
      r.tex_mb, r.tex_count, r.heap_mb, r.rss])
    log("   per frame     : allocated %6.1f MB on a rebuild / %6.1f MB on an edit | adapter invalidate_all! %d rebuild / %d edit" % [
      median(reb.map(&.alloc_mb)), median(r.edit.map(&.alloc_mb)),
      reb.empty? ? 0 : reb.map(&.invalidations).sort[reb.size // 2],
      r.edit.empty? ? 0 : r.edit.map(&.invalidations).sort[r.edit.size // 2]])
    # THE DATA STAGES the 20-row baseline could not see. Exclusive ms, so they are additive and
    # directly comparable with the render/layout buckets above.
    log("   DATA stages   : rebuild  query %6.1f ms (%3d calls, %6d rows) | VT-rework %6.1f (%4d) | pivot-cluster %6.1f (%5d)" % [
      median(reb.map(&.query_ms)), reb.empty? ? 0 : reb.map(&.query_calls).sort[reb.size // 2],
      reb.empty? ? 0 : reb.map(&.query_rows).sort[reb.size // 2],
      median(reb.map(&.vt_ms)), reb.empty? ? 0 : reb.map(&.vt_calls).sort[reb.size // 2],
      median(reb.map(&.pivot_ms)),
      reb.empty? ? 0 : reb.map(&.pivot_calls).sort[reb.size // 2]])
    log("                 : edit     query %6.1f ms (%3d calls, %6d rows) | VT-rework %6.1f (%4d) | pivot-cluster %6.1f (%5d)" % [
      median(r.edit.map(&.query_ms)), r.edit.empty? ? 0 : r.edit.map(&.query_calls).sort[r.edit.size // 2],
      r.edit.empty? ? 0 : r.edit.map(&.query_rows).sort[r.edit.size // 2],
      median(r.edit.map(&.vt_ms)), r.edit.empty? ? 0 : r.edit.map(&.vt_calls).sort[r.edit.size // 2],
      median(r.edit.map(&.pivot_ms)),
      r.edit.empty? ? 0 : r.edit.map(&.pivot_calls).sort[r.edit.size // 2]])
    log("   VT SPLIT (the VirtualTable hooks DO NOT BIND — these four read 0 regardless; see the")
    log("                   reopen comment. Hierarchic binds and is real.)")
    log("                 : rebuild  version %6.1f (%5d) | update %6.1f (%5d) | update_references %7.1f (%3d) | update_rework_table %7.1f (%3d) | Hierarchic %6.1f (%5d)" % [
      median(reb.map(&.version_ms)), reb.empty? ? 0 : reb.map(&.version_calls).sort[reb.size // 2],
      median(reb.map(&.vt_ms)), reb.empty? ? 0 : reb.map(&.vt_calls).sort[reb.size // 2],
      median(reb.map(&.refs_ms)), reb.empty? ? 0 : reb.map(&.refs_calls).sort[reb.size // 2],
      median(reb.map(&.rework_ms)), reb.empty? ? 0 : reb.map(&.rework_calls).sort[reb.size // 2],
      median(reb.map(&.hier_ms)), reb.empty? ? 0 : reb.map(&.hier_calls).sort[reb.size // 2]])
    log("")
  end

  private def report_summary : Nil
    log("=" * 108)
    log("SCALING (GC #{@no_gc ? "DISABLED during the measured windows" : "on"}) — per-shape cost is the")
    log("verdict. Flat ⇒ linear. Rising ⇒ superlinear.")
    log("")
    log("(ms = work per frame, i.e. wall MINUS display — `display` is the 60 Hz vsync wait, which caps")
    log(" wall at 16.7 ms until the work itself exceeds it and would mask every small reading.)")
    log("")
    log("  N | rebuild ms | /shape | edit ms | /shape | composite ms | /shape | widgets | layers | GPU MB | heap MB")
    log(" ---+------------+--------+---------+--------+--------------+--------+---------+--------+--------+--------")
    @rungs.each do |r|
      w = median(r.rebuild.map(&.wall)) - median(r.rebuild.map(&.display))
      e = median(r.edit.map(&.wall)) - median(r.edit.map(&.display))
      c = median(r.composite.map(&.wall)) - median(r.composite.map(&.display))
      log(" %2d | %10.1f | %6.2f | %7.1f | %6.2f | %12.1f | %6.2f | %7d | %6d | %6.1f | %7.1f" % [
        r.n, w, w / r.n, e, e / r.n, c, c / r.n,
        r.rebuild.empty? ? 0 : r.rebuild.map(&.widgets).sort[r.rebuild.size // 2],
        r.rebuild.empty? ? 0 : r.rebuild.map(&.layers).sort[r.rebuild.size // 2],
        r.tex_mb, r.heap_mb])
    end
    log("")
    log("complex_query CALL SITES (cumulative over the whole run):")
    Probe.query_sites.to_a.sort_by { |_, v| -v[1] }.each do |site, v|
      log("   %6d calls  %9.1f ms total   %s" % [v[0], v[1], site])
    end
    log("")
    log("(edit measurement UNAVAILABLE — no directly-assignable cell was found)") if @edit_failed
    first = @rungs.first
    last = @rungs.last
    {"rebuild" => {first.rebuild, last.rebuild}, "edit" => {first.edit, last.edit},
     "composite" => {first.composite, last.composite}}.each do |name, pair|
      f, l = pair
      next if f.empty? || l.empty?
      fw = (median(f.map(&.wall)) - median(f.map(&.display))) / first.n
      lw = (median(l.map(&.wall)) - median(l.map(&.display))) / last.n
      log("per-shape %-9s cost: %6.2f ms at N=%d → %6.2f ms at N=%2d  (%+.0f%%)  %s" % [
        name, fw, first.n, lw, last.n, fw > 0 ? (lw / fw - 1) * 100 : 0.0,
        lw > fw * 1.35 ? "SUPERLINEAR" : (lw < fw * 0.75 ? "sublinear" : "linear")])
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

driver = Driver.new(app, persistency, t_lid)
CrymbleUI::LayerRenderer.probe_sampler = ->{ driver.on_frame }

# A repeating timer keeps the run loop off its blocking wait_event path, so composite-only
# requests (which are only honoured when a timer fired) are actually serviced.
CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 1_000_000), repeating: true) { }

CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 700_000_000)) do
  driver.start
end

renderer.run(app)
