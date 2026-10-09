require "spec"
require "./spec_helper"
require "../src/persistency"
require "../src/virtualtable"
require "../src/debug-helper"
require "../src/gui/tablefieldpicker"

include Persistency

# A table reads and writes the context it is bound to - its Configurator's - whatever context is on top of the stack;
# and the caches that read metadata only key on metadata.

private def document : {Persistency::Default, Hash(String, FieldLID | TableLID | RecordLID)}
    p = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << "T\nA | B\na1 | b1\na2 | b2\n"
    {p, hash}
end

private def table(p, hash, context : Context) : {Table::VirtualTable::Configurator(Cell, BaseCell), Table::VirtualTable::VirtualTable(Cell, BaseCell)}
    c = Table::VirtualTable::Configurator(Cell, BaseCell).new(p, hash["T"].as(TableLID), context)
    c.toggle_select(c.tree)
    {c, c.run}
end

private def column(vt, name) : Int32
    (0...vt.size[1]).find! { |ci| vt.hyperplane_get_name(1, [0, ci]) == name }
end

describe "opening a commit" do
    it "raises meta_version: it writes the commit graph, a meta cell" do
        p, _ = document
        before = p.meta_version
        p.close_and_add_commit
        p.meta_version.should be > before
    end
end

# A guard for the fix: it fails if a re-pin does not move the table's gate.
describe "re-pinning a Configurator" do
    it "moves its table's gate, also onto a context whose version happens to be equal" do
        p, hash = document
        one = p.context.current_commit
        p.close_and_add_commit
        p.set_value(p.get_field_lids(hash["T"].as(TableLID))[0], p.get_record_lids(hash["T"].as(TableLID))[0], "two")
        two = p.context.current_commit
        at_one = p.context.clone; at_one.current_commit = one # each context's version: 1
        at_two = p.context.clone; at_two.current_commit = two
        at_one.version.should eq(at_two.version) # control: a version alone cannot tell them apart
        c, vt = table(p, hash, at_one)
        a = column(vt, "A")
        vt[[0, a]].should eq("a1") # control: bound to commit one
        c.context = at_two
        vt[[0, a]].should eq("two")
    end

    it "moves its table's gate onto a context whose version is lower by one (the sum a bare +1 would recreate)" do
        p, hash = document
        one = p.context.current_commit
        p.close_and_add_commit
        p.set_value(p.get_field_lids(hash["T"].as(TableLID))[0], p.get_record_lids(hash["T"].as(TableLID))[0], "two")
        at_one = p.context.clone; at_one.current_commit = one # version 1
        at_two = p.context.clone                              # version 0
        c, vt = table(p, hash, at_one)
        a = column(vt, "A")
        vt[[0, a]].should eq("a1") # control: bound to commit one
        c.context = at_two
        vt[[0, a]].should eq("two")
    end
end

# The table's own-context switch must ENCLOSE hyperplane_add's transaction: inside it, the transaction would roll back
# the position of whatever context is on top of the stack, not the one the commit was opened in.
describe "a refused record add on a table bound to another context than the stack's top" do
    it "takes back the commit it opened in the table's own context" do
        p, hash = document
        own = p.context.clone # the table's context - not the one on top of the stack
        old = own.current_commit
        p.with_context(own) { p.close_and_add_commit } # `old` is closed now ...
        own.current_commit = old                         # ... and own sits on it: a write there opens a commit
        position = {own.current_commit, own.metadata_commit}
        _, vt = table(p, hash, own)
        rank = (0...vt.size[1]).find! { |ci| vt.hyperplane_is_rank(1, [0, ci]) }
        depth = p.contexts.size
        expect_raises(ConditionsNotMet, /ranks can only be assigned to integer values/) do
            vt.hyperplane_add(0, [0, rank], clusters: {rank => "not a rank".as(Cell)})
        end
        {own.current_commit, own.metadata_commit}.should eq(position)
        p.contexts.size.should eq(depth)
    end
end

describe "the field picker" do
    it "rebuilds its list on a metadata change and not on a data write" do
        p, hash = document
        table = hash["T"].as(TableLID)
        picker = GUI::Widget::FieldPicker.new(p, p.context, table)
        picker.names # built
        before = GUI::Widget::FieldPicker.rebuild_count
        p.set_value(p.get_field_lids(table)[0], p.get_record_lids(table)[0], "data")
        picker.names
        GUI::Widget::FieldPicker.rebuild_count.should eq(before) # a cell write: nothing it lists
        p.add_field(table, "C")
        picker.names.should contain("C")
        GUI::Widget::FieldPicker.rebuild_count.should eq(before + 1)
    end
end

class Table::VirtualTable::VirtualTable(T, U)
    def pinned_spec_batch(& : ->) : Index? # multiassign_begin / _end are protected: a pivot is the only caller
        multiassign_begin
        yield
        multiassign_end
    end
end

# The table bound to `own`, while the document's base context - on another commit - stays on top of the stack.
private def bound_elsewhere : {Persistency::Default, Hash(String, FieldLID | TableLID | RecordLID), Context, Table::VirtualTable::VirtualTable(Cell, BaseCell)}
    p, hash = document
    own = p.context.clone
    p.close_and_add_commit # the base context moves on; `own` stays on the commit behind it
    _, vt = table(p, hash, own)
    {p, hash, own, vt}
end

private def at(p, ctx, hash, record_index) : Cell
    t = hash["T"].as(TableLID)
    p.with_context(ctx) { p.get_value(p.get_field_lids(t)[0], p.get_record_lids(t)[record_index]) }
end

describe "a table's writes land in its own context, whatever context is on top of the stack" do
    it "a cell written" do
        p, hash, own, vt = bound_elsewhere
        vt[[0, column(vt, "A")]] = "mine".as(Cell)
        at(p, own, hash, 0).should eq("mine")
        at(p, p.context, hash, 0).should eq("a1")
    end

    it "a cell written in a multiassign" do
        p, hash, own, vt = bound_elsewhere
        vt.pinned_spec_batch { vt[[0, column(vt, "A")]] = "mine".as(Cell) }
        at(p, own, hash, 0).should eq("mine")
        at(p, p.context, hash, 0).should eq("a1")
    end

    it "a record added" do
        p, hash, own, vt = bound_elsewhere
        t = hash["T"].as(TableLID)
        vt.hyperplane_add(0)
        p.with_context(own) { p.get_record_lids(t).size }.should eq(3)
        p.get_record_lids(t).size.should eq(2)
    end

    it "a record removed" do
        p, hash, own, vt = bound_elsewhere
        t = hash["T"].as(TableLID)
        vt.hyperplane_remove(0, [0, column(vt, "A")])
        p.with_context(own) { p.get_record_lids(t).size }.should eq(1)
        p.get_record_lids(t).size.should eq(2)
    end
end

describe "a table's version" do
    it "follows its own context's moves, not those of the context on top of the stack" do
        p, _, own, vt = bound_elsewhere
        before = vt.version
        p.context.current_commit = p.context.current_commit # the top moves
        vt.version.should eq(before)
        own.current_commit = own.current_commit # control: its own context moves
        vt.version.should_not eq(before)
    end
end

# People live in cities; the table shows each person's city's region - a plain field, which a constraint on it reads
# from the store.
private def referencing : {Persistency::Default, Hash(String, FieldLID | TableLID | RecordLID)}
    p = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << <<-EOT
        cities
        city   | region
        Mordor | East
        Shire  | West
        Boston | Oversea

        persons
        name    | livesin_city
        Sauron  | Mordor
        Alan    | Boston
        EOT
    {p, hash}
end

# The persons table bound to `own`, on a commit of its own where Boston lies East too; the document's base context -
# where it does not - stays on top of the stack.
private def referencing_elsewhere : {Persistency::Default, Hash(String, FieldLID | TableLID | RecordLID), Context, Table::VirtualTable::VirtualTable(Cell, BaseCell)}
    p, hash = referencing
    own = p.context.clone
    p.close_and_add_commit # the base context moves on; `own` stays behind, and a write there branches off
    cities = hash["cities"].as(TableLID)
    p.with_context(own) { p.set_value(hash["region"].as(FieldLID), p.get_record_lids(cities)[2], "East") }
    c = Table::VirtualTable::Configurator(Cell, BaseCell).new(p, hash["persons"].as(TableLID), own)
    c.toggle_expand(c.tree[hash["livesin"]])
    c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
    c.toggle_select(c.tree)
    c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["region"]])
    {p, hash, own, c.run}
end

describe "a reference cell of a table bound to another context than the stack's top" do
    it "lists the records its own context's values fulfil" do
        _, _, _, vt = referencing_elsewhere
        vt[[1, 3]].should eq("East") # control: the region column, read in the table's own context
        cell = vt[[0, 2]].as(ReferenceCell(BaseCell))
        cell.constrain({3 => 1}) # Mordor's region, East: Mordor and - in the table's own context - Boston
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor Boston))
    end

    it "renames the record it points to in its own context" do
        p, hash, own, vt = referencing_elsewhere
        vt[[0, 2]].as(ReferenceCell(BaseCell)).value = "Barad-dur"
        city = hash["city"].as(FieldLID)
        mordor = p.get_record_lids(hash["cities"].as(TableLID))[0]
        p.with_context(own) { p.get_value(city, mordor) }.should eq("Barad-dur")
        p.get_value(city, mordor).should eq("Mordor")
    end
end
