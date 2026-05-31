{% if flag?(:cache_validation) %}

require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Headless cache-validation specs. Compile+run with:
#   crystal spec -Dcache_validation spec/gui/cache_validation_spec.cr
#
# With -Dcache_validation, every render runs TWO pipelines (cached vs
# immediate-mode) and records any pixel disagreement into /tmp/cv_diff_*.ppm
# + /tmp/cv_diag_*.log. Each scenario wraps its action in `with_cv_check` so
# any mismatch raises.

private def with_cv_check(&)
    CrymbleUI::CacheValidation.enable_all
    CrymbleUI::CacheValidation.clear_failures!
    yield
    CrymbleUI::CacheValidation.assert_no_failures!
end

# Demo-populated EmbraceApp with Allocations selected as the primary Shape's table.
# Mirrors do_newfile_demo's data verbatim (the minimum subset needed to exercise
# filter/commit/drill/diff flows realistically).
private def make_demo_app : {EmbraceApp, Hash(String, FieldLID | TableLID | RecordLID)}
    app = EmbraceApp.new
    persistency = app.persistency
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Projects
        Project
        Arts
        Autonomy
        Curiosity
        Healing
        Justice
        Law
        Loyality
        Peace
        Suppression
        Survival

        Times
        Time
        Former
        Future
        Present

        Persons
        Person
        Alan
        Amanita
        Denny
        Helen
        Jared
        Jezelia
        Kaden
        Max
        Melanie
        Rafferty
        Riley
        Samwise
        Sauron
        Wanda
        Will

        Allocations
        Person_Person | Time_Time | Project_Project | Allocation
        Alan | Present | Law | 100
        Denny | Present | Law | 100
        Sauron | Former | Suppression | 100
        Samwise | Former | Peace | 100
        Wanda | Future | Peace | 100
        Melanie | Future | Survival | 100
        Jared | Future | Survival | 100
        Jezelia | Future | Autonomy | 100
        Rafferty | Future | Curiosity | 100
        Kaden | Future | Loyality | 100
        Max | Present | Healing | 100
        Helen | Present | Healing | 100
        Will | Present | Justice | 100
        Riley | Present | Arts | 100
        Amanita | Present | Arts | 100
    EOT
    alloc_lid = hash["Allocations"].as(TableLID)
    app.shapes.clear
    ctx = persistency.context.clone
    app.shapes << ShapeState.new("Allocations", persistency, ctx, alloc_lid)
    app.request_rebuild
    {app, hash}
end

describe "Cache validation — embrace scenarios" do
    # Reproduce the user's small Shape window from the screenshot. With the
    # hardcoded 1100×750 the matrix fits 14 rows without scrolling, and the
    # user-reported blank-rank bug never triggers. Shrinking the Shape panel
    # forces the same 1-row overflow condition from /tmp/2026-04-22_06-51.png.
    around_all do |example|
        ENV["EMBRACE_SHAPE_PANEL_WIDTH"] = "680"
        ENV["EMBRACE_SHAPE_PANEL_HEIGHT"] = "550"
        example.run
        ENV.delete("EMBRACE_SHAPE_PANEL_WIDTH")
        ENV.delete("EMBRACE_SHAPE_PANEL_HEIGHT")
    end

    # S0: baseline — a clean render must be pixel-identical in cached and
    # immediate-mode. If this fails, everything downstream is suspect.
    it "S0 baseline: demo loaded, pristine render is pixel-identical" do
        app, _hash = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        with_cv_check do
            renderer.settle_rendering(app)
        end
    end

    # S1: reproduces the user-reported Amanita bug — typing in the Projects
    # filter and deselecting one value reshapes the matrix; the last row's
    # Rank cell goes blank.
    it "S1 filter deselect + scroll: Projects∖{Curiosity} leaves no stale cells" do
        app, _hash = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)

        shape = app.shapes.first
        project_col = shape.column_names.index("Project") || shape.column_names.index("Project_Project")
        project_col.should_not be_nil

        distinct = shape.column_distinct_values(project_col.not_nil!)
        all_values = distinct.map(&.[0]).to_set
        shape.filter_add(project_col.not_nil!, all_values)
        app.request_rebuild
        renderer.settle_rendering(app)

        with_cv_check do
            # Mirror the user's exact sequence: type "c" in the search, then
            # deselect Curiosity, then wheel-scroll Perspective DOWN.
            app.commit_filter_search({shape.id, project_col.not_nil!}, "c")
            app.request_rebuild
            renderer.settle_rendering(app)

            curiosity = all_values.find do |v|
                v.is_a?(ReferenceCell) ? v.value.to_s.includes?("Curiosity") : v.to_s.includes?("Curiosity")
            end
            curiosity.should_not be_nil
            remaining = all_values.reject { |v| v == curiosity }.to_set
            shape.filter_set_values(project_col.not_nil!, remaining)
            app.request_rebuild
            renderer.settle_rendering(app)

            # Scroll the matrix down — this is the trigger that reveals the
            # stale-rank-cell bug when records have compacted from filter.
            vm = shape.matrix_adapter.not_nil!.virtual_matrix.not_nil!
            pt = CrymbleUI::Vec2.new(
                vm.absolute_bounds.x + vm.absolute_bounds.width / 2,
                vm.absolute_bounds.y + vm.absolute_bounds.height / 2,
            )
            3.times do
                vm.on_mouse_wheel(CrymbleUI::Vec2.new(0.0, -1.0), pt)
                app.request_rebuild
                renderer.settle_rendering(app)
            end
        end
    end

    # S2: simply adding a filter (with everything selected by default) must
    # not produce any cache divergence.
    it "S2 filter add: adding a Projects filter (no-op selection) stays clean" do
        app, _hash = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)

        shape = app.shapes.first
        project_col = shape.column_names.index("Project_Project") || shape.column_names.index("Project")
        next if project_col.nil?
        all_values = shape.column_distinct_values(project_col).map(&.[0]).to_set

        with_cv_check do
            shape.filter_add(project_col, all_values)
            app.request_rebuild
            renderer.settle_rendering(app)
        end
    end

    # S3: search-string narrows the checkbox flow — no matrix cells should move.
    it "S3 filter search: narrowing the value picker stays clean" do
        app, _hash = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        project_col = shape.column_names.index("Project_Project") || shape.column_names.index("Project")
        next if project_col.nil?
        shape.filter_add(project_col, shape.column_distinct_values(project_col).map(&.[0]).to_set)
        app.request_rebuild
        renderer.settle_rendering(app)

        with_cv_check do
            app.commit_filter_search({shape.id, project_col}, "c")
            app.request_rebuild
            renderer.settle_rendering(app)
        end
    end

    # S4: commit reshapes the History section (the changes list collapses).
    it "S4 commit: Commit! cleanly rerenders the History section" do
        app, _hash = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        with_cv_check do
            shape.do_commit
            app.request_rebuild
            renderer.settle_rendering(app)
        end
    end

    # TODO(test): S5 drill scenario — needs a pivot configured to produce a Drilldown cell;
    # skipped until that setup exists, then assert no cache-validation failure.
    pending "S5 drill: spawn drilled shape cleanly"

    # S6: spawn diff-Shape after an edit; changed cells get highlighted.
    it "S6 diff-Shape: Show changes composites cleanly" do
        app, hash = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        # Force an edit so there IS something to diff.
        persistency = app.persistency
        alloc_lid = hash["Allocations"].as(TableLID)
        persistency.contexts.push(shape.context)
        allocation_field = hash["Allocation"].as(FieldLID)
        records = persistency.get_record_lids(alloc_lid)
        persistency.set_value(allocation_field, records.first, 999i64)
        persistency.contexts.pop
        app.request_rebuild
        renderer.settle_rendering(app)

        with_cv_check do
            diff = shape.spawn_diff_shape.not_nil!
            app.shapes << diff
            app.request_rebuild
            renderer.settle_rendering(app)
        end
    end

    # S7: history navigation back + forward.
    it "S7 history navigate: back then forward cleanly" do
        app, _hash = make_demo_app
        renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
        renderer.settle_rendering(app)
        shape = app.shapes.first
        # Seed a commit so there IS a back-step to take.
        shape.do_commit
        app.request_rebuild
        renderer.settle_rendering(app)

        with_cv_check do
            shape.navigate_history(-1)
            app.request_rebuild
            renderer.settle_rendering(app)
            shape.navigate_history(+1)
            app.request_rebuild
            renderer.settle_rendering(app)
        end
    end

    # S8: scroll past one buffer boundary — exercises blit_shift level.
    pending "S8 scroll past buffer boundary"
end

{% else %}

# When the flag isn't set, this spec is a no-op. Print a hint and skip.
describe "Cache validation — embrace scenarios" do
    it "skipped without -Dcache_validation" do
        puts "  (compile with -Dcache_validation to enable)"
    end
end

{% end %}
