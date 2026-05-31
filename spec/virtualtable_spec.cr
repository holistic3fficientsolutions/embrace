require "spec"
require "../spec/spec_helper"
require "../src/global"
require "../src/virtualtable"

include Table::VirtualTable

private def ref2rankvalue(arg)
    arg.map do |row|
        row.map {|el| el.is_a?(ReferenceCell(BaseCell)) ? el.rank.to_s+"-"+el.value.to_s : el}
    end
end

describe VirtualTable do
    it "checking whole table selection and checking dereferencing" do
        l = Persistency::Default.new
        table = l.add_table("mytable")
        person = l.add_field(table, "person")
        father = l.add_field(table, "father", person)
        mother = l.add_field(table, "mother", person)
        year = l.add_field(table, "year")
        rec1 = l.add_record(table)
        l.set_value(person, rec1, "Anton")
        rec2 = l.add_record(table)
        l.set_value(person, rec2, "Berta")
        l.set_value(mother, rec1, rec2) # mother of Anton is Berta
        c = Configurator(Cell,BaseCell).new(l, table)
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 +"}, {1, "  father ◄0,►1 +"}, {1, "  mother ◄0,►1 +"}, {1, "  year"}])
        c.toggle_select(c.tree) # select whole table
        t = c.run
        ref2rankvalue(t.to_a2).should eq([[1, "Anton", "0-(no reference)", "2-Berta", nil], [2, "Berta", "0-(no reference)", "0-(no reference)", nil]]) # checking also dereferencing of references
        c.toggle_select(c.tree) # de-select whole table
        t = c.run
        t.to_a.should eq([] of Cell)
    end
    it "works" do
        l = Persistency::Default.new
        table = l.add_table("mytable")
        person = l.add_field(table, "person")
        mother = l.add_field(table, "mother", person)
        father = l.add_field(table, "father", person)
        year = l.add_field(table, "year")
        c = Configurator(Cell,BaseCell).new(l, table)
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 +"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])
        c.toggle_expand(c.tree[person])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable +"}, {3, "◄ father"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])

        c.toggle_expand(c.tree[person][father][father]) # nothing should change
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable +"}, {3, "◄ father"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])

        c.toggle_expand(c.tree[year]) # nothing should change
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable +"}, {3, "◄ father"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])

        c.toggle_expand(c.tree[person][father])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable -"}, {3, "  (Show all records?)"}, {3, "  Rank"}, {3, "  person ◄2,►0 +"}, {3, "  mother ◄0,►1 +"}, {3, "◄ father ◄0,►1 +"}, {3, "  year"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])
        c.toggle_expand(c.tree[person][father])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable +"}, {3, "◄ father"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])
        c.toggle_expand(c.tree[person][father])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable -"}, {3, "  (Show all records?)"}, {3, "  Rank"}, {3, "  person ◄2,►0 +"}, {3, "  mother ◄0,►1 +"}, {3, "◄ father ◄0,►1 +"}, {3, "  year"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])
        c.toggle_expand(c.tree[person][father][person])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable -"}, {3, "  (Show all records?)"}, {3, "  Rank"}, {3, "  person ◄2,►0 -"}, {4, "  mytable +"}, {5, "◄ mother"}, {4, "  mytable +"}, {5, "◄ father"}, {3, "  mother ◄0,►1 +"}, {3, "◄ father ◄0,►1 +"}, {3, "  year"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])
        c.toggle_expand(c.tree[mother])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 -"}, {2, "  mytable +"}, {3, "◄ mother"}, {2, "  mytable -"}, {3, "  (Show all records?)"}, {3, "  Rank"}, {3, "  person ◄2,►0 -"}, {4, "  mytable +"}, {5, "◄ mother"}, {4, "  mytable +"}, {5, "◄ father"}, {3, "  mother ◄0,►1 +"}, {3, "◄ father ◄0,►1 +"}, {3, "  year"}, {1, "  mother ◄0,►1 -"}, {2, "  mytable +"}, {3, "► person"}, {1, "  father ◄0,►1 +"}, {1, "  year"}])
    end
    it "works" do
        l = Persistency::Default.new
        table = l.add_table("mytable")
        person = l.add_field(table, "person")
        mother = l.add_field(table, "mother", person)
        father = l.add_field(table, "father", person)
        year = l.add_field(table, "year")
        rec1 = l.add_record(table)
        l.set_value(person, rec1, "Anton")
        rec2 = l.add_record(table)
        l.set_value(person, rec2, "Berta")
        l.set_value(father, rec2, rec1)
        c = Configurator(Cell,BaseCell).new(l, table)
        c.toggle_expand(c.tree[father])
        c.toggle_expand(c.tree[father][person])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 +"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 -"}, {2, "  mytable -"}, {3, "  (Show all records?)"}, {3, "  Rank"}, {3, "► person ◄2,►0 +"}, {3, "  mother ◄0,►1 +"}, {3, "  father ◄0,►1 +"}, {3, "  year"}, {1, "  year"}])
        c.toggle_select(c.tree[person])
        c.toggle_select(c.tree[father][person][person])
        # 1. check for only common elements in VT
        t = c.run
        t.size.should eq([1,2])
        t.to_a2.should eq([["Berta", "Anton"]])
        # 2. check for all VT records (do not suppress any records by those two selects)
        c.toggle_select(c.tree[PseudoFields::ShowAll])
        c.toggle_select(c.tree[father][person][PseudoFields::ShowAll])
        t = c.run
        t.size.should eq([3,2])
        t.to_a2.should eq([["Anton", NilRecord], ["Berta", "Anton"], [NilRecord, "Berta"]])
        (t[[0,0]] = "Antonia").should eq([0,0])
        t.to_a2.should eq([["Antonia", NilRecord], ["Berta", "Antonia"], [NilRecord, "Berta"]])
        c.toggle_select(c.tree[PseudoFields::Rank])
        t = c.run
        # Rank is newly selected → appended after existing columns (stable order)
        t.to_a2.should eq([["Antonia", NilRecord, 1], ["Berta", "Antonia", 2], [NilRecord, "Berta", NilRecord]])
        (t[[1,2]] = 1i64).should eq([0,2])
        t.to_a2.should eq([["Berta", "Antonia", 1], ["Antonia", NilRecord, 2], [NilRecord, "Berta", NilRecord]])
        expect_raises(ConditionsNotMet) do
            t[[0,2]] = "foo"  # Rank column (now at index 2) doesn't accept strings
        end

        l.add_field(table, "xx") # changing the meta data leads (a) to an update of the configurator...
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  person ◄2,►0 +"}, {1, "  mother ◄0,►1 +"}, {1, "  father ◄0,►1 -"}, {2, "  mytable -"}, {3, "  (Show all records?)"}, {3, "  Rank"}, {3, "► person ◄2,►0 +"}, {3, "  mother ◄0,►1 +"}, {3, "  father ◄0,►1 +"}, {3, "  year"}, {3, "  xx"}, {1, "  year"}, {1, "  xx"}])
        t.to_a2.should eq([["Berta", "Antonia", 1], ["Antonia", NilRecord, 2], [NilRecord, "Berta", NilRecord]]) # ... but (b) to no change of the selection status (stable column order)
    end
    it "works" do
        l = Persistency::Default.new

        # preparation
        table_a = l.add_table("table_a")
        table_b = l.add_table("table_b")
        table_c = l.add_table("table_c")
        table_z = l.add_table("table_z") # keeping all together / referencing tables a, b and c
        field_a = l.add_field(table_a, "a")
        field_b = l.add_field(table_b, "b")
        field_c = l.add_field(table_c, "c")
        field_za = l.add_field(table_z, "za", field_a)
        field_zb = l.add_field(table_z, "zb", field_b)
        field_zc = l.add_field(table_z, "zc", field_c)
        record_z1 = l.add_record(table_z)
        record_z2 = l.add_record(table_z)
        record_z3 = l.add_record(table_z)
        record_z4 = l.add_record(table_z)
        record_z5 = l.add_record(table_z)
        record_z6 = l.add_record(table_z)
        record_z7 = l.add_record(table_z)
        record_a1 = l.add_record(table_a)
        record_a2 = l.add_record(table_a)
        record_a3 = l.add_record(table_a)
        record_a4 = l.add_record(table_a)
        record_b1 = l.add_record(table_b)
        record_b2 = l.add_record(table_b)
        record_b3 = l.add_record(table_b)
        record_b4 = l.add_record(table_b)
        record_c1 = l.add_record(table_c)
        record_c2 = l.add_record(table_c)
        record_c3 = l.add_record(table_c)
        record_c4 = l.add_record(table_c)
        l.set_value(field_a, record_a1, 2i64)
        l.set_value(field_a, record_a2, 4i64)
        l.set_value(field_a, record_a3, 6i64)
        l.set_value(field_a, record_a4, 7i64)
        l.set_value(field_b, record_b1, 1i64)
        l.set_value(field_b, record_b2, 4i64)
        l.set_value(field_b, record_b3, 5i64)
        l.set_value(field_b, record_b4, 7i64)
        l.set_value(field_c, record_c1, 3i64)
        l.set_value(field_c, record_c2, 5i64)
        l.set_value(field_c, record_c3, 6i64)
        l.set_value(field_c, record_c4, 7i64)
        l.set_value(field_za, record_z2, record_a1)
        l.set_value(field_za, record_z4, record_a2)
        l.set_value(field_za, record_z6, record_a3)
        l.set_value(field_za, record_z7, record_a4)
        l.set_value(field_zb, record_z1, record_b1)
        l.set_value(field_zb, record_z4, record_b2)
        l.set_value(field_zb, record_z5, record_b3)
        l.set_value(field_zb, record_z7, record_b4)
        l.set_value(field_zc, record_z3, record_c1)
        l.set_value(field_zc, record_z5, record_c2)
        l.set_value(field_zc, record_z6, record_c3)
        l.set_value(field_zc, record_z7, record_c4)
        c = Configurator(Cell,BaseCell).new(l, table_z)
        c.toggle_select(c.tree[PseudoFields::Rank]) # we also query rank so that result is deterministic
        c.toggle_expand(c.tree[field_za])
        c.toggle_expand(c.tree[field_za][field_a])
        c.toggle_expand(c.tree[field_zb])
        c.toggle_expand(c.tree[field_zb][field_b])
        c.toggle_expand(c.tree[field_zc])
        c.toggle_expand(c.tree[field_zc][field_c])
        c.toggle_select(c.tree[field_za][field_a][field_a])
        c.toggle_select(c.tree[field_zb][field_b][field_b])
        c.toggle_select(c.tree[field_zc][field_c][field_c])

        # ShowAll case: -
        t = c.run
        t.to_a2.should eq([[7, 7, 7, 7]])

        c.toggle_select(c.tree[field_za][field_a][PseudoFields::ShowAll]) # toggle A
        # ShowAll case: A
        t = c.run
        t.to_a2.map(&.map {|el| el==NilRecord ? nil : el}).should eq([[2, 2, nil, nil], [4, 4, 4, nil], [6, 6, nil, 6], [7, 7, 7, 7]])

        c.toggle_select(c.tree[field_zb][field_b][PseudoFields::ShowAll]) # toggle B
        # ShowAll case: A, B
        t = c.run
        t.to_a2.map(&.map {|el| el==NilRecord ? nil : el}).should eq([[1, nil, 1, nil], [2, 2, nil, nil], [4, 4, 4, nil], [5, nil, 5, 5], [6, 6, nil, 6], [7, 7, 7, 7]])

        c.toggle_select(c.tree[field_za][field_a][PseudoFields::ShowAll]) # toggle A
        # ShowAll case: B
        t = c.run
        t.to_a2.map(&.map {|el| el==NilRecord ? nil : el}).should eq([[1, nil, 1, nil], [4, 4, 4, nil], [5, nil, 5, 5], [7, 7, 7, 7]])

        c.toggle_select(c.tree[field_zc][field_c][PseudoFields::ShowAll]) # toggle C
        # ShowAll case: B, C
        t = c.run
        t.to_a2.map(&.map {|el| el==NilRecord ? nil : el}).should eq([[1, nil, 1, nil], [3, nil, nil, 3], [4, 4, 4, nil], [5, nil, 5, 5], [6, 6, nil, 6], [7, 7, 7, 7]])

        c.toggle_select(c.tree[field_zb][field_b][PseudoFields::ShowAll]) # toggle B
        # ShowAll case: C
        t = c.run
        t.to_a2.map(&.map {|el| el==NilRecord ? nil : el}).should eq([[3, nil, nil, 3], [5, nil, 5, 5], [6, 6, nil, 6], [7, 7, 7, 7]])

        c.toggle_select(c.tree[field_za][field_a][PseudoFields::ShowAll]) # toggle A
        # ShowAll case: A, C
        t = c.run
        t.to_a2.map(&.map {|el| el==NilRecord ? nil : el}).should eq([[2, 2, nil, nil], [3, nil, nil, 3], [4, 4, 4, nil], [5, nil, 5, 5], [6, 6, nil, 6], [7, 7, 7, 7]])

        c.toggle_select(c.tree[field_zb][field_b][PseudoFields::ShowAll]) # toggle B
        # ShowAll case: A, B, C
        t = c.run
        t.to_a2.map(&.map {|el| el==NilRecord ? nil : el}).should eq([[1, nil, 1, nil], [2, 2, nil, nil], [3, nil, nil, 3], [4, 4, 4, nil], [5, nil, 5, 5], [6, 6, nil, 6], [7, 7, 7, 7]])
    end
    it "works" do
        # preparation
        l = Persistency::Default.new
        table1 = l.add_table("mytable1")
        table2 = l.add_table("mytable2")
        field2 = l.add_field(table2, "project")
        field1 = l.add_field(table1, "project", field2)
        record1 = l.add_record(table1)
        c = Configurator(Cell,BaseCell).new(l, table1)
        c.toggle_expand(c.tree[field1])
        c.toggle_expand(c.tree[field1][field2])
        c.toggle_select(c.tree[PseudoFields::ShowAll])
        c.toggle_select(c.tree) # select all in table1
        c.toggle_select(c.tree[field1][field2][PseudoFields::ShowAll])
        c.toggle_select(c.tree[field1][field2]) # select all in table2

        # now starting tests
        ref2rankvalue(c.run.to_a2).should eq([[1, "0-(no reference)", NilRecord, NilRecord]]) # table1 is not pointing anywhere

        record2 = l.add_record(table2)
        l.set_value(field1, record1, record2)
        ref2rankvalue(c.run.to_a2).should eq([[1, "1-", 1, nil]]) # the value in field2 is undefined (nil), but the record exists (rank==1)

        l.remove_record(table2, record2)
        ref2rankvalue(c.run.to_a2).should eq([[1, "0-(no reference)", NilRecord, NilRecord]]) # now also the record is gone -> rank==nil
        l.get_value(field2, record2).should eq(nil) # only VirtualTable actually distinguishes between nil and NilRecord
        # this can happen later in distributed setups with user access rights (-> orphaned references)
    end
    it "simple VT operations work" do
        # preparation
        l = Persistency::Default.new
        table = l.add_table("mytable")
        field1 = l.add_field(table, "field1")
        field2 = l.add_field(table, "field2")
        record = l.add_record(table)
        c = Configurator(Cell,BaseCell).new(l, table)
        c.toggle_select(c.tree)
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  field1"}, {1, "  field2"}])
        vt = c.run
        vt.to_a.should eq([1, nil, nil])
        res = vt.hyperplane_add(1, [0,0]) # doesn't matter 0, 1 or 2
        res.should eq ([0,3])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  field1"}, {1, "  field2"}, {1, "  (unnamed)"}])
        vt.to_a.should eq([1, nil, nil, nil])

        res = vt.hyperplane_add(1, [0,0], name: "foobar", refers_to_field_lid: field2)
        res.should eq([0,4])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  field1"}, {1, "  field2 ◄1,►0 +"}, {1, "  (unnamed)"}, {1, "  foobar ◄0,►1 +"}])
        ref2rankvalue(vt.to_a2).should eq([[1, nil, nil, nil, "0-(no reference)"]])
        vt.hyperplane_remove(1, [0,4])

        vt.hyperplane_remove(1, [0,3])
        c.to_a.should eq([{0, "  mytable -"}, {1, "  (Show all records?)"}, {1, "  Rank"}, {1, "  field1"}, {1, "  field2"}])
        vt.to_a2.should eq([[1, nil, nil]])
        res = vt.hyperplane_add(0, [0,1])
        res.should eq([1,1])
        vt.to_a2.should eq([[1, nil, nil], [2, nil, nil]])
    end
    it "multi table VT operations work" do
        # preparation
        l = Persistency::Default.new
        table1 = l.add_table("mytable1")
        table2 = l.add_table("mytable2")
        field2 = l.add_field(table2, "project")
        field1 = l.add_field(table1, "project", field2)
        record1 = l.add_record(table1)
        c = Configurator(Cell,BaseCell).new(l, table1)
        c.toggle_expand(c.tree[field1])
        c.toggle_expand(c.tree[field1][field2])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[field1][field2])
        vt = c.run
        vt.size.should eq([0,4])
        vt.to_a.should eq([] of Cell)
        res = vt.hyperplane_add(0, [0,1])
        res.should eq([1,1])
        ref2rankvalue(vt.to_a2).should eq([[1, "0-(no reference)", NilRecord, NilRecord], [2, "0-(no reference)", NilRecord, NilRecord]]) # ShowAll has been switched on by #add_record
        vt.hyperplane_remove(0, [0,1])
        ref2rankvalue(vt.to_a2).should eq([[1, "0-(no reference)", NilRecord, NilRecord]])
    end
    it "constraining works" do
        # preparation DB layout
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            colors
            color
            Red
            Grey
            Brown
            Hazel
            Blue
            Silver

            countries
            country
            MiddleEarth
            USA

            cities
            city   | liesin_country
            Mordor | MiddleEarth
            Shire  | MiddleEarth
            Boston | USA

            persons
            name    | livesin_city | eyecolor_color
            Sauron  | Mordor       | Red
            Samwise | Shire        | Brown
            Alan    | Boston       | Blue
            Denny   | Boston       | Hazel
        EOT

        c = Configurator(Cell,BaseCell).new(l, hash["persons"])
        c.toggle_expand(c.tree[hash["livesin"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]][hash["country"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]][hash["country"]][PseudoFields::ShowAll])
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq ([
            [1, "Sauron" , "1-Mordor", "1-Red"  , "1-MiddleEarth"],
            [2, "Samwise", "2-Shire" , "3-Brown", "1-MiddleEarth"],
            [3, "Alan"   , "3-Boston", "5-Blue" , "2-USA"        ],
            [4, "Denny"  , "3-Boston", "4-Hazel", "2-USA"        ]])
        cell = vt[[0,2]].as(ReferenceCell(BaseCell))
        # at first no constraint
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor Shire Boston))

        cell.constrain({3 => 1}) # column 3, 1 is the rank of color "Red"
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor Shire Boston)) # no impact, since not in direct hierarchy

        cell.constrain({4 => 1}) # column 4, 1 is the rank of country "MiddleEarth"
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor Shire))

        cell.constrain({4 => 2}) # column 4, 2 is the rank of country "USA"
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Boston))
    end
    it "constraining works" do
        # preparation DB layout
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            countries
            country
            USA

            cities
            city    | liesin_country
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city
            Alan    | Boston
        EOT

        c = Configurator(Cell,BaseCell).new(l, hash["persons"])
        c.toggle_expand(c.tree[hash["livesin"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]][hash["country"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["city"]]) # for full enumeration flexibility we need both "cities"; for #hyperplane_move it's also better to have the full chain
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][PseudoFields::ShowAll])
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq([[1, "Alan", "1-Boston", "Boston", "1-USA"], [NilRecord, NilRecord, NilRecord, "Seattle", "1-USA"]])
    end
    it "empty table works" do
        # preparation DB layout; one field with one entry
        l = Persistency::Default.new
        table = l.add_table("mytable")
        l.add_field(table, "myfield") # a field, no record yet
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, table)
        # no field selected -> creates empty VT
        vt = c.run
        vt.size.should eq([0,0])
        vt.to_a2.should eq([] of Array(Cell))

        l.add_record(table) # now also with record, but still nothing selected in Configurator
        vt.size.should eq([1,0])
        vt.to_a2.should eq([] of Array(Cell))
    end
    it "empty table and extenting it works" do
        # preparation DB layout; one field with one entry
        l = Persistency::Default.new
        table = l.add_table("mytable")
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, table)
        # no field selected -> creates empty VT
        vt = c.run
        vt.size.should eq([0,0])
        vt.to_a2.should eq([] of Array(Cell))
        vt.hyperplane_add(1) # adding a field
        vt.size.should eq([0,1])
        vt.to_a2.should eq([] of Array(Cell))
        vt.hyperplane_add(0) # adding a record
        vt.size.should eq([1,1])
        vt.to_a2.should eq([[nil]])
    end
    it "testing inward references" do
        # preparation DB layout
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            years
            year
            y2024
            y2025

            costcenters
            costcenter
            SW
            SY
            EE

            costs
            cc1_costcenter | y1_year | hourlyrate
            SW             | y2024   | 100
            SW             | y2025   | 110
            SY             | y2024   | 80
            SY             | y2025   | 90
            EE             | y2024   | 85
            EE             | y2025   | 95

            quote
            cc2_costcenter | y2_year | amount
            SW             | y2024   | 10
            SW             | y2025   | 20
            SY             | y2024   | 30
            SY             | y2025   | 40
            EE             | y2025   | 50
        EOT
        query = {#offsets     5                  2                2                   5               5
            table_lids: [hash["quote"], hash["years"], hash["costcenters"], hash["costs"], hash["costs"]],
            field_lids: [[hash["cc2"],hash["y2"],hash["amount"]], [] of FieldLID, [] of FieldLID, [hash["cc1"],hash["y1"],hash["hourlyrate"]], [hash["cc1"],hash["y1"],hash["hourlyrate"]]],
            table_joins: [{3,0}, {2,0}, {7,2}, {5,3}],
            where_not_nil_columns: [0]
        }
        l.complex_query(query, true).should eq([
            #                               x                  x
            [25, 1, 8 , 4, 10, 4, 1, 8 , 1, 15, 1, 8 , 4, 100, 15, 1, 8 , 4, 100],
            [25, 1, 8 , 4, 10, 4, 1, 8 , 1, 15, 1, 8 , 4, 100, 17, 3, 9 , 4, 80 ],
            [25, 1, 8 , 4, 10, 4, 1, 8 , 1, 15, 1, 8 , 4, 100, 19, 5, 10, 4, 85 ],
            [25, 1, 8 , 4, 10, 4, 1, 8 , 1, 16, 2, 8 , 5, 110, 15, 1, 8 , 4, 100],
            [25, 1, 8 , 4, 10, 4, 1, 8 , 1, 16, 2, 8 , 5, 110, 17, 3, 9 , 4, 80 ],
            [25, 1, 8 , 4, 10, 4, 1, 8 , 1, 16, 2, 8 , 5, 110, 19, 5, 10, 4, 85 ],
            [26, 2, 8 , 5, 20, 5, 2, 8 , 1, 15, 1, 8 , 4, 100, 16, 2, 8 , 5, 110],
            [26, 2, 8 , 5, 20, 5, 2, 8 , 1, 15, 1, 8 , 4, 100, 18, 4, 9 , 5, 90 ],
            [26, 2, 8 , 5, 20, 5, 2, 8 , 1, 15, 1, 8 , 4, 100, 20, 6, 10, 5, 95 ],
            [26, 2, 8 , 5, 20, 5, 2, 8 , 1, 16, 2, 8 , 5, 110, 16, 2, 8 , 5, 110],
            [26, 2, 8 , 5, 20, 5, 2, 8 , 1, 16, 2, 8 , 5, 110, 18, 4, 9 , 5, 90 ],
            [26, 2, 8 , 5, 20, 5, 2, 8 , 1, 16, 2, 8 , 5, 110, 20, 6, 10, 5, 95 ],
            [27, 3, 9 , 4, 30, 4, 1, 9 , 2, 17, 3, 9 , 4, 80 , 15, 1, 8 , 4, 100],
            [27, 3, 9 , 4, 30, 4, 1, 9 , 2, 17, 3, 9 , 4, 80 , 17, 3, 9 , 4, 80 ],
            [27, 3, 9 , 4, 30, 4, 1, 9 , 2, 17, 3, 9 , 4, 80 , 19, 5, 10, 4, 85 ],
            [27, 3, 9 , 4, 30, 4, 1, 9 , 2, 18, 4, 9 , 5, 90 , 15, 1, 8 , 4, 100],
            [27, 3, 9 , 4, 30, 4, 1, 9 , 2, 18, 4, 9 , 5, 90 , 17, 3, 9 , 4, 80 ],
            [27, 3, 9 , 4, 30, 4, 1, 9 , 2, 18, 4, 9 , 5, 90 , 19, 5, 10, 4, 85 ],
            [28, 4, 9 , 5, 40, 5, 2, 9 , 2, 17, 3, 9 , 4, 80 , 16, 2, 8 , 5, 110],
            [28, 4, 9 , 5, 40, 5, 2, 9 , 2, 17, 3, 9 , 4, 80 , 18, 4, 9 , 5, 90 ],
            [28, 4, 9 , 5, 40, 5, 2, 9 , 2, 17, 3, 9 , 4, 80 , 20, 6, 10, 5, 95 ],
            [28, 4, 9 , 5, 40, 5, 2, 9 , 2, 18, 4, 9 , 5, 90 , 16, 2, 8 , 5, 110],
            [28, 4, 9 , 5, 40, 5, 2, 9 , 2, 18, 4, 9 , 5, 90 , 18, 4, 9 , 5, 90 ],
            [28, 4, 9 , 5, 40, 5, 2, 9 , 2, 18, 4, 9 , 5, 90 , 20, 6, 10, 5, 95 ],
            [29, 5, 10, 5, 50, 5, 2, 10, 3, 19, 5, 10, 4, 85 , 16, 2, 8 , 5, 110],
            [29, 5, 10, 5, 50, 5, 2, 10, 3, 19, 5, 10, 4, 85 , 18, 4, 9 , 5, 90 ],
            [29, 5, 10, 5, 50, 5, 2, 10, 3, 19, 5, 10, 4, 85 , 20, 6, 10, 5, 95 ],
            [29, 5, 10, 5, 50, 5, 2, 10, 3, 20, 6, 10, 5, 95 , 16, 2, 8 , 5, 110],
            [29, 5, 10, 5, 50, 5, 2, 10, 3, 20, 6, 10, 5, 95 , 18, 4, 9 , 5, 90 ],
            [29, 5, 10, 5, 50, 5, 2, 10, 3, 20, 6, 10, 5, 95 , 20, 6, 10, 5, 95 ]
        ])
        # this comment is meant to stay!
        # if we would filter only for equal record_lids in columns "x": this would be the desired result in case of two-field references:
        # [   #                               x                  x
        #     [25, 1, 8 , 4, 10, 4, 1, 8 , 1, 15, 1, 8 , 4, 100, 15, 1, 8 , 4, 100],
        #     [26, 2, 8 , 5, 20, 5, 2, 8 , 1, 16, 2, 8 , 5, 110, 16, 2, 8 , 5, 110],
        #     [27, 3, 9 , 4, 30, 4, 1, 9 , 2, 17, 3, 9 , 4, 80 , 17, 3, 9 , 4, 80 ],
        #     [28, 4, 9 , 5, 40, 5, 2, 9 , 2, 18, 4, 9 , 5, 90 , 18, 4, 9 , 5, 90 ],
        #     [29, 5, 10, 5, 50, 5, 2, 10, 3, 20, 6, 10, 5, 95 , 20, 6, 10, 5, 95 ]
        # ]

        # this comment is meant to stay!
        # be aware that "table_joins:" one column has to be the own table's RecordLID, the other a reference carrying the other tables RecordLIDs
        # the following doesn't work:
        # query = {#        6                  2                2                   5               5
        #     table_lids: [hash["quote"], hash["costs"]],
        #     field_lids: [[hash["cc2"],hash["y2"],hash["amount"]], [hash["cc1"],hash["y1"],hash["hourlyrate"]]],
        #     table_joins: [{2,2}], # wrong!
        #     where_not_nil_columns: [0]
        # }

        c = Configurator(Cell,BaseCell).new(l, hash["quote"])
        c.toggle_expand(c.tree[hash["cc2"]])
        c.toggle_expand(c.tree[hash["cc2"]][hash["costcenter"]])
        c.toggle_expand(c.tree[hash["cc2"]][hash["costcenter"]][hash["costcenter"]])
        c.toggle_expand(c.tree[hash["cc2"]][hash["costcenter"]][hash["costcenter"]][hash["cc1"]])
        c.toggle_expand(c.tree[hash["y2"]])
        c.toggle_expand(c.tree[hash["y2"]][hash["year"]])
        c.toggle_expand(c.tree[hash["y2"]][hash["year"]][hash["year"]])
        c.toggle_expand(c.tree[hash["y2"]][hash["year"]][hash["year"]][hash["y1"]])

        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["cc2"]][hash["costcenter"]][hash["costcenter"]][hash["cc1"]][hash["hourlyrate"]])
        c.toggle_select(c.tree[hash["y2"]][hash["year"]][hash["year"]][hash["y1"]][hash["hourlyrate"]])
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq([
            [1, "1-SW", "1-y2024", 10, 100, 100],
            [1, "1-SW", "1-y2024", 10, 100, 80 ],
            [1, "1-SW", "1-y2024", 10, 100, 85 ],
            [1, "1-SW", "1-y2024", 10, 110, 100],
            [1, "1-SW", "1-y2024", 10, 110, 80 ],
            [1, "1-SW", "1-y2024", 10, 110, 85 ],
            [2, "1-SW", "2-y2025", 20, 100, 110],
            [2, "1-SW", "2-y2025", 20, 100, 90 ],
            [2, "1-SW", "2-y2025", 20, 100, 95 ],
            [2, "1-SW", "2-y2025", 20, 110, 110],
            [2, "1-SW", "2-y2025", 20, 110, 90 ],
            [2, "1-SW", "2-y2025", 20, 110, 95 ],
            [3, "2-SY", "1-y2024", 30, 80, 100 ],
            [3, "2-SY", "1-y2024", 30, 80, 80  ],
            [3, "2-SY", "1-y2024", 30, 80, 85  ],
            [3, "2-SY", "1-y2024", 30, 90, 100 ],
            [3, "2-SY", "1-y2024", 30, 90, 80  ],
            [3, "2-SY", "1-y2024", 30, 90, 85  ],
            [4, "2-SY", "2-y2025", 40, 80, 110 ],
            [4, "2-SY", "2-y2025", 40, 80, 90  ],
            [4, "2-SY", "2-y2025", 40, 80, 95  ],
            [4, "2-SY", "2-y2025", 40, 90, 110 ],
            [4, "2-SY", "2-y2025", 40, 90, 90  ],
            [4, "2-SY", "2-y2025", 40, 90, 95  ],
            [5, "3-EE", "2-y2025", 50, 85, 110 ],
            [5, "3-EE", "2-y2025", 50, 85, 90  ],
            [5, "3-EE", "2-y2025", 50, 85, 95  ],
            [5, "3-EE", "2-y2025", 50, 95, 110 ],
            [5, "3-EE", "2-y2025", 50, 95, 90  ],
            [5, "3-EE", "2-y2025", 50, 95, 95  ]
        ])
    end
    it "references to references" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        expect_raises(Exception) do # we disallow references to references
            help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
            help << <<-EOT
                cities1
                city1
                Mordor
                Shire

                cities2
                city2_city1
                Mordor
                Shire

                persons
                name    | livesin_city2
                Sauron  | Mordor
            EOT
            # c = Configurator(Cell,BaseCell).new(l, hash["persons"])
            # c.toggle_select(c.tree)
            # vt = c.run
            # p ref2rankvalue(vt.to_a2)
        end
    end
    it "pure showalls must not shrink" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            cities
            city
            Mordor
            Shire

            persons
            name    | livesin_city
            Sauron  | nil
        EOT
        c = Configurator(Cell,BaseCell).new(l, hash["persons"])
        c.toggle_select(c.tree)
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq([[1, "Sauron", "0-(no reference)"]])
        c.toggle_expand(c.tree[hash["livesin"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][PseudoFields::ShowAll])
        ref2rankvalue(vt.to_a2).should eq([[1, "Sauron", "0-(no reference)"]]) # must be the same
    end
    it "further hyperplane_remove tests" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            countries
            country
            MiddleEarth
            USA
            Nowhere

            cities
            city | liesin_country
            Mordor | MiddleEarth
            Shire | MiddleEarth
            Boston | USA
            Seattle | USA
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["cities"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::ShowAll]) # needed for selective #hyperplane_remove
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_select(c.tree[hash["city"]])
        c.toggle_expand(c.tree[hash["liesin"]])
        c.toggle_select(c.tree[hash["liesin"]])
        c.toggle_expand(c.tree[hash["liesin"]][hash["country"]])
        c.toggle_select(c.tree[hash["liesin"]][hash["country"]][hash["country"]])
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq([
            [1, "Mordor" , "1-MiddleEarth", "MiddleEarth"],
            [2, "Shire"  , "1-MiddleEarth", "MiddleEarth"],
            [3, "Boston" , "2-USA"        , "USA"        ],
            [4, "Seattle", "2-USA"        , "USA"        ]
        ])
        vt.hyperplane_remove(0, [2,3])
        ref2rankvalue(vt.to_a2).should eq([
            [1, "Mordor" , "1-MiddleEarth"   , "MiddleEarth"],
            [2, "Shire"  , "1-MiddleEarth"   , "MiddleEarth"],
            [3, "Boston" , "0-(no reference)", NilRecord    ],
            [4, "Seattle", "0-(no reference)", NilRecord    ]
        ])
    end
end
