require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Reproduces the user's scenario: load demo-style data, press Commit! with
# one table deferred. Afterwards open a Shape on the deferred table and
# verify the fields are visible.

describe "Commit with deferred table" do
    it "deferred table keeps its field after float_writes (simple case)" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Projects
            Project
            Arts
            Law

            Times
            Time
            Former
            Future
            Present
        EOT
        times_lid = hash["Times"].as(TableLID)
        time_field = hash["Time"].as(FieldLID)

        # Commit with Times deferred
        closing = persistency.context.current_commit
        persistency.close_and_add_commit
        new_open = persistency.context.current_commit
        persistency.float_writes(from: closing, to: new_open, defer_tables: Set{times_lid})

        persistency.context.current_commit = new_open
        persistency.get_value(MetaFieldLIDs::Names, time_field).should eq("Time")
        persistency.get_value(MetaFieldLIDs::BelongsTo, time_field).should eq(times_lid)
        last_field = persistency.get_value(MetaFieldLIDs::TableLastField, times_lid)
        last_field.should eq(time_field)
        field_lids = persistency.get_field_lids(times_lid)
        field_lids.should contain(time_field)
    end

    it "deferred table keeps its field with full demo data (references + aggregations)" do
        # Mirror the actual embrace demo in src/gui/embrace_file_ops.cr
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Cities
            City | Country
            Arizona | USA
            Boston | USA

            Times
            Time
            Former
            Future
            Present

            Projects
            Project
            Arts
            Autonomy

            Persons
            Person | City_City
            Alan | Boston
            Jared | Arizona

            Allocations
            Person_Person | Time_Time | Project_Project | Allocation
            Alan | Present | Arts | 100
            Jared | Future | Autonomy | 100
        EOT
        times_lid = hash["Times"].as(TableLID)
        time_field = hash["Time"].as(FieldLID)

        closing = persistency.context.current_commit
        persistency.close_and_add_commit
        new_open = persistency.context.current_commit
        persistency.float_writes(from: closing, to: new_open, defer_tables: Set{times_lid})

        context = persistency.context.clone
        shape = ShapeState.new("Times", persistency, context, times_lid)

        fl = shape.fieldlist.not_nil!
        _ = fl.size
        fl_row_names = (0...fl.size[0]).map { |ri|
            fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Name.value]]
        }
        fl_row_names.should contain("Time"),
            "after float_writes on Times, Shape's fieldlist lost Time; got: #{fl_row_names.inspect}"
    end

    it "deferred table keeps its field when Shape exists BEFORE commit (real GUI order)" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Projects
            Project
            Arts

            Times
            Time
            Former
            Future
            Present
        EOT
        times_lid = hash["Times"].as(TableLID)
        time_field = hash["Time"].as(FieldLID)

        # STEP 1: create the Shape pre-commit (as EmbraceApp does on demo load).
        # This is key: Configurator is constructed at the pre-commit version.
        context = persistency.context.clone
        shape = ShapeState.new("Shape", persistency, context, times_lid)

        # STEP 2: commit with Times deferred
        shape.do_commit(Set{times_lid})

        # STEP 3: Shape's fieldlist should STILL list the Time field.
        # This is the "Times lost its field" bug: app's global context stays at
        # the pre-commit commit, but the shape's context advanced — so
        # Configurator reads at app context (missing Times' fields) and drops
        # Time from the tree. Fix: Configurator pinned to shape.context.
        fl = shape.fieldlist.not_nil!
        _ = fl.size
        fl_row_names = (0...fl.size[0]).map { |ri|
            fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Name.value]]
        }
        fl_row_names.should contain("Time"),
            "pre-existing Shape on Times lost its Time field after Commit! with Times deferred; got: #{fl_row_names.inspect}"
    end

    it "deferred table keeps its field when opened in a Shape (GUI-path)" do
        # Mirror the user's flow exactly: load demo-like data then defer a table
        # that was defined AFTER another table had records with references pointing
        # elsewhere. Open a new Shape on the deferred table (like the "→ Shape"
        # button would). Confirm the field is in the Configurator tree.
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID | TableLID | RecordLID).new
        help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Projects
            Project
            Arts
            Law

            Times
            Time
            Former
            Future
            Present
        EOT
        times_lid = hash["Times"].as(TableLID)
        time_field = hash["Time"].as(FieldLID)

        closing = persistency.context.current_commit
        persistency.close_and_add_commit
        new_open = persistency.context.current_commit
        persistency.float_writes(from: closing, to: new_open, defer_tables: Set{times_lid})

        # Open a Shape on Times
        context = persistency.context.clone
        shape = ShapeState.new("Times", persistency, context, times_lid)

        # The shape's Configurator/fieldlist/adapter should know about Time_FieldLID
        shape.matrix_adapter.should_not be_nil
        shape.fieldlist.should_not be_nil
        fl = shape.fieldlist.not_nil!
        _ = fl.size  # trigger sync
        fl_row_names = (0...fl.size[0]).map { |ri|
            fl[[ri, Table::Lazy::Fieldlist::ColumnIndices::Name.value]]
        }
        fl_row_names.should contain("Time"),
            "Shape on deferred Times should list 'Time' field in fieldlist, got: #{fl_row_names.inspect}"
    end
end
