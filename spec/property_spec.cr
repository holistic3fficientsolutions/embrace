require "spec"
require "./spec_helper"
require "../src/fieldlist"
require "../src/global"
require "../src/table/pivot"
require "../src/persistency"
require "../src/virtualtable"

include Persistency

# --- Test World: holds persistency + persistent configurator state ---

class PropertyTestWorld
  getter persistency : Persistency::Default
  getter hash : Hash(String, FieldLID|TableLID|RecordLID)
  getter table_lids : Array(TableLID)
  getter ops_log : Array(String)
  getter rng : Random

  # Persistent configurator state per table
  getter configurators : Hash(TableLID, Table::VirtualTable::Configurator(Cell, BaseCell))
  getter vts : Hash(TableLID, Table::Lazy::Raw::Base(Cell))
  getter selected_fields : Hash(TableLID, Set(FieldLID))
  getter rank_selected : Hash(TableLID, Bool)

  def initialize(seed : UInt64)
    @persistency = Persistency::Default.new
    @hash = Hash(String, FieldLID|TableLID|RecordLID).new
    @table_lids = Array(TableLID).new
    @ops_log = Array(String).new
    @rng = Random.new(seed)
    @configurators = Hash(TableLID, Table::VirtualTable::Configurator(Cell, BaseCell)).new
    @vts = Hash(TableLID, Table::Lazy::Raw::Base(Cell)).new
    @selected_fields = Hash(TableLID, Set(FieldLID)).new
    @rank_selected = Hash(TableLID, Bool).new
    setup
  end

  private def setup
    help = TableReader(Persistency::Default, Persistency::Cell).new(@persistency, @hash)
    help << <<-EOT
        cities
        city    | country
        Boston  | USA
        Berlin  | Germany
        Tokyo   | Japan
        London  | UK

        persons
        name    | hometown_city | age
        Alan    | Boston        | 30
        Berta   | Berlin        | 25
        Carlos  | Tokyo         | 40
        Diana   | London        | 35
        Eve     | Boston        | 28

        projects
        title       | lead_name
        Alpha       | Alan
        Beta        | Berta
        Gamma       | Carlos
    EOT
    @table_lids = ["cities", "persons", "projects"].map { |n| @hash[n].as(TableLID) }

    # Initialize persistent configurators: all fields selected
    @table_lids.each do |tid|
      c = Table::VirtualTable::Configurator(Cell, BaseCell).new(@persistency, tid)
      c.toggle_select(c.tree)
      @configurators[tid] = c
      @vts[tid] = c.run
      @selected_fields[tid] = field_lids(tid).to_set
      @rank_selected[tid] = true
    end
  end

  def record_lids(table_lid : TableLID) : Array(RecordLID)
    @persistency.get_table(table_lid).map(&.[0].as(RecordLID))
  end

  def field_lids(table_lid : TableLID) : Array(FieldLID)
    @persistency.get_field_lids(table_lid)
  end

  def is_reference?(field_lid : FieldLID) : Bool
    !@persistency.get_value(MetaFieldLIDs::RefersTo, field_lid).nil?
  end

  def reference_target_table(field_lid : FieldLID) : TableLID?
    if target_fld = @persistency.get_value(MetaFieldLIDs::RefersTo, field_lid)
      @persistency.get_value(MetaFieldLIDs::BelongsTo, target_fld.as(FieldLID)).as(TableLID?)
    end
  end

  def log(msg : String)
    @ops_log << msg
  end
end

# --- Generators: random operations wrapping existing API ---

module Gen
  STRINGS = ["Foo", "Bar", "Baz", "Qux", "Zap", "Nix", "Woo", "Yak"]
  INTS    = [1i64, 2i64, 10i64, 42i64, 99i64, 0i64, -1i64, 100i64]

  def self.add_record(w : PropertyTestWorld)
    tid = w.table_lids.sample(w.rng)
    rid = w.persistency.add_record(tid)
    w.field_lids(tid).each do |fld|
      if w.is_reference?(fld)
        if target_table = w.reference_target_table(fld)
          targets = w.record_lids(target_table)
          w.persistency.set_value(fld, rid, targets.sample(w.rng)) unless targets.empty?
        end
      else
        val = w.rng.rand(2) == 0 ? STRINGS.sample(w.rng) : INTS.sample(w.rng)
        w.persistency.set_value(fld, rid, val)
      end
    end
    w.log "add_record(table=#{tid}, record=#{rid})"
  end

  def self.remove_record(w : PropertyTestWorld) : Bool
    tid = w.table_lids.sample(w.rng)
    recs = w.record_lids(tid)
    return false if recs.size <= 1
    rid = recs.sample(w.rng)
    w.persistency.remove_record(tid, rid)
    w.log "remove_record(table=#{tid}, record=#{rid})"
    true
  end

  def self.set_cell(w : PropertyTestWorld)
    tid = w.table_lids.sample(w.rng)
    flds = w.field_lids(tid)
    recs = w.record_lids(tid)
    return if flds.empty? || recs.empty?
    fld = flds.sample(w.rng)
    rec = recs.sample(w.rng)
    if w.is_reference?(fld)
      if target_table = w.reference_target_table(fld)
        targets = w.record_lids(target_table)
        return if targets.empty?
        val = w.rng.rand(3) == 0 ? nil : targets.sample(w.rng)
        w.persistency.set_value(fld, rec, val)
        w.log "set_ref(field=#{fld}, record=#{rec}, value=#{val})"
      end
    else
      val = case w.rng.rand(4)
            when 0 then STRINGS.sample(w.rng)
            when 1 then INTS.sample(w.rng)
            when 2 then nil
            else        STRINGS.sample(w.rng)
            end
      w.persistency.set_value(fld, rec, val)
      w.log "set_cell(field=#{fld}, record=#{rec}, value=#{val})"
    end
  end

  def self.move_record(w : PropertyTestWorld) : Bool
    tid = w.table_lids.sample(w.rng)
    recs = w.record_lids(tid)
    return false if recs.size < 2
    from = w.rng.rand(recs.size) + 1
    to = w.rng.rand(recs.size) + 1
    w.persistency.move_record_by_rank(tid, from, to)
    w.log "move_record(table=#{tid}, from=#{from}, to=#{to})"
    true
  end

  def self.toggle_select(w : PropertyTestWorld)
    tid = w.table_lids.sample(w.rng)
    c = w.configurators[tid]
    flds = w.field_lids(tid)
    return if flds.empty?

    if w.rng.rand(4) == 0
      # Toggle Rank
      c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
      w.rank_selected[tid] = !w.rank_selected[tid]
      w.log "toggle_rank(table=#{tid}, now=#{w.rank_selected[tid]})"
    else
      # Toggle a random field
      fld = flds.sample(w.rng)
      c.toggle_select(c.tree[fld])
      if w.selected_fields[tid].includes?(fld)
        w.selected_fields[tid].delete(fld)
      else
        w.selected_fields[tid] << fld
      end
      w.log "toggle_field(table=#{tid}, field=#{fld}, sel=#{w.selected_fields[tid].includes?(fld)})"
    end
  end

  def self.random_op(w : PropertyTestWorld)
    case w.rng.rand(14)
    when 0..2  then add_record(w)
    when 3..4  then remove_record(w) || set_cell(w)
    when 5..7  then set_cell(w)
    when 8..9  then move_record(w) || set_cell(w)
    when 10..13 then toggle_select(w)
    end
  end
end

# --- Invariant Checkers ---

module Invariants
  # Table structure: each row has RecordLID + Rank + N fields, ranks are 1..N, RecordLIDs unique
  def self.check_table_structure(w : PropertyTestWorld)
    w.table_lids.each do |tid|
      flds = w.field_lids(tid)
      rows = w.persistency.get_table(tid)
      expected_cols = flds.size + 2
      record_ids = Set(RecordLID).new
      rows.each_with_index do |row, i|
        row.size.should eq(expected_cols),
          "table #{tid} row #{i}: #{row.size} cols, expected #{expected_cols}\n#{w.ops_log.join("\n")}"
        rid = row[0].as(RecordLID)
        record_ids.includes?(rid).should be_false,
          "table #{tid}: duplicate RecordLID #{rid}\n#{w.ops_log.join("\n")}"
        record_ids << rid
        rank = row[1].as(Int64)
        rank.should eq((i + 1).to_i64),
          "table #{tid} row #{i}: rank #{rank}, expected #{i + 1}\n#{w.ops_log.join("\n")}"
      end
    end
  end

  # Oracle: persistent VT (with partial selection) matches raw data
  def self.check_persistent_vt(w : PropertyTestWorld)
    w.table_lids.each do |tid|
      selected = w.selected_fields[tid]
      has_rank = w.rank_selected[tid]
      expected_cols = selected.size + (has_rank ? 1 : 0)

      vt = w.vts[tid]
      raw = w.persistency.get_table(tid)

      if expected_cols == 0
        vt.size[1].should eq(0),
          "PersistVT(#{tid}): expected 0 cols when nothing selected, got #{vt.size[1]}\n#{w.ops_log.join("\n")}"
        next
      end

      a2 = vt.to_a2
      a2.size.should eq(raw.size),
        "PersistVT(#{tid}): rows #{a2.size} != raw #{raw.size}\n#{w.ops_log.join("\n")}"
      a2.each_with_index do |row, ri|
        row.size.should eq(expected_cols),
          "PersistVT(#{tid}) row #{ri}: #{row.size} cols != #{expected_cols}\n#{w.ops_log.join("\n")}"
      end

      # Value-level oracle: check non-reference values match raw data
      flds = w.field_lids(tid)
      selected_ordered = flds.select { |f| selected.includes?(f) }

      # Build field → VT column index map using stable user IDs
      vt_ids = vt.hyperplane_get_ids(0).to_a
      field_to_vt_col = Hash(FieldLID, Int32).new
      selected_ordered.each do |fld|
        vt_col_idx = (0...vt.size[1]).find { |c| vt.hyperplane_get_name(1, [0, c]) == w.persistency.get_value(MetaFieldLIDs::Names, fld) }
        field_to_vt_col[fld] = vt_col_idx.not_nil! if vt_col_idx
      end

      # Find rank column position (may not be at index 0 with stable ordering)
      rank_col = has_rank ? (0...vt.size[1]).find { |c| vt.hyperplane_is_rank(1, [0, c]) } : nil

      raw.each_with_index do |raw_row, ri|
        rid = raw_row[0].as(RecordLID)
        vt_row = a2[ri]

        if rank_col
          vt_row[rank_col].should eq(raw_row[1]),
            "PersistVT(#{tid}) row #{ri}: rank #{vt_row[rank_col]} != #{raw_row[1]}\n#{w.ops_log.join("\n")}"
        end

        selected_ordered.each do |fld|
          col = field_to_vt_col[fld]?
          next unless col
          vt_val = vt_row[col]
          raw_val = w.persistency.get_value(fld, rid)

          if w.is_reference?(fld)
            if vt_val.is_a?(ReferenceCell(BaseCell))
              if raw_val.nil?
                vt_val.rank.should eq(0),
                  "PersistVT(#{tid}) row #{ri} field #{fld}: nil ref rank #{vt_val.rank} != 0\n#{w.ops_log.join("\n")}"
              else
                target_table = w.reference_target_table(fld)
                if target_table
                  target_rows = w.persistency.get_table(target_table)
                  target_row = target_rows.find { |r| r[0] == raw_val }
                  if target_row
                    expected_rank = target_row[1].as(Int64).to_i32
                    vt_val.rank.should eq(expected_rank),
                      "PersistVT(#{tid}) row #{ri} field #{fld}: ref rank #{vt_val.rank} != #{expected_rank}\n#{w.ops_log.join("\n")}"
                    target_fld = w.persistency.get_value(MetaFieldLIDs::RefersTo, fld).as(FieldLID)
                    expected_display = w.persistency.get_value(target_fld, raw_val.as(RecordLID))
                    vt_val.value.should eq(expected_display),
                      "PersistVT(#{tid}) row #{ri} field #{fld}: display '#{vt_val.value}' != '#{expected_display}'\n#{w.ops_log.join("\n")}"
                  else
                    vt_val.rank.should eq(0),
                      "PersistVT(#{tid}) row #{ri} field #{fld}: removed ref rank #{vt_val.rank} != 0\n#{w.ops_log.join("\n")}"
                  end
                end
              end
            end
          else
            vt_val.should eq(raw_val),
              "PersistVT(#{tid}) row #{ri} field #{fld}: vt=#{vt_val.inspect} raw=#{raw_val.inspect}\n#{w.ops_log.join("\n")}"
          end
        end
      end
    end
  end

  # Pivot with random field roles: doesn't crash, dimensions consistent
  def self.check_pivot_random_roles(w : PropertyTestWorld, tid : TableLID)
    c = Table::VirtualTable::Configurator(Cell, BaseCell).new(w.persistency, tid)
    c.toggle_select(c.tree)
    vt = c.run
    fl = Table::Lazy::Fieldlist(FieldlistCell, Cell).new(vt)

    roles = [
      Table::Lazy::Pivot::Classes::Row.value,
      Table::Lazy::Pivot::Classes::Column.value,
      Table::Lazy::Pivot::Classes::Aggregate.value,
    ]
    fl_rows = fl.size[0]
    fl_rows.times do |row_i|
      fl[[row_i, Table::Lazy::Fieldlist::ColumnIndices::Class.value]] = roles.sample(w.rng).to_i64
    end

    pivot = Table::Lazy::Pivot::Hierarchic(Cell, BaseCell, FieldlistCell).new(vt, fl)
    sz = pivot.size
    a2 = pivot.to_a2

    a2.size.should eq(sz[0]),
      "PivotRoles(#{tid}) rows #{a2.size} != size[0] #{sz[0]}\n#{w.ops_log.join("\n")}"
    a2.each_with_index do |row, ri|
      row.size.should eq(sz[1]),
        "PivotRoles(#{tid}) row #{ri} cols #{row.size} != size[1] #{sz[1]}\n#{w.ops_log.join("\n")}"
    end
  end

  # Clone isolation: cloned configurator output unaffected by original mutation
  def self.check_clone_isolation(w : PropertyTestWorld, tid : TableLID)
    c = Table::VirtualTable::Configurator(Cell, BaseCell).new(w.persistency, tid)
    c.toggle_select(c.tree)

    c2 = c.clone(false)
    vt2 = c2.run
    snapshot = vt2.to_a2

    c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
    vt2_after = vt2.to_a2
    vt2_after.size.should eq(snapshot.size),
      "Clone isolation(#{tid}): rows #{snapshot.size} -> #{vt2_after.size}\n#{w.ops_log.join("\n")}"
    c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
  end

  def self.check_all(w : PropertyTestWorld, step : Int32)
    check_table_structure(w)
    if step % 2 == 0
      check_persistent_vt(w)
    end
    if step % 7 == 0
      w.table_lids.each { |tid| check_pivot_random_roles(w, tid) }
    end
    if step % 10 == 0
      w.table_lids.each { |tid| check_clone_isolation(w, tid) }
    end
  end
end

# --- Test Loop ---

describe "Property-based testing" do
  it "move_records round-trip preserves table-structure + VT invariants" do
    # Deterministic (not a random Gen op: the seeded world's three tables are structurally
    # distinct, so a random move would trip the structure-match precondition and no-op).
    # Two ISOLATED structure-matching tables (no refs in/out) so the move isn't entangled
    # with reference degradation; both registered with the harness so the checkers cover them.
    w = PropertyTestWorld.new(1_u64)
    p = w.persistency
    src = p.add_table("src_mv"); sa = p.add_field(src, "a"); sb = p.add_field(src, "b")
    dst = p.add_table("dst_mv"); p.add_field(dst, "a"); p.add_field(dst, "b")
    rs = (0...3).map do |i|
      r = p.add_record(src); p.set_value(sa, r, "a#{i}"); p.set_value(sb, r, "b#{i}"); r
    end
    [src, dst].each do |tid|
      c = Table::VirtualTable::Configurator(Cell, BaseCell).new(p, tid)
      c.toggle_select(c.tree)
      w.configurators[tid] = c
      w.vts[tid] = c.run
      w.selected_fields[tid] = w.field_lids(tid).to_set
      w.rank_selected[tid] = true
      w.table_lids << tid
    end
    check = -> do
      Invariants.check_table_structure(w)
      w.configurators.each { |tid, c| w.vts[tid] = c.run } # refresh VTs after the data change
      Invariants.check_persistent_vt(w)
    end
    check.call
    p.move_records([rs[1]], src, dst); check.call           # middle record out
    p.move_records([rs[0], rs[2]], src, dst); check.call     # the rest out (src now empty)
    p.get_record_lids(src).should eq([] of RecordLID)
    p.move_records(rs, dst, src); check.call                 # all back
    p.get_record_lids(src).should eq(rs)                     # original order restored
  end
  it "random operations preserve invariants across data + configurator mutations" do
    master_seed = ENV.fetch("PROP_SEED", Time.utc.to_unix.to_s).to_u64
    num_runs = ENV.fetch("PROP_RUNS", "20").to_i
    ops_per_run = ENV.fetch("PROP_OPS", "20").to_i
    puts "Property test: seed=#{master_seed}, runs=#{num_runs}, ops=#{ops_per_run}"

    master_rng = Random.new(master_seed)
    num_runs.times do |run|
      run_seed = master_rng.next_u.to_u64
      w = PropertyTestWorld.new(run_seed)
      ops_per_run.times do |step|
        begin
          Gen.random_op(w)
          Invariants.check_all(w, step)
        rescue ex
          puts "FAILED at run=#{run}, step=#{step}, run_seed=#{run_seed}"
          puts "Reproduce: PROP_SEED=#{run_seed} PROP_RUNS=1 PROP_OPS=#{step + 1}"
          puts "Ops log:"
          w.ops_log.each_with_index { |op, i| puts "  #{i}: #{op}" }
          raise ex
        end
      end
    end
  end

  # --- V2: Write-through-pivot bug exploration ---
  # Tries many configurations to find and classify all failure modes.

  it "write-through-pivot with chained tables preserves consistency" do
    master_seed = ENV.fetch("PIVOT_SEED", Time.utc.to_unix.to_s).to_u64
    num_runs = ENV.fetch("PIVOT_RUNS", "10").to_i
    ops_per_run = ENV.fetch("PIVOT_OPS", "15").to_i
    puts "Pivot write test: seed=#{master_seed}, runs=#{num_runs}, ops=#{ops_per_run}"

    # Collect all failures instead of aborting on first
    failures = Array({UInt64, String, String}).new # {run_seed, error_class, summary}
    op_counts = Hash(String, Int32).new(0)

    master_rng = Random.new(master_seed)
    num_runs.times do |run|
      run_seed = master_rng.next_u.to_u64
      rng = Random.new(run_seed)
      ops_log = Array(String).new

      begin
        # Setup: countries → cities → persons (2-hop chain)
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            countries
            country
            MiddleEarth
            USA
            Nowhere

            cities
            city    | liesin_country
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city | eyecolor
            Sauron  | Mordor       | Red
            Samwise | Shire        | Brown
            Alan    | Boston       | Blue
            Denny   | Boston       | Hazel
        EOT

        # Randomly choose configurator configuration
        config_style = rng.rand(3)
        c = Table::VirtualTable::Configurator(Cell, BaseCell).new(persistency, hash["persons"])

        case config_style
        when 0
          # 3-level expand, no ShowAll
          c.toggle_expand(c.tree[hash["livesin"]])
          c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
          c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
          c.toggle_select(c.tree)
          c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
          c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["city"]])
          ops_log << "config: 3-level expand, no ShowAll"
        when 1
          # 4-level expand WITH ShowAll (adds NilRecord rows)
          c.toggle_expand(c.tree[hash["livesin"]])
          c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
          c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
          c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]][hash["country"]])
          c.toggle_select(c.tree)
          c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
          c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["city"]])
          c.toggle_select(c.tree[hash["livesin"]][hash["city"]][Table::VirtualTable::PseudoFields::ShowAll])
          c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]][hash["country"]][Table::VirtualTable::PseudoFields::ShowAll])
          ops_log << "config: 4-level expand, WITH ShowAll"
        when 2
          # 2-level expand only
          c.toggle_expand(c.tree[hash["livesin"]])
          c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
          c.toggle_select(c.tree)
          c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["city"]])
          ops_log << "config: 2-level expand"
        end

        vt = c.run

        # Randomly choose fieldlist configuration
        vt_cols = vt.size[1]
        fl_style = rng.rand(3)
        fl_data = Array(FieldlistCell).new

        case fl_style
        when 0
          # Kanban: country=Column, livesin=Column, rank=Row, rest=Aggregate
          ops_log << "fieldlist: kanban (col+col+row+agg)"
          vt_cols.times do |i|
            case i
            when 5 then fl_data.concat([i.to_i64, Table::Lazy::Pivot::Classes::Column.value.to_i64, 0i64, true])
            when 2 then fl_data.concat([i.to_i64, Table::Lazy::Pivot::Classes::Column.value.to_i64, 0i64, true])
            when 0 then fl_data.concat([i.to_i64, Table::Lazy::Pivot::Classes::Row.value.to_i64, 1i64, true])
            else        fl_data.concat([i.to_i64, Table::Lazy::Pivot::Classes::Aggregate.value.to_i64, 0i64, false])
            end
          end
        when 1
          # All rows (flat table through pivot)
          ops_log << "fieldlist: all rows (flat)"
          vt_cols.times do |i|
            fl_data.concat([i.to_i64, Table::Lazy::Pivot::Classes::Row.value.to_i64, 0i64, true])
          end
        when 2
          # Random roles
          ops_log << "fieldlist: random roles"
          roles = [Table::Lazy::Pivot::Classes::Row.value, Table::Lazy::Pivot::Classes::Column.value, Table::Lazy::Pivot::Classes::Aggregate.value]
          vt_cols.times do |i|
            fl_data.concat([i.to_i64, roles.sample(rng).to_i64, 0i64, true])
          end
        end

        fieldlist_table = Helper(FieldlistCell).array2table(4, fl_data)
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        pivot = Table::Lazy::Pivot::Hierarchic(Cell, BaseCell, FieldlistCell).new(vt, fieldlist_table)

        # Initial sanity check
        pivot.to_a2

        ops_per_run.times do |step|
          sz = pivot.size
          next if sz[0] == 0 || sz[1] == 0

          # Choose operation type
          op_type = rng.rand(10)

          if op_type < 7
            # --- Cell write ---
            writable = Array({Table::Index, Cell}).new
            sz[0].times do |r|
              sz[1].times do |col|
                a = pivot.get_assignability([r, col])
                next unless a == Table::Lazy::Pivot::Assignability::Directly
                val = pivot[[r, col]]?
                next if val.nil? || val.is_a?(NilRecordStruct) || val.is_a?(NilDeadAreaStruct)
                writable << {[r, col], val}
              end
            end
            next if writable.empty?

            idx, current_val = writable.sample(rng)

            new_idx = case current_val
            when ReferenceCell(BaseCell)
              max_rank = current_val.values.size - 1
              new_rank = rng.rand(max_rank + 1)
              current_val.rank = new_rank
              ops_log << "write_ref(#{idx}, rank=#{new_rank})"
              pivot[idx] = current_val
            when Int64
              new_val = (rng.rand(Math.max(sz[0], 4)) + 1).to_i64
              ops_log << "write_int(#{idx}, val=#{new_val})"
              pivot[idx] = new_val
            when String
              new_val = Gen::STRINGS.sample(rng)
              ops_log << "write_str(#{idx}, val=#{new_val})"
              pivot[idx] = new_val
            when Float64
              new_val = (rng.rand(100) + 1).to_f64
              ops_log << "write_float(#{idx}, val=#{new_val})"
              pivot[idx] = new_val
            else
              next
            end
            ops_log[-1] += " → #{new_idx}"

          elsif op_type < 8
            # --- Add row (global, no position) ---
            ops_log << "hyperplane_add(0)"
            new_idx = pivot.hyperplane_add(0)
            ops_log[-1] += " → #{new_idx}"

          elsif op_type < 9
            # --- Add row at Indirectly-assignable cell (the hard path) ---
            indirect = Array(Table::Index).new
            sz[0].times do |r|
              sz[1].times do |col|
                if pivot.get_assignability([r, col]) == Table::Lazy::Pivot::Assignability::Indirectly
                  indirect << [r, col]
                end
              end
            end
            next if indirect.empty?
            idx = indirect.sample(rng)
            op_counts["indirect_add"] += 1
            ops_log << "hyperplane_add_indirect(0, #{idx})"
            begin
              new_idx = pivot.hyperplane_add(0, idx)
              ops_log[-1] += " → #{new_idx}"
              # Now write a value to the new cell
              new_val = pivot[new_idx]?
              if new_val && !new_val.is_a?(NilRecordStruct) && !new_val.is_a?(NilDeadAreaStruct)
                case new_val
                when Int64
                  pivot[new_idx] = (rng.rand(4) + 1).to_i64
                  ops_log << "  follow-up write_int(#{new_idx})"
                when String
                  pivot[new_idx] = Gen::STRINGS.sample(rng)
                  ops_log << "  follow-up write_str(#{new_idx})"
                when ReferenceCell(BaseCell)
                  max_rank = new_val.values.size - 1
                  new_val.rank = rng.rand(max_rank + 1)
                  pivot[new_idx] = new_val
                  ops_log << "  follow-up write_ref(#{new_idx}, rank=#{new_val.rank})"
                end
              end
            rescue ex : ConditionsNotMet
              ops_log[-1] += " rejected: #{ex.message}"
              next
            end

          else
            # --- Remove row ---
            # Find a removable cell
            removable = Array(Table::Index).new
            sz[0].times do |r|
              a = pivot.get_assignability([r, 0])
              if a && a != Table::Lazy::Pivot::Assignability::Not
                removable << [r, 0]
              end
            end
            next if removable.empty?
            idx = removable.sample(rng)
            ops_log << "hyperplane_remove(0, #{idx})"
            begin
              pivot.hyperplane_remove(0, idx)
            rescue ex : ConditionsNotMet
              ops_log[-1] += " rejected: #{ex.message}"
              next
            end
          end

          # --- Invariant checks ---

          # 1. Pivot dimensions consistent
          sz2 = pivot.size
          a2 = pivot.to_a2
          a2.size.should eq(sz2[0]),
            "BUG:PIVOT_DIMS pivot rows #{a2.size} != #{sz2[0]}\n#{ops_log.join("\n")}"
          a2.each_with_index do |row, ri|
            row.size.should eq(sz2[1]),
              "BUG:PIVOT_DIMS pivot row #{ri}: #{row.size} cols != #{sz2[1]}\n#{ops_log.join("\n")}"
          end

          # 2. VT dimensions consistent
          vt_sz = vt.size
          vt_a2 = vt.to_a2
          vt_a2.size.should eq(vt_sz[0]),
            "BUG:VT_DIMS VT rows #{vt_a2.size} != #{vt_sz[0]}\n#{ops_log.join("\n")}"

          # 3. Cross-view: clone the SAME configurator (preserves auto-ShowAll state)
          #    then compare against a fresh VT from that clone
          if step % 5 == 0
            c2 = c.clone(false) # clone preserves ShowAll auto-toggle state
            vt2 = c2.run
            vt_a2.size.should eq(vt2.to_a2.size),
              "BUG:CROSS_VIEW live VT #{vt_a2.size} rows != cloned VT #{vt2.to_a2.size} rows\n#{ops_log.join("\n")}"
          end
        end

      rescue ex : ConditionsNotMet
        failures << {run_seed, "ConditionsNotMet", "#{ex.message}\n#{ops_log.last(3).join(" | ")}"}
      rescue ex : Spec::AssertionFailed
        tag = if ex.message.try(&.includes?("BUG:"))
          ex.message.not_nil!.split(" ").first
        else
          "BUG:UNKNOWN"
        end
        failures << {run_seed, tag, "#{ex.message.try(&.split("\n").first)}\n#{ops_log.last(3).join(" | ")}"}
      rescue ex : TypeCastError
        failures << {run_seed, "TypeCastError", "#{ex.message}\n#{ops_log.join("\n")}\n#{ex.inspect_with_backtrace.split("\n").first(15).join("\n")}"}
      rescue ex
        failures << {run_seed, ex.class.name, "#{ex.message}\n#{ops_log.last(5).join(" | ")}"}
      end
    end

    puts "Op counts: #{op_counts}" if op_counts.any?

    # Report all failures clustered by type
    if !failures.empty?
      puts "\n=== BUG CLUSTER REPORT (#{failures.size}/#{num_runs} runs failed) ==="
      grouped = failures.group_by { |f| f[1] }
      grouped.each do |tag, items|
        puts "\n--- #{tag} (#{items.size} occurrences) ---"
        items.first(3).each do |seed, _, summary|
          puts "  seed=#{seed}: #{summary}"
        end
        puts "  ... and #{items.size - 3} more" if items.size > 3
      end
      puts "\n"
      fail "#{failures.size}/#{num_runs} runs failed — see cluster report above"
    end
  end
end
