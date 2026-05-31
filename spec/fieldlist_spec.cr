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
end
