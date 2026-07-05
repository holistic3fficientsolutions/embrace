require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/gui/dialogues"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"

include Persistency

# Regression guard: "Factor out" must be able to create the target table (and
# its field) *inline*, exactly as the v1 dialog and doc/02-references.md
# describe ("Factor out City -> creates new table 'Cities' with field 'City'").
# The ImGui -> CrymbleUI port had reduced the dialog to selecting a
# pre-existing table/field only, forcing the user to create the table (and
# delete its default record) beforehand.
describe Dialogs::FactorOut do
  it "creates the target table and field inline, then factors out into them" do
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Persons
        Person | City
        Alan | Boston
        Denny | Boston
        Carol | Arizona
    EOT
    city_field = hash["City"].as(FieldLID)

    target_table : TableLID? = nil
    target_field : FieldLID? = nil
    dialog = Dialogs::FactorOut.new("Factoring out 'City'", persistency, persistency.context, city_field) do |ttl, tfl|
      target_table = ttl
      target_field = tfl
      persistency.factor_out_reference(persistency.get_table_lid(city_field).not_nil!, city_field, ttl, tfl)
    end

    # Before choosing/creating a target there is nothing to accept.
    dialog.ready?.should be_false

    # Drive the dialog exactly as the GUI would: create a brand-new target
    # table, re-target the field picker onto it, create the target field.
    dialog.table_picker.add_table("Cities")
    dialog.sync_field_picker!
    dialog.field_picker.add_field("City")
    dialog.ready?.should be_true

    dialog.accept

    # City is now a reference pointing into the freshly-created table's field.
    persistency.get_outward_reference(city_field).should eq(target_field)
    persistency.get_table_lid(target_field.not_nil!).should eq(target_table)
    # Duplicate values are deduplicated in the new table: Boston, Arizona -> 2.
    persistency.get_table(target_table.not_nil!).size.should eq(2)
  end
end
