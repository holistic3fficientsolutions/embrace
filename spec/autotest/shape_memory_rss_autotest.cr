require "../spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"

# THE TESTER'S SCENARIO, MECHANISED — the real embrace app, a real window, real GPU textures.
#
# Reported 2026-07-26: an empty project with 16 shapes reaches ~1.0 GB; CLOSING all of them reaches
# ~1.6 GB (closing ALLOCATES); "New file (empty)" frees nothing. This runs exactly that sequence
# repeatedly and reports whether memory RETURNS.
#
# Why this cannot be a headless spec: the thing that leaks is a driver-side RenderTexture behind a
# ~100-byte Crystal wrapper. Headless replaces it with an ordinary Crystal array that the collector
# reclaims by itself, so the defect is INVISIBLE there — which is precisely how several
# headless-derived "fixes" measured as no-ops during this arc.
#
# THE ORACLE IS THE COUNTER, NOT RSS. RSS is printed as corroboration only: on some drivers texture
# memory is not resident in the process at all (measured on this box: destroying 0 vs 210 textures
# per cycle produced byte-identical RSS), so a resident-pages band is unfalsifiable. Created minus
# destroyed is exact everywhere. The verdict is ORDINAL — the stranded count must not GROW from
# cycle to cycle — so it needs no absolute numbers and no per-machine calibration.
#
# Run: source setup.sh
#      crystal build --release spec/autotest/shape_memory_rss_autotest.cr -o /tmp/shape_memory_rss
#      DISPLAY=:0 timeout 300 /tmp/shape_memory_rss ; echo "exit=$?"

include Persistency

PAGE_SIZE = 4096_i64

class SF::RenderTexture
  @@probe_created = 0
  @@probe_destroyed = 0

  def self.probe_created
    @@probe_created
  end

  def self.probe_destroyed
    @@probe_destroyed
  end

  # Texture bytes actually held. RSS cannot answer "how much do 16 shapes cost" on a driver that
  # does not account texture memory as resident, but the allocations themselves are exact: SFML
  # allocates width*height*4 (RGBA8) per RenderTexture, so summing over the live set is the real
  # figure. Tracked as a running total so peak and floor are both readable.
  @@probe_live_bytes = 0_i64
  @@probe_sizes = {} of UInt64 => Int64

  def self.probe_live_mb : Float64
    @@probe_live_bytes / 1_048_576.0
  end

  def initialize(width : Int, height : Int, settings : SF::ContextSettings? = nil)
    previous_def
    @@probe_created += 1
    bytes = width.to_i64 * height.to_i64 * 4
    @@probe_sizes[object_id] = bytes
    @@probe_live_bytes += bytes
  end

  def destroy! : Nil
    unless destroyed?
      @@probe_destroyed += 1
      @@probe_sizes.delete(object_id).try { |b| @@probe_live_bytes -= b }
    end
    previous_def
  end
end

def rss_mb : Float64
  (File.read("/proc/self/statm").split[1].to_i64 * PAGE_SIZE) / 1_048_576.0
end

LOG = "/tmp/shape_memory_rss.log"
File.write(LOG, "")

def log(msg : String)
  File.open(LOG, "a") { |f| f.puts msg }
  puts msg
end

# The real app with a real table, exactly as spec/gui/layer_registry_hygiene_spec.cr builds it.
app = EmbraceApp.new
persistency = app.persistency
hash = Hash(String, FieldLID | TableLID | RecordLID).new
help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
rows = (1..20).map { |i| "a#{i} | b#{i} | c#{i}" }.join("\n")
help << "T\nA | B | C\n#{rows}"
t_lid = hash["T"].as(TableLID)

class Driver
  SHAPES = 16
  CYCLES = 3

  @step = 0
  @floors = [] of Float64
  @survivors = [] of Int32
  @baseline = 0.0
  getter? failed = false

  def initialize(@app : EmbraceApp, @persistency : Persistency::Default, @t_lid : TableLID)
  end

  private def open_shapes
    SHAPES.times do
      @app.shapes << ShapeState.new("T", @persistency, @persistency.context.clone, @t_lid)
    end
    @app.request_rebuild
  end

  # The tester closes every shape and then picks "New file (empty)" — both end up as an empty
  # shape list plus a rebuild, which is what makes his "closing ALLOCATES" observation so sharp:
  # the rebuild legitimately re-creates surfaces for whatever survives, so the question is never
  # "did it allocate" but "did the discarded set come back".
  private def close_all_and_new_file
    @app.shapes.each(&.close)
    @app.shapes.clear
    @app.request_rebuild
  end

  def step : Bool
    case @step
    when 0
      @baseline = rss_mb
      log("baseline (empty)    : %8.1f MB" % @baseline)
    when 1, 4, 7
      open_shapes
    when 2, 5, 8
      log("   peak (%2d shapes) : %8.1f MB RSS | %8.1f MB of live GPU textures (created %d / destroyed %d)" % [
        SHAPES, rss_mb, SF::RenderTexture.probe_live_mb,
        SF::RenderTexture.probe_created, SF::RenderTexture.probe_destroyed])
      close_all_and_new_file
    when 3, 6, 9
      f = rss_mb
      @floors << f
      @survivors << (SF::RenderTexture.probe_created - SF::RenderTexture.probe_destroyed)
      log("after close + new %d : %8.1f MB RSS | %8.1f MB of live GPU textures (stranded: %d)" % [
        @floors.size, f, SF::RenderTexture.probe_live_mb, @survivors.last])
    else
      report
      return false
    end
    @step += 1
    true
  end

  private def report
    log("")
    log("floors    = #{@floors.map(&.round(1))}")
    log("survivors = #{@survivors}")
    log("textures: #{SF::RenderTexture.probe_created} created, #{SF::RenderTexture.probe_destroyed} destroyed")

    growth = @survivors.size >= 2 ? (@survivors[-1] - @survivors[0]) : 0
    if growth > 0
      per_cycle = (growth / (@survivors.size - 1)).round
      log("VERDICT: FAIL — #{growth} more textures stranded after cycle #{@survivors.size} than " \
          "after cycle 1 (#{per_cycle} per open/close/new-file cycle). This is the tester's report.")
      @failed = true
    else
      log("VERDICT: PASS — the stranded-texture count does not grow across #{@survivors.size} " \
          "open/close/new-file cycles. Memory returns.")
    end
    log("(RSS climb #{"%+.1f" % (@floors.size >= 2 ? @floors[-1] - @floors[0] : 0.0)} MB — " \
        "corroboration only; this driver may not account texture memory as resident.)")
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

# Driven from the scheduler so every state change is separated by actually-rendered frames —
# sampling between them is what makes "did it come back" a fair question.
CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 800_000_000)) do
  tick = uninitialized Proc(Nil)
  tick = -> do
    if driver.step
      CrymbleUI::Widget.scheduler.schedule(Time::Span.new(nanoseconds: 500_000_000)) { tick.call }
    else
      exit(driver.failed? ? 1 : 0)
    end
    nil
  end
  tick.call
end

renderer.run(app)
