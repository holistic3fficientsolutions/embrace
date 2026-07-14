require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# A field created with a BLANK name must read "(unnamed)", not an empty string.
# Reference fields are created only through the "..." AddField dialog, which
# submits "" for an un-named field; "" is truthy in Crystal, so the bare
# `args[:name]? || Constant::Unnamed` fallback used to keep it empty. (Value
# fields via the quick "Add field" button pass no name and already read
# "(unnamed)".)
describe "blank field name resolves to (unnamed)" do
    it "add_field_custom with an empty name yields (unnamed), not an empty string" do
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

        persistency.contexts.push(shape.context)
        before = persistency.get_field_lids(table_lid).to_set
        persistency.contexts.pop

        shape.add_field_custom("", nil) # the "..." dialog path (references + blank value fields)

        persistency.contexts.push(shape.context)
        new_fields = persistency.get_field_lids(table_lid).reject { |f| before.includes?(f) }
        new_fields.size.should eq(1), "expected exactly one new field"
        name = persistency.get_value(MetaFieldLIDs::Names, new_fields.first)
        persistency.contexts.pop

        name.should eq(Constant::Unnamed),
            "a field created with a blank name must read #{Constant::Unnamed}, not empty (got #{name.inspect})"
    end
end
