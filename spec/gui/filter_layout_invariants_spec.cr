require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Investigation spec for the user-reported bug: after filter toggles + Filter
# section collapse, the Perspective shows inconsistent per-column data
# (e.g. rank column 1-9 with blanks, while other columns show all 13).
#
# Strategy: drive ShapeState directly (no EmbraceApp needed), verify adapter
# data consistency under repeated filter changes + explicit update(true)
# calls that mimic the app-level relayout. If the adapter stays consistent
# here, the bug is purely at the VirtualMatrix widget-caching layer in
# crymble-ui, not in the filter data pipeline.

private def make_wide_setup : {Persistency::Default, TableLID}
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Data
        Name | Class | Tag | Amount
        Alan | Present | Law | 100
        Denny | Present | Law | 100
        Sauron | Former | Suppression | 100
        Samwise | Former | Peace | 100
        Wanda | Future | Peace | 100
        Melanie | Future | Survival | 100
        Jared | Future | Survival | 100
        Jezelia | Future | Autonomy | 100
        Rafferty | Future | Curiosity | 100
        Kaden | Future | Loyalty | 100
        Max | Present | Healing | 100
        Helen | Present | Healing | 100
        Will | Present | Justice | 100
    EOT
    {persistency, hash["Data"].as(TableLID)}
end

private def make_wide_shape : ShapeState
    persistency, table_lid = make_wide_setup
    ShapeState.new("Data", persistency, persistency.context.clone, table_lid)
end

private def column_samples(shape : ShapeState) : Hash(String, Array(String))
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.size[0], adapter.size[1]
    (0...cols).each_with_object(Hash(String, Array(String)).new) do |c, h|
        name = shape.column_names[c]? || "col_#{c}"
        h[name] = (0...rows).map { |r| adapter.cell_get_name(r, c) }
    end
end

describe "Filter+layout data invariants (adapter-level)" do
    it "Scenario A: repeated update(true) doesn't change row count or cell values" do
        shape = make_wide_shape
        before = shape.matrix_adapter.not_nil!.size.dup
        samples_before = column_samples(shape)

        # Simulate an app-level relayout trigger — update(true) forces a
        # fresh configurator run + setup_adapters
        shape.update(true)
        shape.update(true)

        after = shape.matrix_adapter.not_nil!.size
        after.should eq(before)
        samples = column_samples(shape)
        samples.each do |col, values|
            values.should eq(samples_before[col]),
                "column '#{col}' differs after repeated update(true)"
        end
    end

    it "Scenario B: filter toggling sequence — adapter rows reflect filter on every step" do
        shape = make_wide_shape
        unfiltered_rows = shape.matrix_adapter.not_nil!.size[0]
        unfiltered_rows.should be > 0

        class_col = shape.column_names.index("Class").not_nil!
        all_values = shape.column_distinct_values(class_col).map(&.[0]).to_set

        # Step 1: add filter with all values selected — row count unchanged
        shape.filter_add(class_col, all_values)
        shape.matrix_adapter.not_nil!.size[0].should eq(unfiltered_rows)

        # Step 2: drop one value — row count shrinks
        dropped = all_values.to_a.first
        shape.filter_set_values(class_col, all_values - Set{dropped})
        step2_rows = shape.matrix_adapter.not_nil!.size[0]
        step2_rows.should be < unfiltered_rows

        # Step 3: restore it — back to full count
        shape.filter_set_values(class_col, all_values)
        shape.matrix_adapter.not_nil!.size[0].should eq(unfiltered_rows)

        # Step 4: drop a different value — different count
        dropped2 = all_values.to_a.last
        shape.filter_set_values(class_col, all_values - Set{dropped2})
        step4_rows = shape.matrix_adapter.not_nil!.size[0]
        step4_rows.should be < unfiltered_rows
    end

    it "Scenario C: filter-change THEN app-level relayout — data stays consistent" do
        shape = make_wide_shape
        class_col = shape.column_names.index("Class").not_nil!
        all_values = shape.column_distinct_values(class_col).map(&.[0]).to_set

        shape.filter_add(class_col, all_values)
        # Uncheck one value
        dropped = all_values.to_a.first
        shape.filter_set_values(class_col, all_values - Set{dropped})

        samples_after_filter = column_samples(shape)
        size_after_filter = shape.matrix_adapter.not_nil!.size.dup

        # Simulate the "collapse Filter section" trigger — this doesn't change
        # the adapter directly; it's a pure widget-tree layout change. But the
        # app still calls shape.update at the top of each rebuild which runs
        # the version check. Call it to mimic that.
        shape.update(false)   # NOT forced — should be a no-op since version unchanged

        shape.matrix_adapter.not_nil!.size.should eq(size_after_filter),
            "matrix size changed after no-op update (filter data should be frozen)"
        column_samples(shape).should eq(samples_after_filter),
            "cell values changed after no-op update"
    end

    it "Scenario D: full cell scan never returns nil/empty for present rows" do
        shape = make_wide_shape
        class_col = shape.column_names.index("Class").not_nil!
        all_values = shape.column_distinct_values(class_col).map(&.[0]).to_set
        shape.filter_add(class_col, all_values)
        shape.filter_set_values(class_col, all_values - Set{all_values.to_a.first})

        adapter = shape.matrix_adapter.not_nil!
        rows, cols = adapter.size[0], adapter.size[1]
        rows.should be > 0

        # This is the key check: every cell in every visible row should return
        # a defined value. If ANY column returns nil/empty for a row where
        # other columns return data, that's the rank-column-blank bug at the
        # data level.
        (0...rows).each do |r|
            (0...cols).each do |c|
                val = adapter.cell_get_name(r, c)
                val.should_not be_nil, "row #{r} col #{c} returned nil"
            end
        end
    end

    it "Scenario E: rank column is dense (no blanks in-between) for the full filtered set" do
        # Reproduces user screenshot 2026-04-19_08-45.png:
        # Rank column shows 1-8, 10, 11, then blank for rows 11-14.
        # Other columns have data in every row. If this ever happens at the
        # adapter level, it's an embrace data bug (not a VM render bug).
        shape = make_wide_shape
        adapter = shape.matrix_adapter.not_nil!

        class_col = shape.column_names.index("Class").not_nil!
        all_values = shape.column_distinct_values(class_col).map(&.[0]).to_set

        # User's sequence: add filter (all values), uncheck one, then re-check it
        shape.filter_add(class_col, all_values)
        dropped = all_values.to_a.first
        shape.filter_set_values(class_col, all_values - Set{dropped})
        shape.filter_set_values(class_col, all_values)     # restore

        # Find the Rank column. In embrace's VirtualTable, Rank is a leading
        # PseudoField column — lookup by name (locale-insensitive).
        rank_col = shape.column_names.index { |n| n.downcase.includes?("rank") }
        rank_col.should_not be_nil
        rank_col = rank_col.not_nil!

        rows = adapter.size[0]
        rank_values = (0...rows).map { |r| adapter.cell_get_name(r, rank_col) }
        name_col = shape.column_names.index("Name").not_nil!
        name_values = (0...rows).map { |r| adapter.cell_get_name(r, name_col) }

        # Collect indices where Name is present but Rank is blank — those are
        # the user's "rank column blank while other column has data" rows.
        blank_rank = [] of Int32
        (0...rows).each do |r|
            if !name_values[r].empty? && rank_values[r].strip.empty?
                blank_rank << r
            end
        end
        blank_rank.empty?.should be_true,
            "rank blank at rows #{blank_rank.inspect} while Name has data; rank=#{rank_values.inspect} name=#{name_values.inspect}"
    end
end
