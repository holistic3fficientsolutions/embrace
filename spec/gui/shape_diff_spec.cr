require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Setup: 5 Sales rows committed, then 2 cells edited in a new open commit.
private def make_sales_with_pending_edits
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
    parent_commit = persistency.context.current_commit
    persistency.close_and_add_commit
    open_commit = persistency.context.current_commit
    table_lid = hash["Sales"].as(TableLID)
    amount_field = hash["Amount"].as(FieldLID)
    product_field = hash["Product"].as(FieldLID)
    amounts = persistency.get_field(amount_field)
    rec_10 = amounts.find { |_, v| v == 10i64 }.not_nil![0]
    rec_30 = amounts.find { |_, v| v == 30i64 }.not_nil![0]
    persistency.set_value(amount_field, rec_10, 999i64)
    persistency.set_value(product_field, rec_30, "gizmo")
    {persistency, table_lid, parent_commit, open_commit, amount_field, product_field, rec_10, rec_30}
end

describe "ShapeState#spawn_diff_shape" do
    # --- diff as overlay (NOT clamping), with row filter + highlight ---

    it "diff-Shape shows FULL cell values (unchanged cells not nil)" do
        persistency, table_lid, _parent, _open, amount_field, _pf, rec_10, rec_30 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        # Changed cell reflects the new value, as before.
        persistency.contexts.push(diff.context)
        persistency.get_value(amount_field, rec_10).should eq(999i64)
        # Unchanged-in-open cell (rec_30's Amount) should now be VISIBLE with its
        # original value — no more clamping.
        persistency.get_value(amount_field, rec_30).should eq(30i64)
        persistency.contexts.pop
    end

    it "diff-Shape defaults to show_changed_only=true and filters rows accordingly" do
        persistency, table_lid, _parent, _open, _af, _pf, rec_10, rec_30 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        diff.diff_show_changed_only.should be_true
        # Only 2 records were modified in the open commit (rec_10, rec_30)
        drilled_vt = diff.unfiltered_vt.not_nil!
        filtered = Table::Lazy::Filter.apply(drilled_vt, diff.filter_state)
        filtered.size[0].should eq(2)
    end

    it "toggling diff_show_changed_only = false reveals all records" do
        persistency, table_lid, _parent, _open, _af, _pf, _r1, _r2 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        diff.diff_show_changed_only = false
        drilled_vt = diff.unfiltered_vt.not_nil!
        filtered = Table::Lazy::Filter.apply(drilled_vt, diff.filter_state)
        filtered.size[0].should eq(5)  # all records, not only changed
    end

    it "diff_changed_cells contains the (row, col) of every changed data cell" do
        persistency, table_lid, _parent, _open, _af, _pf, _rec_10, _rec_30 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        changed = diff.diff_changed_cells.not_nil!
        # Two edits in the setup: rec_10.Amount and rec_30.Product. With the
        # default show_changed_only=true filter, only those two rows are visible
        # and each contributes exactly one changed cell → 2 entries total.
        changed.size.should eq(2),
            "expected 2 changed cells, got #{changed.size}: #{changed.inspect}"
    end

    it "diff_changed_cells ignores write-then-restore (value-differs semantic)" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Sales
            Region | Product | Amount
            north | widget | 10
            south | widget | 20
        EOT
        persistency.close_and_add_commit
        persistency.close_and_add_commit
        table_lid = hash["Sales"].as(TableLID)
        amount_field = hash["Amount"].as(FieldLID)
        amounts = persistency.get_field(amount_field)
        rec_10 = amounts.find { |_, v| v == 10i64 }.not_nil![0]
        # Write-then-restore: the open commit has a write on this cell but the
        # final value matches the parent commit's value.
        persistency.set_value(amount_field, rec_10, 999i64)
        persistency.set_value(amount_field, rec_10, 10i64)

        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        # Value equals parent → not in changed set. (The old "was-written"
        # semantic would have flagged it.)
        diff.diff_changed_cells.not_nil!.should be_empty
    end

    it "diff_deleted_records captures records absent at open commit" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Sales
            Region | Product | Amount
            north | widget | 10
            south | widget | 20
            north | gadget | 30
        EOT
        persistency.close_and_add_commit
        persistency.close_and_add_commit  # open commit
        table_lid = hash["Sales"].as(TableLID)
        amount_field = hash["Amount"].as(FieldLID)
        amounts = persistency.get_field(amount_field)
        rec_20 = amounts.find { |_, v| v == 20i64 }.not_nil![0]
        # Delete rec_20 in the open commit.
        persistency.remove_record(table_lid, rec_20)

        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        deleted = diff.diff_deleted_records.not_nil!
        deleted.size.should eq(1)
        rec, field_values = deleted.first
        rec.should eq(rec_20)
        # The deleted record's last-known field values must be populated
        # (read at parent context during spawn).
        field_values[amount_field].should eq(20i64)
    end

    it "diff shape is marked read-only" do
        persistency, table_lid, _parent, _open, _af, _pf, _r1, _r2 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!
        diff.readonly?.should be_true
        parent_shape.readonly?.should be_false
    end

    it "returns nil when there is no open commit" do
        persistency = Persistency::Default.new
        context = Context.new
        shape = ShapeState.new("empty", persistency, context)
        shape.context = Context.new
        shape.spawn_diff_shape.should be_nil
    end

    it "diff-Shape has diff_target_commit set to parent's open commit" do
        persistency, table_lid, _parent, open_commit, _af, _pf, _r1, _r2 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!
        diff.diff_target_commit.should eq(open_commit)
    end

    # --- Auto-refresh: edits while diff-Shape is open must update its state. ---

    it "diff_changed_cells refreshes after a new edit at the open commit" do
        persistency, table_lid, _parent, _open, amount_field, _pf, _rec_10, _rec_30 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        size_before = diff.diff_changed_cells.not_nil!.size

        # New edit at the open commit (simulates editing in another shape).
        amounts = persistency.get_field(amount_field)
        rec_50 = amounts.find { |_, v| v == 50i64 }.not_nil![0]
        persistency.set_value(amount_field, rec_50, 7777i64)

        # Drive a frame: shapes' update() runs the version-change branch.
        diff.update

        diff.diff_changed_cells.not_nil!.size.should eq(size_before + 1),
            "diff_changed_cells should grow by 1 after a new edit; was #{size_before}, now #{diff.diff_changed_cells.not_nil!.size}"
    end

    it "add_record routes its write through the Shape's context (changes counter visible)" do
        # Mirrors clicking "Add record" after Commit!: the new record's write
        # must land on the Shape's open commit so changes_in_open_commit
        # (which the History counter reads under the Shape's context) sees it.
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Persons
            Name
            Wanda
        EOT
        table_lid = hash["Persons"].as(TableLID)
        context = persistency.context.clone
        shape = ShapeState.new("Persons", persistency, context, table_lid)
        shape.do_commit  # Commit! → fresh open commit, no edits yet

        # Counter under shape's context: nothing changed.
        persistency.contexts.push(shape.context)
        before = persistency.changes_in_open_commit
        persistency.contexts.pop
        before.size.should eq(0), "no changes expected immediately post-commit"

        shape.add_record  # GUI's "Add record" button

        persistency.contexts.push(shape.context)
        after = persistency.changes_in_open_commit
        persistency.contexts.pop
        after.size.should eq(1), "Add record should bump the counter for this shape's table"
        after[table_lid].records_added.should eq(1)
    end

    it "add_field_simple routes its write through the Shape's context" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Persons
            Name
            Wanda
        EOT
        table_lid = hash["Persons"].as(TableLID)
        context = persistency.context.clone
        shape = ShapeState.new("Persons", persistency, context, table_lid)
        shape.do_commit

        shape.add_field_simple  # GUI's plain "Add field" button (no dots)

        persistency.contexts.push(shape.context)
        after = persistency.changes_in_open_commit
        persistency.contexts.pop
        after.size.should eq(1), "Add field should bump the counter for this shape's table"
        after[table_lid].fields_added.should eq(1)
    end

    it "diff captures a deletion routed through the matrix adapter (GUI flow)" do
        # Mirrors the real GUI: load demo, Commit!, then delete via the
        # SimpleMatrixAdapter (the path the VM Delete-key handler takes).
        # The deletion must land on the shape's context so the diff-Shape's
        # parent/open commits see it.
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Persons
            Name
            Wanda
            Sauron
            Samwise
        EOT
        table_lid = hash["Persons"].as(TableLID)

        context = persistency.context.clone
        parent_shape = ShapeState.new("Persons", persistency, context, table_lid)
        parent_shape.do_commit  # GUI's Commit! button

        # Find Wanda's matrix row by walking the shape's pivot, then ask the
        # adapter to delete that row — same code path as the VM's Delete key.
        adapter = parent_shape.matrix_adapter.not_nil!
        rc = parent_shape.matrix_userdata_rc.not_nil!
        wanda_row : Int32? = nil
        persistency.contexts.push(parent_shape.context)
        rc.size[0].times do |row|
            (0...rc.size[1]).each do |col|
                if rc[[row, col]] == "Wanda"
                    wanda_row = row
                    break
                end
            end
            break if wanda_row
        end
        persistency.contexts.pop
        adapter.cell_delete({wanda_row.not_nil!, 0})
        parent_shape.update(true)

        diff = parent_shape.spawn_diff_shape.not_nil!

        diff.diff_deleted_records.not_nil!.size.should eq(1),
            "deleted count should be 1 but is #{diff.diff_deleted_records.not_nil!.size}"
    end

    it "diff_deleted_records captures a record removed via remove_record at the open commit (post-close demo flow)" do
        # Mirrors the actual app flow: load data (commit 0), Commit! (open=1),
        # delete a record at commit 1, then click "show changes" at commit 1.
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Persons
            Name
            Wanda
            Sauron
            Samwise
        EOT
        # close_and_add_commit -> seals 0, opens 1 (mirrors the user clicking "Commit!")
        persistency.close_and_add_commit
        table_lid = hash["Persons"].as(TableLID)
        name_field = hash["Name"].as(FieldLID)
        names = persistency.get_field(name_field)
        wanda = names.find { |_, v| v == "Wanda" }.not_nil![0]
        # User deletes Wanda *at the open commit* (1).
        persistency.remove_record(table_lid, wanda)

        # Spawn diff at commit 1 — parent = 0, open = 1
        context = persistency.context.clone
        parent_shape = ShapeState.new("Persons", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        diff.diff_deleted_records.not_nil!.size.should eq(1),
            "deleted count should be 1 (Wanda removed at open commit) but is #{diff.diff_deleted_records.not_nil!.size}"
    end

    it "diff_deleted_records refreshes when a record is deleted after spawn" do
        persistency, table_lid, _parent, _open, amount_field, _pf, _rec_10, _rec_30 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        # No records deleted at spawn time.
        diff.diff_deleted_records.not_nil!.size.should eq(0)

        amounts = persistency.get_field(amount_field)
        rec_50 = amounts.find { |_, v| v == 50i64 }.not_nil![0]
        persistency.remove_record(table_lid, rec_50)

        diff.update

        diff.diff_deleted_records.not_nil!.size.should eq(1),
            "deleted count should grow to 1 after removing a record at the open commit"
        diff.diff_deleted_records.not_nil!.first[0].should eq(rec_50)
    end

    it "diff filter refreshes after a new edit so the row filter shows the new record" do
        persistency, table_lid, _parent, _open, amount_field, _pf, _rec_10, _rec_30 =
            make_sales_with_pending_edits
        context = persistency.context.clone
        parent_shape = ShapeState.new("Sales", persistency, context, table_lid)
        diff = parent_shape.spawn_diff_shape.not_nil!

        # Initially 2 changed records → 2 visible rows under default filter.
        drilled_vt = diff.unfiltered_vt.not_nil!
        Table::Lazy::Filter.apply(drilled_vt, diff.filter_state).size[0].should eq(2)

        amounts = persistency.get_field(amount_field)
        rec_50 = amounts.find { |_, v| v == 50i64 }.not_nil![0]
        persistency.set_value(amount_field, rec_50, 7777i64)

        diff.update

        drilled_vt = diff.unfiltered_vt.not_nil!
        Table::Lazy::Filter.apply(drilled_vt, diff.filter_state).size[0].should eq(3),
            "row filter should now reveal the third just-changed record"
    end
end
