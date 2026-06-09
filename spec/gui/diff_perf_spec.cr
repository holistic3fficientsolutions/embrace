require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# T-007: count get_value CALLS to make the diff-Shape construction budgets
# DETERMINISTIC (machine-load-independent) instead of absolute wall-clock.
# Reopened HERE in the spec only — production persistency.cr is byte-for-byte
# untouched; the counter exists solely in the test binary. (A clean
# Layer01(Cell) subclass can't compile: Layer01's Generic modules re-declare
# `abstract def get_value`, so a subclass `super` resolves into the abstract.)
# Counting CALLS above the cache is the algorithmic read count — a redundant
# walk bumps it regardless of caching. probe_reads is shared across every
# persistency instance in the test binary, so reset it right before each
# measured op (see reads_for).
class Persistency::Backend::Cacher(T)
  property probe_reads : Int32 = 0
  def get_value(field_lid : FieldLID, record_lid : RecordLID) : T
    @probe_reads += 1
    previous_def
  end
end

# Performance specs for "Show changes" / diff-Shape feature.
#
# User report: spawning a diff-Shape burns ~1s at 100% CPU before anything
# shows up, while DUPLICATING a shape on the exact same data is fast. The
# difference is the right thing to measure:
#
#   - `dup_shape` (src/gui/shape.cr:781) uses the CLONE constructor at line
#     756, which reuses the parent's Configurator and Fieldlist (cheap).
#   - `spawn_diff_shape` (src/gui/shape.cr:804) uses the REGULAR constructor
#     `ShapeState.new(title, persistency, ctx, table_lid)` which rebuilds
#     the Configurator from scratch + runs `fieldlist_normalize!` +
#     `apply_diff_record_filter!`. That's the hot path.
#
# All assertions below are DETERMINISTIC or COMPARATIVE — never absolute
# wall-clock (machine-load-dependent, flaky in headless). Two kinds:
#   - CONSTRUCTION budgets (det 1/2): deterministic get_value read-COUNT ratios
#     (5 vs 500 records) — catch a record-walk creeping into the O(1) dup path
#     and a quadratic re-walk in spawn_diff_shape, independent of machine speed.
#   - RENDER/scaling budgets (perf1/5/6/7): comparative TIME ratios (diff vs
#     dup, or 500 vs 5) — load-robust by cancellation (same load hits both).
# Read-count guards "the diff walk/build stays ~linear in R", NOT wall-clock;
# a non-read quadratic (set-ops/alloc) or a render regression is backstopped
# only by the timing ratios. See memory/feedback_perf_measurement.

# Parent Shape with 5 Sales rows + 2 pending edits, fully initialized
# (Configurator run, fieldlist built) so dup vs diff comparison is fair.
private def make_parent_shape : {ShapeState, TableLID}
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10
        south | widget | 20
        north | gadget | 30
        south | gadget | 40
        north | widget | 50
    EOT
    persistency.close_and_add_commit
    persistency.close_and_add_commit  # open commit for pending edits
    table_lid = hash["Sales"].as(TableLID)
    amount_field = hash["Amount"].as(FieldLID)
    product_field = hash["Product"].as(FieldLID)
    amounts = persistency.get_field(amount_field)
    rec_10 = amounts.find { |_, v| v == 10i64 }.not_nil![0]
    rec_30 = amounts.find { |_, v| v == 30i64 }.not_nil![0]
    persistency.set_value(amount_field, rec_10, 999i64)
    persistency.set_value(product_field, rec_30, "gizmo")
    context = persistency.context.clone
    parent = ShapeState.new("Sales", persistency, context, table_lid)
    {parent, table_lid}
end

# Large parent (500 rows, 2 edited cells) for the scaling assertion.
private def make_large_parent_shape(record_count : Int32 = 500) : {ShapeState, TableLID}
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    header = "Sales\nRegion | Product | Amount"
    rows = String.build(record_count * 24) do |b|
        record_count.times do |i|
            b << "\n" << (i.even? ? "north" : "south")
            b << " | " << (i % 3 == 0 ? "widget" : (i % 3 == 1 ? "gadget" : "gizmo"))
            b << " | " << (10 + i).to_s
        end
    end
    help << (header + rows)
    persistency.close_and_add_commit
    persistency.close_and_add_commit
    table_lid = hash["Sales"].as(TableLID)
    amount_field = hash["Amount"].as(FieldLID)
    amounts = persistency.get_field(amount_field)
    first_rec = amounts.first[0]
    last_rec = amounts.to_a.last[0]
    persistency.set_value(amount_field, first_rec, 9999i64)
    persistency.set_value(amount_field, last_rec, 8888i64)
    context = persistency.context.clone
    parent = ShapeState.new("Sales", persistency, context, table_lid)
    {parent, table_lid}
end

private def measure_ms(&) : Float64
    t0 = Time.instant
    yield
    (Time.instant - t0).total_milliseconds
end

# Median of 3 runs for a single-call operation. Reduces jitter from GC,
# first-use allocation, and kernel scheduling. `setup` yields a fresh
# parent for each run (since spawn/dup mutates state).
private def median_ms_3(setup : -> ShapeState, &op : ShapeState -> _) : Float64
    samples = [] of Float64
    3.times do
        parent = setup.call
        # Warmup call — does not count. Uses a different measurement target
        # (a trivial closure over the parent) so `op` itself is not warmed.
        _ = parent.spawn_diff_shape
        fresh = setup.call
        samples << measure_ms { op.call(fresh) }
    end
    samples.sort!
    samples[1]
end

# get_value reads incurred by `op` on a freshly-built parent. Deterministic —
# one run suffices (no median/warmup). Resets the shared counter right before
# the op so build/meta reads from earlier don't leak in. dup_shape and
# spawn_diff_shape both reuse the parent's persistency instance, so their reads
# land on the same counter.
private def reads_for(parent : ShapeState, &op : ShapeState -> _) : Int32
    pers = parent.persistency
    pers.probe_reads = 0
    op.call(parent)
    pers.probe_reads
end

describe "diff-Shape performance — failing baseline vs dup_shape" do
    # (det 1) dup_shape is the fast reference: the clone constructor REUSES the
    # parent's Configurator and never walks persistency per record, so its
    # get_value count is O(1) — flat from 5 to 500 records. Deterministic
    # replacement for the old "dup < 50ms" anchor: if a record-walk crept into
    # the fast path, reads would jump ~R-fold (≈130×), not stay flat.
    it "(det 1) dup_shape read-count is flat in record count (O(1) fast path)" do
        reads_small = reads_for(make_parent_shape[0]) { |p| p.dup_shape("copy") }
        reads_big = reads_for(make_large_parent_shape(500)[0]) { |p| p.dup_shape("copy") }
        ratio = reads_big.to_f / {reads_small, 1}.max
        puts "    [det 1] dup reads: 5-rec=#{reads_small} / 500-rec=#{reads_big} / ratio=#{ratio.round(1)}×"
        ratio.should be <= 2.0,
            "dup_shape reads scaled #{ratio.round(1)}× from 5→500 records (#{reads_small}→#{reads_big}); the clone fast path must stay O(1) — a record-walk crept in"
    end

    # 2. spawn_diff_shape on the same data should be comparable to
    # dup_shape. The original quadratic implementation ran ~100× slower
    # than dup; the current fix stays within ~10× on sub-ms measurements
    # (dup is 0.4ms so 4ms diff = 10×, well inside the regression guard).
    it "(perf 1) spawn_diff_shape is no more than 15× dup_shape on demo" do
        setup = -> { make_parent_shape[0] }
        t_dup = median_ms_3(setup) { |p| p.dup_shape("copy") }
        t_diff = median_ms_3(setup) { |p| p.spawn_diff_shape }
        ratio = t_diff / {t_dup, 0.01}.max
        puts "    [perf 1] dup = #{t_dup.round(2)}ms / diff = #{t_diff.round(2)}ms / ratio = #{ratio.round(1)}×"
        ratio.should be < 15.0,
            "spawn_diff_shape took #{t_diff.round(2)}ms vs dup_shape #{t_dup.round(2)}ms — #{ratio.round(1)}× slower (budget: 15×)"
    end

    # (det 2) spawn_diff_shape stays ~linear (O(R·F)) in record count, NOT
    # quadratic. This is the deterministic guard for the historical regression:
    # the original diff walk was ~100× slower than dup — a redundant read-walk.
    # By get_value count, linear is ≈23× for 100× the records; a re-introduced
    # quadratic walk (inner record loop) would be ≈5900×. Budget 50× sits well
    # inside that gap, replacing the old absolute 200ms/500ms wall-clock budgets.
    it "(det 2) spawn_diff_shape read-count scales near-linearly 5→500 records (no quadratic walk)" do
        reads_small = reads_for(make_parent_shape[0]) { |p| p.spawn_diff_shape }
        reads_big = reads_for(make_large_parent_shape(500)[0]) { |p| p.spawn_diff_shape }
        ratio = reads_big.to_f / {reads_small, 1}.max
        puts "    [det 2] spawn_diff reads: 5-rec=#{reads_small} / 500-rec=#{reads_big} / ratio=#{ratio.round(1)}×"
        ratio.should be < 50.0,
            "spawn_diff_shape reads scaled #{ratio.round(1)}× from 5→500 records (#{reads_small}→#{reads_big}); linear is ~23×, a quadratic re-walk would be ~5900× (budget: 50×)"
    end

    # 6. Scaling ratio: 500-record diff should not be catastrophic.
    # Linear O(R) would be ~100× for 100× the data; quadratic would be
    # ~10 000×. Budget 200× catches the quadratic regression while
    # tolerating Configurator's one-time O(R·F) cost at spawn.
    it "(perf 5) spawn_diff_shape scales near-linearly from 5 to 500 records (≤ 200×)" do
        small = median_ms_3(-> { make_parent_shape[0] }) { |p| p.spawn_diff_shape }
        big = median_ms_3(-> { make_large_parent_shape(500)[0] }) { |p| p.spawn_diff_shape }
        ratio = big / {small, 0.01}.max
        puts "    [perf 5] small(5) = #{small.round(2)}ms / big(500) = #{big.round(2)}ms / ratio = #{ratio.round(1)}×"
        ratio.should be < 200.0,
            "scaling 5→500 records inflates spawn_diff_shape by #{ratio.round(1)}× (budget: 200×; linear-with-build-overhead ~50-80× is expected, quadratic would be >1000×)"
    end

    # 6d. Inspect matrix shape: how many cells does dup produce vs diff?
    # If diff has MORE cells, that alone explains slower render (and matches
    # user's observation even if my render-frame timings match).
    it "(perf 6d) matrix size: dup vs diff" do
        parent, _ = make_parent_shape
        dup = parent.dup_shape("copy")
        diff = parent.spawn_diff_shape.not_nil!

        dup_rc = dup.matrix_userdata_rc
        diff_rc = diff.matrix_userdata_rc
        dup_size = dup_rc ? dup_rc.size : [0, 0]
        diff_size = diff_rc ? diff_rc.size : [0, 0]
        dup_cells = dup_size[0] * dup_size[1]
        diff_cells = diff_size[0] * diff_size[1]
        puts "    [perf 6d] dup matrix = #{dup_size.inspect} (#{dup_cells} cells)"
        puts "    [perf 6d] diff matrix = #{diff_size.inspect} (#{diff_cells} cells)"
        puts "    [perf 6d] parent filter_state.size dup=#{dup.filter_state.size} diff=#{diff.filter_state.size}"
    end

    # 6c. Count the number of render frames each path needs to fully settle.
    # If diff settles in more frames than dup, the user's "1s 100% CPU"
    # could be multiple frames of work that the single-frame test misses.
    it "(perf 6c) settle frame count: +dup vs +diff" do
        ["dup", "diff"].each do |mode|
            parent, _ = make_parent_shape
            app = EmbraceApp.new
            app.shapes.clear
            app.shapes << parent
            renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
            renderer.settle_rendering(app)  # initial settle

            new_shape = (mode == "dup") ? parent.dup_shape("copy") : parent.spawn_diff_shape.not_nil!
            app.shapes << new_shape
            app.request_rebuild

            # Count frames until primitive_count stabilizes. Emulates settle_rendering.
            frames = 0
            total_time = 0.0
            prev_primitives = -1
            20.times do
                t = measure_ms { renderer.render_frame(app) }
                total_time += t
                cur = renderer.primitive_count
                if cur == prev_primitives
                    break
                end
                prev_primitives = cur
                frames += 1
            end
            puts "    [perf 6c/#{mode}] settled after #{frames} frames, total=#{total_time.round(1)}ms"
        end
    end

    # 6b. Isolate pure rebuild cost: call request_rebuild WITHOUT adding a
    # shape, then render_frame. This measures rebuild + reconciliation of
    # the existing tree — no new shape. Subtract from dup/diff delta to
    # get the actual NEW-SHAPE construction cost.
    it "(perf 6b) decompose: pure rebuild / +dup / +diff" do
        # --- Baseline: render twice, no rebuild ---
        parent_a, _ = make_parent_shape
        app_a = EmbraceApp.new
        app_a.shapes.clear
        app_a.shapes << parent_a
        r_a = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_a.render_frame(app_a)
        t_steady = measure_ms { r_a.render_frame(app_a) }

        # --- Rebuild cost, no new shape added ---
        parent_b, _ = make_parent_shape
        app_b = EmbraceApp.new
        app_b.shapes.clear
        app_b.shapes << parent_b
        r_b = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_b.render_frame(app_b)
        app_b.request_rebuild
        t_rebuild_only = measure_ms { r_b.render_frame(app_b) }

        # --- +dup ---
        parent_c, _ = make_parent_shape
        app_c = EmbraceApp.new
        app_c.shapes.clear
        app_c.shapes << parent_c
        r_c = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_c.render_frame(app_c)
        t_dup_spawn = measure_ms { parent_c.dup_shape("copy") }
        app_c.shapes << parent_c.dup_shape("copy2")
        app_c.request_rebuild
        t_dup_first_frame = measure_ms { r_c.render_frame(app_c) }

        # --- +diff ---
        parent_d, _ = make_parent_shape
        app_d = EmbraceApp.new
        app_d.shapes.clear
        app_d.shapes << parent_d
        r_d = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_d.render_frame(app_d)
        t_diff_spawn = measure_ms { parent_d.spawn_diff_shape.not_nil! }
        app_d.shapes << parent_d.spawn_diff_shape.not_nil!
        app_d.request_rebuild
        t_diff_first_frame = measure_ms { r_d.render_frame(app_d) }

        # Decompose each first-frame delta: rebuild-only vs new-shape-incremental.
        dup_delta = t_dup_first_frame - t_rebuild_only
        diff_delta = t_diff_first_frame - t_rebuild_only
        puts "    [perf 6b] steady=#{t_steady.round(1)}ms  rebuild_only=#{t_rebuild_only.round(1)}ms"
        puts "    [perf 6b] spawn_dup=#{t_dup_spawn.round(2)}ms  first_frame_+dup=#{t_dup_first_frame.round(1)}ms  (Δ_new_shape=#{dup_delta.round(1)}ms)"
        puts "    [perf 6b] spawn_diff=#{t_diff_spawn.round(2)}ms  first_frame_+diff=#{t_diff_first_frame.round(1)}ms  (Δ_new_shape=#{diff_delta.round(1)}ms)"
        # Diagnostic only — don't fail; the prints are the output we want.
    end

    # 7. FIRST-FRAME rendering cost: spawning adds a shape to app.shapes,
    # which triggers a rebuild + layout + render next frame. The user's
    # "~1 second of 100% CPU" happens in that first frame. Compare the
    # first-frame cost of adding a dup vs adding a diff. Uses render_frame
    # directly (one frame, no settle loop) so we measure a single pass.
    it "(perf 6) first-frame render cost of adding diff-Shape ≤ 3× adding dup-Shape" do
        # Baseline: parent alone, rendered once.
        parent_a, _ = make_parent_shape
        app_a = EmbraceApp.new
        app_a.shapes.clear
        app_a.shapes << parent_a
        r_a = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_a.render_frame(app_a)  # warmup initial tree build
        t_base_a = measure_ms { r_a.render_frame(app_a) }

        # Add a dup_shape and measure the first frame that sees it.
        parent_b, _ = make_parent_shape
        app_b = EmbraceApp.new
        app_b.shapes.clear
        app_b.shapes << parent_b
        r_b = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_b.render_frame(app_b)  # warmup
        dup = parent_b.dup_shape("copy")
        app_b.shapes << dup
        app_b.request_rebuild
        t_dup_first_frame = measure_ms { r_b.render_frame(app_b) }

        # Add a spawn_diff_shape and measure the first frame that sees it.
        parent_c, _ = make_parent_shape
        app_c = EmbraceApp.new
        app_c.shapes.clear
        app_c.shapes << parent_c
        r_c = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_c.render_frame(app_c)  # warmup
        diff = parent_c.spawn_diff_shape.not_nil!
        app_c.shapes << diff
        app_c.request_rebuild
        t_diff_first_frame = measure_ms { r_c.render_frame(app_c) }

        # Subtract baseline to isolate the added-shape cost.
        dup_delta = t_dup_first_frame - t_base_a
        diff_delta = t_diff_first_frame - t_base_a
        ratio = diff_delta / {dup_delta.abs, 0.1}.max
        puts "    [perf 6] base = #{t_base_a.round(2)}ms / +dup = #{t_dup_first_frame.round(2)}ms (Δ#{dup_delta.round(2)}) / +diff = #{t_diff_first_frame.round(2)}ms (Δ#{diff_delta.round(2)}) / ratio = #{ratio.round(1)}×"
        ratio.should be < 3.0,
            "first-frame cost of adding diff-Shape is #{ratio.round(1)}× adding a dup-Shape (+dup Δ#{dup_delta.round(2)}ms vs +diff Δ#{diff_delta.round(2)}ms); budget: 3×"
    end

    # 8. First-frame parity with dup: adding a diff-Shape should not be
    # materially slower than adding a dup. TestRenderer has ~1 s of
    # inherent overhead per first frame in headless — that hits dup and
    # diff equally. Budget: diff ≤ 1.5× dup. The quadratic original was
    # ~2× dup; today's fix should bring the ratio to ~1.0×.
    it "(perf 7) first-frame render +diff is within 1.5× +dup on demo" do
        parent_a, _ = make_parent_shape
        app_a = EmbraceApp.new
        app_a.shapes.clear
        app_a.shapes << parent_a
        r_a = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_a.render_frame(app_a)  # warmup
        dup = parent_a.dup_shape("copy")
        app_a.shapes << dup
        app_a.request_rebuild
        t_dup_first = measure_ms { r_a.render_frame(app_a) }

        parent_b, _ = make_parent_shape
        app_b = EmbraceApp.new
        app_b.shapes.clear
        app_b.shapes << parent_b
        r_b = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        r_b.render_frame(app_b)  # warmup
        diff = parent_b.spawn_diff_shape.not_nil!
        app_b.shapes << diff
        app_b.request_rebuild
        t_diff_first = measure_ms { r_b.render_frame(app_b) }

        ratio = t_diff_first / {t_dup_first, 1.0}.max
        puts "    [perf 7] +dup first-frame = #{t_dup_first.round(2)}ms / +diff first-frame = #{t_diff_first.round(2)}ms / ratio = #{ratio.round(2)}×"
        ratio.should be < 1.5,
            "first-frame render +diff (#{t_diff_first.round(2)}ms) is #{ratio.round(2)}× +dup (#{t_dup_first.round(2)}ms); budget: 1.5× — quadratic regression would be ~2×"
    end
end
