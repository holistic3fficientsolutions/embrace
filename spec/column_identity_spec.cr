require "spec"
require "./spec_helper"
require "../src/global"
require "../src/table/pivot"
require "../src/persistency"
require "../src/virtualtable"

# Column identity has ONE currency: the Configurator's stable user column id — the ids
# hyperplane_get_ids returns in bulk, the ids the fieldlist persists in its Column values.
# hyperplane_get_id (per cell) must return THAT id, and column_identity must resolve THAT id.
# Anything else (e.g. the internal flat column, which is positional, offset by the hidden
# RecordLID slot, and unstable across VT tree rebuilds) silently resolves every column to a
# NEIGHBOR — the exact misattribution class structural identity exists to kill.

describe "column identity currency" do
    it "hyperplane_get_id returns the hyperplane_get_ids id, and column_identity resolves it" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            who | project | amount
            Alan | law | 10
        EOT
        configurator = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        configurator.toggle_select(configurator.tree) # select all: Rank + the three fields
        vt = configurator.run

        # Per-cell ids agree with the bulk ids, positionally (update_push appends both pairwise).
        bulk = vt.hyperplane_get_ids(0).to_a
        per_cell = (0...vt.size[1]).map { |c| vt.hyperplane_get_id(1, [0, c]).not_nil! }
        per_cell.should eq(bulk)

        # And each id resolves to the column's actual identity: Rank first (tree order),
        # then the three fields in schema order.
        identities = per_cell.map { |id| vt.column_identity(id) }
        identities[0].should eq(Table::VirtualTable::PseudoFields::Rank)
        identities[1..].should eq([hash["who"], hash["project"], hash["amount"]])
    end
end
