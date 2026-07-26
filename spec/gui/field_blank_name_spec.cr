require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Blank names: storage keeps the TRUTH (a field created or renamed with an empty name stores ""),
# and the DISPLAY layer shows "(unnamed)" — from one owner (Persistency#display_name, applied in
# the configurator's name derivation which feeds the fieldlist / tree / pivot headers).
#
# CONTRACT MIGRATION (deliberate, 2026-07): the original T-018 fix normalized at WRITE time
# (add_field stored the literal "(unnamed)"), which polluted storage (a deliberately-so-named
# field became indistinguishable) and leaked blanks through every OTHER write path (rename,
# table-create). This spec now asserts the read-time contract instead: truthful storage +
# consistent display.

private CI_NAME = GUI::Widget::FieldlistConstants::ColumnIndices::Name

private def make_shape : {ShapeState, Persistency::Default, TableLID}
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Persons
        Name
        Wanda
    EOT
    table_lid = hash["Persons"].as(TableLID)
    shape = ShapeState.new("Persons", persistency, persistency.context.clone, table_lid)
    {shape, persistency, table_lid}
end

private def fieldlist_names(shape : ShapeState) : Array(String)
    fla = shape.fieldlist_adapter.not_nil!
    (0...fla.size).map { |i| fla.cell_read({i, CI_NAME}).as(String) }
end

describe "blank names: truthful storage, (unnamed) display" do
    it "a field created with an empty name stores the truth and displays (unnamed)" do
        shape, persistency, table_lid = make_shape

        persistency.contexts.push(shape.context)
        before = persistency.get_field_lids(table_lid).to_set
        persistency.contexts.pop

        shape.add_field_custom("", nil) # the "..." dialog path (references + blank value fields)

        persistency.contexts.push(shape.context)
        new_fields = persistency.get_field_lids(table_lid).reject { |f| before.includes?(f) }
        new_fields.size.should eq(1), "expected exactly one new field"
        stored = persistency.get_value(MetaFieldLIDs::Names, new_fields.first)
        displayed = persistency.display_name(new_fields.first)
        persistency.contexts.pop

        stored.should eq(""), "storage must keep the truth (got #{stored.inspect})"
        displayed.should eq(Constant::Unnamed)
        # ... and the fieldlist (fed by the configurator's name derivation) shows the placeholder
        shape.update(true)
        fieldlist_names(shape).should contain(Constant::Unnamed)
    end

    it "a field RENAMED to empty displays (unnamed) in the fieldlist (not a blank chip)" do
        shape, persistency, _ = make_shape
        shape.update(true)
        names_before = fieldlist_names(shape)
        names_before.should contain("Name") # sanity

        persistency.contexts.push(shape.context)
        persistency.set_value(MetaFieldLIDs::Names, persistency.get_field_lids(shape.table_lid.not_nil!).first, "")
        shape.context = persistency.contexts.pop
        shape.update(true)

        names = fieldlist_names(shape)
        names.should_not contain(""), "a blank name must not render as an empty chip"
        names.should contain(Constant::Unnamed)
    end

    it "a table renamed to empty titles the shape (unnamed)" do
        shape, persistency, table_lid = make_shape
        persistency.contexts.push(shape.context)
        persistency.set_value(MetaFieldLIDs::Names, table_lid, "")
        shape.context = persistency.contexts.pop
        shape.table_name.should eq(Constant::Unnamed)
    end
end
