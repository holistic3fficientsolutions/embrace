require "spec"
require "./spec_helper"
require "../src/global"
require "../src/persistency"
require "../src/constants"

# Names are labels, not identity — and a blank label is DISPLAYED as "(unnamed)", by exactly
# one owner: Persistency#display_name. Storage stays truthful (a never-named or renamed-to-empty
# field/table keeps its blank name); every display surface (shape title, configurator tree,
# fieldlist rows, pickers, dialogs, the History changes list) reads through this method, so the
# placeholder is consistent everywhere. Edit surfaces (rename prefill) deliberately read the raw
# name instead — an unnamed entity prefills an EMPTY box, not the placeholder text.

describe "Persistency#display_name" do
    it "falls back to (unnamed) for blank names, passes real names through" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Persons
            Name
            Wanda
        EOT
        table_lid = hash["Persons"].as(TableLID)
        field_lid = hash["Name"].as(FieldLID)

        # real names pass through untouched
        persistency.display_name(table_lid).should eq("Persons")
        persistency.display_name(field_lid).should eq("Name")

        # renamed to empty -> the placeholder (storage keeps the truth)
        persistency.set_value(MetaFieldLIDs::Names, field_lid, "")
        persistency.display_name(field_lid).should eq(Constant::Unnamed)
        persistency.get_value(MetaFieldLIDs::Names, field_lid).should eq("")

        persistency.set_value(MetaFieldLIDs::Names, table_lid, "")
        persistency.display_name(table_lid).should eq(Constant::Unnamed)
    end
end
