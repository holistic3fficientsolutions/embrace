require "spec"
require "./spec_helper"
require "../src/fieldlist"
require "../src/global"
require "../src/table/pivot"
require "../src/persistency"
require "../src/virtualtable"

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
    it "densifies a vacated aggregate level (enforces 'no left gaps')" do
        # A move can strand an aggregate at level 1 with level 0 empty (the field that held level 0 became
        # a row header). The pivot would render that empty level as a phantom NilDeadArea band under every
        # record. Fieldlist#update enforces the module's "no left gaps" invariant (fl.cr:269) — the same
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
