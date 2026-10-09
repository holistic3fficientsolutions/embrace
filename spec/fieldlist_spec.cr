require "spec"
require "./spec_helper"
require "../src/fieldlist"
require "../src/global"
require "../src/table/pivot"
require "../src/persistency"
require "../src/virtualtable"

include Persistency

# Note: Do NOT include Table::VirtualTable at top level — it shadows
# the VirtualTable(T,U) class and breaks property_spec when compiled together.

describe Table::Lazy::Fieldlist(FieldlistCell,Cell) do
    it "cloning fieldlist works, part one" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            who       | project
            Alan      | lawsuiting
        EOT

        configurator = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        configurator.toggle_select(configurator.tree)

        vt = configurator.run
        fieldlist = Table::Lazy::Fieldlist(FieldlistCell,Cell).new(vt) # creates a default fieldlist on the VT
        matrix_userdata_rc = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist)
        matrix_userdata_rc.to_a2.should eq([[1, "Alan", "lawsuiting"]])
        configurator.toggle_select(configurator.tree[Table::VirtualTable::PseudoFields::Rank])
        matrix_userdata_rc.to_a2.should eq([["Alan", "lawsuiting"]])

        configurator2 = configurator.clone(false)
        vt2 = configurator2.run
        fieldlist2 = fieldlist.clone(vt2)
        matrix_userdata_rc2 = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt2, fieldlist2)
        matrix_userdata_rc2.to_a2.should eq([["Alan", "lawsuiting"]])
        configurator2.toggle_select(configurator2.tree[Table::VirtualTable::PseudoFields::Rank])
        matrix_userdata_rc2.to_a2.should eq([[1, "Alan", "lawsuiting"]])

        # but unchanged:
        matrix_userdata_rc.to_a2.should eq([["Alan", "lawsuiting"]])
    end
    it "cloning fieldlist works, part two" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            who       | project
            Alan      | lawsuiting
        EOT

        configurator = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        configurator.toggle_select(configurator.tree)

        vt = configurator.run
        fieldlist = Table::Lazy::Fieldlist(FieldlistCell,Cell).new(vt) # creates a default fieldlist on the VT
        matrix_userdata_rc = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist)
        matrix_userdata_rc.to_a2.should eq([[1, "Alan", "lawsuiting"]])
        configurator.toggle_select(configurator.tree[Table::VirtualTable::PseudoFields::Rank])
        matrix_userdata_rc.to_a2.should eq([["Alan", "lawsuiting"]])
        configurator.toggle_select(configurator.tree[Table::VirtualTable::PseudoFields::Rank])
        matrix_userdata_rc.to_a2.should eq([[1, "Alan", "lawsuiting"]])

        persistency2 = persistency
        configurator2 = configurator.clone(false) # `false`: do not clone persistency
        vt2 = configurator2.run
        fieldlist2 = fieldlist.clone(vt2)
        matrix_userdata_rc2 = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt2, fieldlist2)

        matrix_userdata_rc2.to_a2.should eq([[1, "Alan", "lawsuiting"]])
        configurator2.toggle_select(configurator2.tree[Table::VirtualTable::PseudoFields::Rank])
        matrix_userdata_rc2.to_a2.should eq([["Alan", "lawsuiting"]])

        # but unchanged:
        matrix_userdata_rc.to_a2.should eq([[1, "Alan", "lawsuiting"]])
    end
    # Reading a pivot's version derives nothing of its own: it is the version of its inputs (it may sync the
    # VirtualTable root and the Fieldlist under it, as any data read does). A stale pivot rebuilds on the next DATA
    # read, once, under exactly that version.
    it "reads a pivot's version without rebuilding the pivot" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            who       | amount
            Alan      | 10
            Bob       | 20
        EOT
        configurator = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        configurator.toggle_select(configurator.tree)
        vt = configurator.run
        fieldlist = Table::Lazy::Fieldlist(FieldlistCell,Cell).new(vt)
        pivot = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist)
        pivot.size # built
        vt.hyperplane_add(0) # a record: the pivot is stale
        rebuilds = Table::Lazy::Pivot::Hierarchic.rebuild_count
        version = pivot.version
        Table::Lazy::Pivot::Hierarchic.rebuild_count.should eq(rebuilds) # a read rebuilt nothing
        pivot.size
        Table::Lazy::Pivot::Hierarchic.rebuild_count.should eq(rebuilds + 1) # the data read did, once
        pivot.size
        pivot.version.should eq(version) # ...under the version read before it
        Table::Lazy::Pivot::Hierarchic.rebuild_count.should eq(rebuilds + 1)
    end

    # A field-list change the Fieldlist SETTLES (densifies a stranded aggregate): its own sync writes into the table
    # its version is made of, so a pivot keyed on the unsettled sum would rebuild twice. Once, under the read version.
    it "rebuilds a pivot once after a field-list change the Fieldlist settles" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            who       | amount
            Alan      | 10
            Bob       | 20
        EOT
        configurator = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        configurator.toggle_select(configurator.tree)
        vt = configurator.run
        fieldlist = Table::Lazy::Fieldlist(FieldlistCell,Cell).new(vt)
        pivot = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist)
        pivot.size # built
        cls_col = Table::Lazy::Pivot::FieldlistColumns::PivotClass.value
        lvl_col = Table::Lazy::Pivot::FieldlistColumns::Level.value
        agg = Table::Lazy::Pivot::Classes::Aggregate.value
        aggs = (0...fieldlist.size[0]).select { |i| fieldlist[[i, cls_col]]? == agg }
        aggs[0...-1].each { |i| fieldlist[[i, cls_col]] = Table::Lazy::Pivot::Classes::Row.value.to_i64 }
        fieldlist[[aggs[-1], lvl_col]] = 1i64 # stranded: level 0 empty, the Fieldlist will densify it
        rebuilds = Table::Lazy::Pivot::Hierarchic.rebuild_count
        version = pivot.version
        2.times { pivot.size }
        Table::Lazy::Pivot::Hierarchic.rebuild_count.should eq(rebuilds + 1)
        pivot.version.should eq(version)
        fieldlist[[aggs[-1], lvl_col]]?.should eq(0i64) # instrument: the Fieldlist did settle it
    end

    # A column-set change made with no data read of the table (a field selected in the configurator): the first
    # read is the pivot's version, which syncs the Fieldlist - and the Fieldlist must see the new column.
    it "sees a column selected since, when the pivot's version is read first" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            who       | amount
            Alan      | 10
        EOT
        configurator = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        configurator.toggle_select(configurator.tree)
        vt = configurator.run
        fieldlist = Table::Lazy::Fieldlist(FieldlistCell,Cell).new(vt)
        pivot = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist)
        pivot.size # built
        columns = fieldlist.size[0]
        note = persistency.add_field(hash["allocation"].as(TableLID), "note")
        configurator.toggle_select(configurator.tree[note]) # a new column, no data read of the table
        pivot.version
        fieldlist.size[0].should eq(columns + 1)
    end

    it "densifies a vacated aggregate level (enforces 'no left gaps')" do
        # A move can strand an aggregate at level 1 with level 0 empty (the field that held level 0 became
        # a row header). The pivot would render that empty level as a phantom NilDeadArea band under every
        # record. Fieldlist#update enforces the module's "no left gaps" invariant — the same
        # densification the transpose already applies — so a plain move behaves like the transpose.
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            who       | amount
            Alan      | 10
            Bob       | 20
        EOT
        configurator = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        configurator.toggle_select(configurator.tree)
        vt = configurator.run
        fieldlist = Table::Lazy::Fieldlist(FieldlistCell,Cell).new(vt) # default: Rank=Row L0, who/amount=Agg L0

        cls_col = Table::Lazy::Pivot::FieldlistColumns::PivotClass.value
        lvl_col = Table::Lazy::Pivot::FieldlistColumns::Level.value
        agg     = Table::Lazy::Pivot::Classes::Aggregate.value
        row_cls = Table::Lazy::Pivot::Classes::Row.value

        # Vacate aggregate level 0: move every aggregate but one to a row header, strand the last at level 1.
        aggs = (0...fieldlist.size[0]).select { |i| fieldlist[[i, cls_col]]? == agg }
        aggs[0...-1].each { |i| fieldlist[[i, cls_col]] = row_cls.to_i64 }
        stranded = aggs[-1]
        fieldlist[[stranded, lvl_col]] = 1i64 # sole aggregate now at level 1, level 0 empty -> a gap
        fieldlist.version # force a derivation

        # update() densified the stranded aggregate back to level 0 (no left gap).
        fieldlist[[stranded, lvl_col]]?.should eq(0i64)
    end
end
