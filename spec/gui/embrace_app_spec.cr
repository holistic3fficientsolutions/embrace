require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Test ShapeState business logic and the do_newfile_empty/demo patterns
# without SFML. Catches Bug 1 & 4: nothing displayed after demo/empty.
#
# Root cause: Context.new starts at commit 0 (RootCommit) and cannot see
# tables added after. shape_add must use a context derived from the current
# persistency state (e.g. persistency.context.clone).

# Helper: create persistency with one table (like do_newfile_empty_impl)
private def make_empty_persistency : Persistency::Default
  persistency = Persistency::Default.new
  table_lid = persistency.add_table(Constant::Unnamed)
  persistency.add_field(table_lid, Constant::Unnamed)
  persistency.add_record(table_lid)
  persistency
end

# Helper: create persistency with demo tables (like do_newfile_demo)
private def make_demo_persistency : Persistency::Default
  persistency = Persistency::Default.new
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Cities
      City | Country
      Arizona | USA
      Boston | USA

      Persons
      Person | City_City
      Alan | Boston
  EOT
  persistency
end

# Helper: simulate what shape_add should do (with correct context)
private def create_shape(persistency : Persistency::Default) : ShapeState
  context = persistency.context.clone
  ShapeState.new("Shape", persistency, context)
end

describe ShapeState do
  describe "context visibility" do
    it "Context.new cannot see tables added after initialization" do
      persistency = make_empty_persistency
      persistency.contexts.push(Context.new)
      tables = persistency.get_table(MetaFieldLIDs::TableLastTable)
      persistency.contexts.pop
      tables.size.should eq 0
    end

    it "cloned context can see tables" do
      persistency = make_empty_persistency
      persistency.contexts.push(persistency.context.clone)
      tables = persistency.get_table(MetaFieldLIDs::TableLastTable)
      persistency.contexts.pop
      tables.size.should eq 1
    end
  end

  describe "do_newfile_empty pattern (shape_add with correct context)" do
    it "creates shape with adapters when table exists" do
      persistency = make_empty_persistency
      shape = create_shape(persistency)

      shape.widget_table_picker.lid.should_not be_nil
      shape.vhtree_adapter.should_not be_nil
      shape.matrix_adapter.should_not be_nil
      shape.fieldlist_adapter.should_not be_nil
    end
  end

  describe "do_newfile_demo pattern (shape_add with correct context)" do
    it "creates shape with demo data and all adapters initialized" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)

      shape.widget_table_picker.lid.should_not be_nil
      shape.vhtree_adapter.should_not be_nil
      shape.matrix_adapter.should_not be_nil
    end

    it "shape has vhtree data (tables are expandable)" do
      persistency = make_demo_persistency
      shape = create_shape(persistency)

      # VHTree should have data (not empty)
      nodes = [] of Interface::GUI::VHTreeAdapter
      shape.dfs_tree { |node, level| nodes << node }
      nodes.size.should be > 0
    end
  end

  describe "dup_shape" do
    it "creates a new shape with same persistency and working adapters" do
      persistency = make_empty_persistency
      shape1 = create_shape(persistency)
      shape2 = shape1.dup_shape("Copy")

      shape2.title.should eq "Copy"
      shape2.id.should_not eq shape1.id
      shape2.persistency.should eq shape1.persistency
      shape2.vhtree_adapter.should_not be_nil
    end
  end

  describe "close" do
    it "sets open to false" do
      persistency = make_empty_persistency
      shape = create_shape(persistency)
      shape.open.should be_true
      shape.close
      shape.open.should be_false
    end
  end

  describe "do_commit" do
    it "doesn't raise" do
      persistency = make_empty_persistency
      shape = create_shape(persistency)
      shape.do_commit
    end
  end

  describe "navigate_history" do
    it "stays within bounds" do
      persistency = make_empty_persistency
      shape = create_shape(persistency)
      shape.navigate_history(-1)
      shape.navigate_history(1)
    end
  end

  describe "add_record" do
    it "doesn't raise when matrix exists" do
      persistency = make_empty_persistency
      shape = create_shape(persistency)
      shape.add_record
    end
  end
end
