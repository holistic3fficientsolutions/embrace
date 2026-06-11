require "crexcel"
require "xlsx-parser"
require "spec"
require "../src/global"
require "../src/persistency"
require "../spec/spec_helper"

include Persistency # to use FieldLID

module SpecHelpers::PersistencyHelper # if we name it SpecHelper::Persistency we get compilation errors in another module / name conflicts with ::Persistency
    def self.singularity_query(l, hash)
        res = l.complex_query({table_lids: [hash["persons"], hash["colors"]], field_lids: [[hash["name"],hash["eyecolor"]], [hash["color"]]], table_joins: [{3,0}], where_not_nil_columns: [] of Int32}, true)
        res.map {|row| [1,2,5,6].map {|i| row[i]} } # keep rank,value,rank,value
    end
end

describe Persistency::Default do
    it "singularities work" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            colors
            color
            Red
            Brown

            persons
            name    | eyecolor_color
            Sauron  | Red
            Samwise | Brown
        EOT
        # normal test
        SpecHelpers::PersistencyHelper.singularity_query(l, hash).should eq([[1, "Sauron", 1  , "Red"], [2, "Samwise", 2  , "Brown"]])
        # singularity #1: removed referenced record
        l.get_value(hash["color"], hash["Red"]).should eq("Red") # field,record -> value
        l.remove_record(hash["colors"], hash["Red"])
        l.get_value(hash["color"], hash["Red"]).should eq("Red") # field,record -> value; still there, only record removed from table linked list; in general, this also needs to be like this (with later access right restrictions)
        SpecHelpers::PersistencyHelper.singularity_query(l, hash).should eq([[1, "Sauron", nil, nil  ], [2, "Samwise", 1  , "Brown"]])
        # singularity #2: removed referenced field, but somewhere the field_lid is still stored (i.e. referencing field)
        l.remove_field(hash["colors"], hash["color"])
        SpecHelpers::PersistencyHelper.singularity_query(l, hash).should eq([[1, "Sauron", nil, nil  ], [2, "Samwise", 1  , nil    ]])
        # singularity #3: removed referenced table: on Perstistency this can only happen when a table_lid is given, which is not valid anymore
        # (since nil as a table_lid is not allowed on the API; hence this case needs to be covered by VT)
        l.remove_table(hash["colors"])
        SpecHelpers::PersistencyHelper.singularity_query(l, hash).should eq([[1, "Sauron", nil, nil  ], [2, "Samwise", nil, nil    ]])
    end
    it "works" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            cities
            city    | liesin
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city
            Horst   | Mordor
        EOT
        res = l.complex_query({table_lids: [hash["persons"], hash["cities"]], field_lids: [[hash["name"],hash["livesin"]], [hash["city"],hash["liesin"]]], table_joins: [{3,0}], where_not_nil_columns: [] of Int32}, true)
        res[0][0].nil?.should be_false # we do have sth. on the left hand side
        l.remove_record(hash["persons"], res[0][0].as(RecordLID))
        res = l.complex_query({table_lids: [hash["persons"], hash["cities"]], field_lids: [[hash["name"],hash["livesin"]], [hash["city"],hash["liesin"]]], table_joins: [{3,0}], where_not_nil_columns: [] of Int32}, true)
        res[0][0].should eq(nil) # now left hand side is empty
    end
    it "move_records re-homes records and re-keys into matching fields" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            foo
            a   | b
            a1  | b1
            a2  | b2
            a3  | b3
        EOT
        foo   = hash["foo"].as(TableLID)
        foo_a = hash["a"].as(FieldLID)
        # a structure-matching target (two value fields), built as the UX/test layer would
        bar   = l.add_table("bar")
        bar_a = l.add_field(bar, "a")
        l.add_field(bar, "b")
        r1, r2, r3 = l.get_record_lids(foo)
        # move the MIDDLE record, then the (new) tail — exercises source tail-repair + growing target tail
        l.move_records([r2], foo, bar)
        l.get_record_lids(foo).should eq([r1, r3])
        l.get_record_lids(bar).should eq([r2])
        l.move_records([r3], foo, bar)
        l.get_record_lids(foo).should eq([r1])
        l.get_record_lids(bar).should eq([r2, r3])
        # re-key: value lands on the target field once, source cell cleared (no redundancy)
        l.get_value(bar_a, r2).should eq("a2")
        l.get_value(foo_a, r2).should eq(nil)
        # re-home: BelongsTo follows the record
        l.get_table_lid(r2).should eq(bar)
    end
    it "move_records is its own inverse (out then back, incl. save/load)" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            foo
            a   | b
            a1  | b1
            a2  | b2
            a3  | b3
        EOT
        foo = hash["foo"].as(TableLID)
        bar = l.add_table("bar")
        l.add_field(bar, "a"); l.add_field(bar, "b")
        records = l.get_record_lids(foo)
        before  = l.get_table(foo)
        l.move_records(records, foo, bar)                       # all out
        l.get_record_lids(foo).should eq([] of RecordLID)       # source emptied
        l.get_table(bar).map(&.[2..]).should eq(before.map(&.[2..]))  # the values are now in bar
        l.move_records(records, bar, foo)                       # all back, same order
        l.get_record_lids(bar).should eq([] of RecordLID)       # target emptied
        l.get_record_lids(foo).should eq(records)               # chain restored, original order
        l.get_table(foo).should eq(before)                      # ranks + values restored
        commit = l.context.current_commit
        l.load(l.save)                                          # the move's nil/value chain writes serialize cleanly
        l.context.current_commit = commit                       # load resets to RootCommit; re-point at the data
        l.get_table(foo).should eq(before)
    end
    it "move_records preconditions raise ConditionsNotMet" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            foo
            a   | b
            a1  | b1
            a2  | b2

            otherfoo
            x   | y
            x1  | y1
        EOT
        foo   = hash["foo"].as(TableLID)
        other = hash["otherfoo"].as(TableLID)            # 2 value fields -> structurally matches foo
        r     = l.get_record_lids(foo)
        foreign = l.get_record_lids(other)[0]
        bar1  = l.add_table("bar1"); l.add_field(bar1, "a")            # 1 field -> count mismatch
        cityt = l.add_table("city"); cityf = l.add_field(cityt, "city")
        barref = l.add_table("barref")                                # 2 fields, but field 1 is a reference
        l.add_field(barref, "a", cityf); l.add_field(barref, "b")
        expect_raises(ConditionsNotMet, "Cannot move, no records given; ignoring command")                        { l.move_records([] of RecordLID, foo, bar1) }
        expect_raises(ConditionsNotMet, "Cannot move records into the same table; ignoring command")              { l.move_records(r, foo, foo) }
        expect_raises(ConditionsNotMet, "Cannot move, a record is not in the source table; ignoring command")     { l.move_records([foreign], foo, other) }
        expect_raises(ConditionsNotMet, "different field count")                                                  { l.move_records(r, foo, bar1) }
        expect_raises(ConditionsNotMet, "reference shape differs")                                                { l.move_records(r, foo, barref) }
    end
    it "dumping works" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            cities
            city    | liesin
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city
            Sauron  | Mordor
            Samwise | Shire
            Alan    | Boston
            Denny   | Boston
            Stale   | Boston
            Nil     | nil
        EOT
        x = TableWriter(Persistency::Default,Persistency::Cell).new(l).dump
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << x
        l.complex_query({table_lids: [hash["persons"], hash["cities"]], field_lids: [[hash["name"],hash["livesin"]], [hash["city"],hash["liesin"]]], table_joins: [{3,0}], where_not_nil_columns: [0,4]}, false).should eq( # LHS => RHS
        [[12 , 1 , "Sauron" , 5      , 5  , 1  , "Mordor" , "MiddleEarth"],
        [13 , 2  , "Samwise", 6      , 6  , 2  , "Shire"  , "MiddleEarth"],
        [14 , 3  , "Alan"   , 7      , 7  , 3  , "Boston" , "USA" ],
        [15 , 4  , "Denny"  , 7      , 7  , 3  , "Boston" , "USA" ],
        [16 , 5  , "Stale"  , 7      , 7  , 3  , "Boston" , "USA" ],
        [17 , 6  , "Nil"    , nil    , nil, nil, nil      , nil ],
        [nil, nil, nil      , nil    , 8  , 4  , "Seattle", "USA" ]])
    end
    it "works" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            cities
            city    | liesin
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city
            Sauron  | Mordor
            Samwise | Shire
            Alan    | Boston
            Denny   | Boston
            Stale   | Boston
            Nil     | nil
        EOT

        l.set_value(hash["livesin"], hash["Stale"], 1234i64)
        l.set_value(hash["livesin"], hash["Nil"], nil)

        l.complex_query({table_lids: [hash["persons"], hash["cities"]], field_lids: [[hash["name"],hash["livesin"]], [hash["city"],hash["liesin"]]], table_joins: [{3,0}], where_not_nil_columns: [0,4]}, false).should eq( # LHS => RHS
        [[12 , 1 , "Sauron" , 5      , 5  , 1  , "Mordor" , "MiddleEarth"],
        [13 , 2  , "Samwise", 6      , 6  , 2  , "Shire"  , "MiddleEarth"],
        [14 , 3  , "Alan"   , 7      , 7  , 3  , "Boston" , "USA" ],
        [15 , 4  , "Denny"  , 7      , 7  , 3  , "Boston" , "USA" ],
        [16 , 5  , "Stale"  , 1234i64, nil, nil, nil      , nil ],
        [17 , 6  , "Nil"    , nil    , nil, nil, nil      , nil ],
        [nil, nil, nil      , nil    , 8  , 4  , "Seattle", "USA" ]])

        l.complex_query({table_lids: [hash["cities"], hash["persons"]], field_lids: [[hash["city"],hash["liesin"]], [hash["name"],hash["livesin"]]], table_joins: [{0,3}], where_not_nil_columns: [0,4]}, false).should eq( # RHS => LHS
        [[5  , 1  , "Mordor" , "MiddleEarth", 12 , 1  , "Sauron" , 5],
        [6  , 2  , "Shire"  , "MiddleEarth", 13 , 2  , "Samwise", 6],
        [7  , 3  , "Boston" , "USA"        , 14 , 3  , "Alan"   , 7],
        [7  , 3  , "Boston" , "USA"        , 15 , 4  , "Denny"  , 7],
        [8  , 4  , "Seattle", "USA"        , nil, nil, nil      , nil],
        [nil, nil, nil      , nil          , 16 , 5  , "Stale"  , 1234i64],
        [nil, nil, nil      , nil          , 17 , 6  , "Nil"    , nil]])

        l.get_table(MetaFieldLIDs::TableLastTable).should eq([[hash["cities"], 1, "cities"], [hash["persons"], 2, "persons"]])
    end
    it "works" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            tab
            col
            some
            thing
            nil
        EOT
        query = {table_lids: [hash["tab"]], field_lids: [[hash["col"]]], table_joins: [] of {Int32,Int32}, where_not_nil_columns: [] of Int32}
        l.complex_query(query, false).size.should eq(3)
        l.complex_query(query, true).size.should eq(3)
        query[:where_not_nil_columns] << 2
        l.complex_query(query, false).size.should eq(2)
        l.complex_query(query, true).size.should eq(2)
    end
    it "testing move" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            tab
            col
            some
            thing
            nil
        EOT
        l.get_table(hash["tab"]).should eq([[4, 1, "some"], [5, 2, "thing"], [6, 3, nil]])
        l.move_record_by_rank(hash["tab"], 1, 2)
        l.get_table(hash["tab"]).should eq([[5, 1, "thing"], [4, 2, "some"], [6, 3, nil]])
        l.move_record_by_rank(hash["tab"], 1, 3)
        l.get_table(hash["tab"]).should eq([[4, 1, "some"], [6, 2, nil], [5, 3, "thing"]])
        l.move_record_by_rank(hash["tab"], 1, 4)
        l.get_table(hash["tab"]).should eq([[6, 1, nil], [5, 2, "thing"], [4, 3, "some"]])
        l.move_record_by_rank(hash["tab"], 3, 2)
        l.get_table(hash["tab"]).should eq([[6, 1, nil], [4, 2, "some"], [5, 3, "thing"]])
        l.move_record_by_rank(hash["tab"], 3, 1)
        l.get_table(hash["tab"]).should eq([[5, 1, "thing"], [6, 2, nil], [4, 3, "some"]])
        l.move_record_by_rank(hash["tab"], 3, 0)
        l.get_table(hash["tab"]).should eq([[4, 1, "some"], [5, 2, "thing"], [6, 3, nil]])
        l.move_record_by_rank(hash["tab"], 1, 1)
        l.get_table(hash["tab"]).should eq([[4, 1, "some"], [5, 2, "thing"], [6, 3, nil]])
        l.move_record_by_rank(hash["tab"], 2, 2)
        l.get_table(hash["tab"]).should eq([[4, 1, "some"], [5, 2, "thing"], [6, 3, nil]])
        l.move_record_by_rank(hash["tab"], 3, 3)
        l.get_table(hash["tab"]).should eq([[4, 1, "some"], [5, 2, "thing"], [6, 3, nil]])
    end
    it "works" do
        data = [%w(first second third),["1",2,42.3],[4,nil,6],[7,8,9]]
        # first, write data to .xlsx
        file = File.tempname(".xlsx")
        workbook = Crexcel::Workbook.new(file)
        worksheet = workbook.add_worksheet("test")
        data.each.with_index do |row, i|
            worksheet.write_row(i, row)
        end
        workbook.close
        l = Persistency::Default.new
        # second, import .xlsx
        table_lid = l.import(file, "test")
        # third, export .xlsx
        l.export(file, table_lid)
        # fourth, read .xlsx back in
        book = XlsxParser::Book.new(file)
        res = [] of (Array(Bool | Float64 | Int32 | Int64 | String | Time | Nil) | Array(Bool | Float64 | Int32 | Int64 | String | Time)) # TODO(test): verbose union type — extract an alias
        book.sheets[0].rows.each do |row|
            res << row.values
        end
        # fifth, compare with original data
        res.should eq(data)

        ref_old = l.get_table(table_lid)
        ref_old_commit = l.context.current_commit
        ref_new_commit = l.close_and_add_commit

        ref = l.get_table(table_lid).transpose[2..-1].transpose # remove RecordLID and Rank
        ref.should eq([["1", 2, 42.3], [4, nil, 6], [7, 8, 9]])

        l.add_record(table_lid)
        l.get_table(table_lid).transpose[2..-1].transpose.should eq([["1", 2, 42.3], [4, nil, 6], [7, 8, 9], [nil, nil, nil]])

        table_lid2 = l.import(file, "test")
        # l.get_table(table_lid2)

        # check that querying commit table is independent of current commit
        l.get_field(MetaFieldLIDs::RootCommit).should eq({ref_old_commit=>MetaFieldLIDs::RootCommit, ref_new_commit=>ref_old_commit}) # test #1
        version = l.version
        l.context.current_commit = ref_old_commit
        l.version.should eq(version) # changing current commit shouldn't change the version
        l.get_field(MetaFieldLIDs::RootCommit).should eq({ref_old_commit=>MetaFieldLIDs::RootCommit, ref_new_commit=>ref_old_commit}) # test #2

        l.get_table(table_lid).should eq(ref_old)

        ref = l.get_table(table_lid)
        ref.transpose[2..-1].transpose.should eq([["1", 2, 42.3], [4, nil, 6], [7, 8, 9]])
        l.context.current_commit.should eq(ref_old_commit)

        l.get_table(12345678).should eq(Array(Array(Cell)).new)
    end
    it "works" do
        l = Persistency::Default.new
        table = l.add_table("foo")
        person = l.add_field(table, "person")
        m = l.add_field(table, "mother", person)
        f = l.add_field(table, "father", person)
        l.get_outward_reference(m).should eq(person)
        l.get_inward_references(person).should eq([m,f])
        l.get_table_lid(person).should eq(table)
        l.get_table_lid(m).should eq(table)
        l.get_table_lid(f).should eq(table)
    end
    it "testing VT and Persistency commits" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            people
            name
            A
            B
            C
        EOT
        context = l.context
        l.load(l.save) # testing load&save
        l.context = context
        l.get_table(hash["people"]).should eq([[4, 1, "A"], [5, 2, "B"], [6, 3, "C"]])
        frozen = l.context.current_commit
        l.close_and_add_commit
        l.move_record_by_rank(hash["people"], 2, 1)
        l.get_table(hash["people"]).should eq([[5, 1, "B"], [4, 2, "A"], [6, 3, "C"]])
        l.context.current_commit = frozen # rolling back
        l.get_table(hash["people"]).should eq([[4, 1, "A"], [5, 2, "B"], [6, 3, "C"]])
        l.load(l.save) # testing load&save
        l.context = context
        l.get_table(hash["people"]).should eq([[4, 1, "A"], [5, 2, "B"], [6, 3, "C"]])
    end
    it "testing factor out & in" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            persons
            name    | livesin
            Sauron  | Mordor
            Samwise | Shire
            Alan    | Boston
            Denny   | Boston
        EOT
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , "Mordor"],
            [2, "Samwise", "Shire" ],
            [3, "Alan"   , "Boston"],
            [4, "Denny"  , "Boston"]
        ])
        # prepare a new table to take the reference
        table_lid2 = l.add_table("cities")
        field_lid2 = l.add_field(table_lid2, "city")
        # first test: we factor out into empty table
        l.factor_out_reference(hash["persons"], hash["livesin"], table_lid2, field_lid2).should eq(false)
        cities = l.get_table(table_lid2)
        cities.map(&.[1..]).should eq([
            [1, "Boston"],
            [2, "Mordor"],
            [3, "Shire" ]
        ])
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , cities[1][0]], # now having proper references (RecordLIDs)
            [2, "Samwise", cities[2][0]],
            [3, "Alan"   , cities[0][0]],
            [4, "Denny"  , cities[0][0]]
        ])
        # undoing, i.e. removing the reference again
        l.factor_in_reference(hash["persons"], hash["livesin"])
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , "Mordor"],
            [2, "Samwise", "Shire" ],
            [3, "Alan"   , "Boston"],
            [4, "Denny"  , "Boston"]
        ])
        # doing the inital factor out again, target table should not change
        l.factor_out_reference(hash["persons"], hash["livesin"], table_lid2, field_lid2).should eq(false)
        cities = l.get_table(table_lid2)
        cities.map(&.[1..]).should eq([
            [1, "Boston"],
            [2, "Mordor"],
            [3, "Shire" ]
        ])
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , cities[1][0]],
            [2, "Samwise", cities[2][0]],
            [3, "Alan"   , cities[0][0]],
            [4, "Denny"  , cities[0][0]]
        ])
        # test factor_in with deleted referenced table
        l.remove_table(table_lid2)
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , cities[1][0]], # VT would show "(no reference)"
            [2, "Samwise", cities[2][0]],
            [3, "Alan"   , cities[0][0]],
            [4, "Denny"  , cities[0][0]]
        ])
        l.factor_in_reference(hash["persons"], hash["livesin"])
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , "Mordor"],
            [2, "Samwise", "Shire" ],
            [3, "Alan"   , "Boston"],
            [4, "Denny"  , "Boston"]
        ])
    end
    it "moving field outwards and inwards works - good case" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            cities
            city    | liesin
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA
            Munich  | Germany

            persons
            name    | livesin_city | sth
            Sauron  | Mordor       | a
            Samwise | Shire        | b
            Alan    | Boston       | c
            Denny   | Boston       | c
            Stale   | Boston       | nil
        EOT
        # first we test #move_field_outwards (on partially defined data)
        field_lid = l.move_field_outwards(hash["persons"], hash["livesin"], hash["cities"], hash["sth"])
        cities = l.get_table(hash["cities"])
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , cities[0][0]], # "sth" is removed...
            [2, "Samwise", cities[1][0]],
            [3, "Alan"   , cities[2][0]],
            [4, "Denny"  , cities[2][0]],
            [5, "Stale"  , cities[2][0]]
        ])
        l.get_table(hash["cities"]).map(&.[1..]).should eq([
            [1, "Mordor" , "MiddleEarth", "a"], # ... and now "sth" shows up here
            [2, "Shire"  , "MiddleEarth", "b"],
            [3, "Boston" , "USA"        , "c"],
            [4, "Seattle", "USA"        , nil],
            [5, "Munich" , "Germany"    , nil]
        ])
        l.set_value(field_lid, cities[4][0].as(RecordLID), "hi") # we insert a unreferenced element
        # then we test #move_field_inwards (and see filling up)
        field_lid = l.move_field_inwards(hash["persons"], hash["livesin"], hash["cities"], field_lid)
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , cities[0][0], "a"], # "sth" showing up here again
            [2, "Samwise", cities[1][0], "b"],
            [3, "Alan"   , cities[2][0], "c"],
            [4, "Denny"  , cities[2][0], "c"],
            [5, "Stale"  , cities[2][0], "c"] # this gets filled
        ])
        l.get_table(hash["cities"]).map(&.[1..]).should eq([
            [1, "Mordor" , "MiddleEarth", nil ],
            [2, "Shire"  , "MiddleEarth", nil ],
            [3, "Boston" , "USA"        , nil ],
            [4, "Seattle", "USA"        , nil ],
            [5, "Munich" , "Germany"    , "hi"]
        ])
        # user can manually drop the original "sth" column
    end
    it "moving field outwards works - bad case" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            cities
            city    | liesin
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city | sth
            Sauron  | Mordor       | a
            Samwise | Shire        | b
            Alan    | Boston       | d
            Denny   | Boston       | c
            Stale   | Boston       | c
        EOT
        expect_raises(ConditionsNotMet, "Cannot move, field 'sth' cannot have several values at once, e.g. at 'Boston' both 'd' and 'c'; ignoring command") do
            field_lid = l.move_field_outwards(hash["persons"], hash["livesin"], hash["cities"], hash["sth"])
        end
        # and checking that nothing was changed
        cities = l.get_table(hash["cities"])
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , cities[0][0], "a"],
            [2, "Samwise", cities[1][0], "b"],
            [3, "Alan"   , cities[2][0], "d"],
            [4, "Denny"  , cities[2][0], "c"],
            [5, "Stale"  , cities[2][0], "c"]
        ])
        l.get_table(hash["cities"]).map(&.[1..]).should eq([
            [1, "Mordor"  , "MiddleEarth" ],
            [2, "Shire"   , "MiddleEarth" ],
            [3, "Boston"  , "USA"         ],
            [4, "Seattle" , "USA"         ]
        ])
    end
    it "move_field works" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            persons
            name    | livesin | sth
            Sauron  | Mordor  | A
            Samwise | Shire   | B
            Alan    | Boston  | C
            Denny   | Boston  | D
        EOT
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , "Mordor", "A"],
            [2, "Samwise", "Shire" , "B"],
            [3, "Alan"   , "Boston", "C"],
            [4, "Denny"  , "Boston", "D"]
        ])
        l.move_field(hash["persons"], hash["sth"], hash["name"]) # replaces "name"'s position, moving forward
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "A", "Sauron" , "Mordor"],
            [2, "B", "Samwise", "Shire" ],
            [3, "C", "Alan"   , "Boston"],
            [4, "D", "Denny"  , "Boston"]
        ])
        l.move_field(hash["persons"], hash["sth"], hash["livesin"]) # replaces "livesin"'s position, moving backward
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , "Mordor", "A"],
            [2, "Samwise", "Shire" , "B"],
            [3, "Alan"   , "Boston", "C"],
            [4, "Denny"  , "Boston", "D"]
        ])
    end
    it "merge_fields works - good case" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            persons
            name    | sth | dummy | else
            Sauron  | A   | 1     | nil
            Samwise | B   | 2     | B
            Alan    | C   | 3     | C
            Denny   | nil | 4     | D
        EOT
        l.merge_fields(hash["persons"], hash["sth"], hash["else"])
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , 1, "A"],
            [2, "Samwise", 2, "B"],
            [3, "Alan"   , 3, "C"],
            [4, "Denny"  , 4, "D"]
        ])
    end
    it "merge_fields works - bad case" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            persons
            name    | sth | dummy | else
            Sauron  | A   | 1     | nil
            Samwise | B   | 2     | B
            Alan    | C   | 3     | C
            Denny   | C   | 4     | D
        EOT
        expect_raises(ConditionsNotMet, "Cannot merge, e.g. values 'C' and 'D' are different; ignoring command") do
            l.merge_fields(hash["persons"], hash["sth"], hash["else"])
        end
        l.get_table(hash["persons"]).map(&.[1..]).should eq([
            [1, "Sauron" , "A", 1, nil],
            [2, "Samwise", "B", 2, "B"],
            [3, "Alan"   , "C", 3, "C"],
            [4, "Denny"  , "C", 4, "D"]
        ])
    end
    it "sparse get_field only lists non-nil values" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            colors
            color  | sth
            Red    | nil
            Brown  | a
        EOT
        tab = l.get_table(hash["colors"])
        l.get_field(hash["sth"]).should eq({tab[1][0] => "a"})
        l.set_value(hash["sth"], tab[0][0].as(RecordLID), "x")
        l.get_field(hash["sth"]).should eq({tab[1][0] => "a", tab[0][0] => "x"})
        l.set_value(hash["sth"], tab[0][0].as(RecordLID), nil)
        l.get_field(hash["sth"]).should eq({tab[1][0] => "a"})
    end
    it "associate_fields and dissociate_fields works" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            allocations
            day       | Alice | Bob | Carol | mux | value
            Monday    | x     | x   | x     |     |
            Tuesday   |       | x   |       |     |
            Wednesday |       | x   | x     |     |
        EOT
        l.get_table(hash["allocations"]).map(&.[1..]).should eq([
            [1, "Monday"   , "x", "x", "x", nil, nil],
            [2, "Tuesday"  , nil, "x", nil, nil, nil],
            [3, "Wednesday", nil, "x", "x", nil, nil]
        ])
        l.associate_fields(hash["allocations"], [hash["Alice"], hash["Bob"], hash["Carol"]], hash["mux"], hash["value"])
        l.get_table(hash["allocations"]).map(&.[2..]).sort.should eq([
            ["Monday"   , "Alice", "x"],
            ["Monday"   , "Bob"  , "x"],
            ["Monday"   , "Carol", "x"],
            ["Tuesday"  , "Bob"  , "x"],
            ["Wednesday", "Bob"  , "x"],
            ["Wednesday", "Carol", "x"]
        ])
        l.dissociate_fields(hash["allocations"], hash["mux"], hash["value"])
        l.get_table(hash["allocations"]).map(&.[1..]).should eq([ # this is back from where we started
            [1, "Monday"   , "x", "x", "x"],
            [2, "Tuesday"  , nil, "x", nil],
            [3, "Wednesday", nil, "x", "x"]
        ])
    end
    it "stepwise associate_fields works" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            allocations
            day       | Alice | Bob | Carol | mux | value
            Monday    | x     | x   | x     |     |
            Tuesday   |       | x   |       |     |
            Wednesday |       | x   | x     |     |
        EOT
        l.associate_fields(hash["allocations"], [hash["Alice"]], hash["mux"], hash["value"]) # three steps - or two - same result at the end
        l.get_table(hash["allocations"]).map(&.[2..]).sort.should eq([
            ["Monday"   , "x", "x", "Alice", "x"],
            ["Tuesday"  , "x", nil, nil    , nil],
            ["Wednesday", "x", "x", nil    , nil]
        ])
        l.associate_fields(hash["allocations"], [hash["Bob"]], hash["mux"], hash["value"])
        l.get_table(hash["allocations"]).map(&.[2..]).sort.should eq([
            ["Monday"   , "x", "Alice", "x"], # Monday+Carol still in (part of the context)
            ["Monday"   , "x", "Bob"  , "x"], # here we see a repetition of Monday+Carol (first row)
            ["Tuesday"  , nil, "Bob"  , "x"],
            ["Wednesday", "x", "Bob"  , "x"]
        ])
        l.associate_fields(hash["allocations"], [hash["Carol"]], hash["mux"], hash["value"])
        l.get_table(hash["allocations"]).map(&.[2..]).sort.should eq([
            ["Monday"   , "Alice", "x"],
            ["Monday"   , "Bob"  , "x"],
            ["Monday"   , "Carol", "x"], # must show up only once
            ["Tuesday"  , "Bob"  , "x"],
            ["Wednesday", "Bob"  , "x"],
            ["Wednesday", "Carol", "x"]
        ])
    end
    it "associate_fields field and record singularities work" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            allocations
            day       | Alice | Bob | Carol | mux | value
            Monday    |       |     |       |     |
            Tuesday   |       |     |       |     |
            Wednesday |       |     |       |     |
        EOT
        l.associate_fields(hash["allocations"], [hash["Alice"], hash["Bob"], hash["Carol"]], hash["mux"], hash["value"])
        l.get_table(hash["allocations"]).map(&.[2..]).sort.should eq([
            [nil        , "Alice", nil],
            [nil        , "Bob"  , nil],
            [nil        , "Carol", nil],
            ["Monday"   , nil    , nil], # since we operate in one table, we have to insert dummy (nil) entries in order not to lose ex-field names (A/B/C)
            ["Tuesday"  , nil    , nil], # likewise record contexts (Mo/Tu/We) should not be lost
            ["Wednesday", nil    , nil]
        ])
    end
    it "associate_fields record singularities work" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            allocations
            day       | Alice | Bob | Carol | mux | value
        EOT
        l.associate_fields(hash["allocations"], [hash["Alice"], hash["Bob"], hash["Carol"]], hash["mux"], hash["value"])
        l.get_table(hash["allocations"]).map(&.[2..]).sort.should eq([
            [nil, "Alice", nil],
            [nil, "Bob"  , nil],
            [nil, "Carol", nil]
        ])
    end
    it "simple branches work" do # see booklet 14.3.2025
        commits = [MetaFieldLIDs::RootCommit]
        l = Persistency::Default.new
        commits << l.context.current_commit # 1, done by Basic constructor
        l.context.current_commit = commits[0]
        commits << l.close_and_add_commit # 2
        commits << l.close_and_add_commit # 3
        l.context.current_commit = commits[2]
        commits << l.close_and_add_commit # 4
        l.context.current_commit = commits[3]
        commits << l.close_and_add_commit # 5
        commits << l.close_and_add_commit # 6
        l.context.current_commit = commits[5]
        commits << l.close_and_add_commit # 7
        commits << l.close_and_add_commit # 8
        commits << l.close_and_add_commit # 9
        l.context.current_commit = commits[6]
        commits << l.close_and_add_commit # 10
        l.context.current_commit = commits[2] # current commit doesn't matter for following queries
        l.get_commit_path(commits[ 1]).should eq([0,1].map {|el| commits[el]})
        l.get_commit_path(commits[10]).should eq([0,2,3,5,6,10].map {|el| commits[el]})
        l.get_commit_path(commits[ 4]).should eq([0,2,4].map {|el| commits[el]})
        l.get_commit_path(commits[ 9]).should eq([0,2,3,5,7,8,9].map {|el| commits[el]})
        l.get_ordered_commit_leaves.should eq([1,10,4,9].map {|el| commits[el]})
    end
    it "special works" do
        l = Persistency::Default.new
        l.set_special("foo", "bar")
        l.get_special("foo").should eq("bar")
        l.load(l.save)
        l.get_special("foo").should eq("bar")
    end

    # === Phase 0: meta/net read-path separation ===
    # Background: Context.root_commit clamps the visible commit path for reads.
    # Setting root == current should yield exactly [current]. The earlier impl
    # had a bug walking past root when both were the same commit.

    it "get_commit_path with root==current yields single-commit path" do
        # Two commits, both with writes to the SAME cell but different values.
        # root=current=C → path=[C] only → get_value sees the write at C.
        l = Persistency::Default.new
        table = l.add_table("t")
        field = l.add_field(table, "f", nil)
        record = l.add_record(table)
        l.set_value(field, record, "old")  # lands on whatever commit is currently open
        commit_a = l.context.current_commit
        l.close_and_add_commit              # new open commit
        commit_b = l.context.current_commit
        l.set_value(field, record, "new")  # lands on commit_b
        # Clamp root=current=commit_b → path should be [commit_b] → get_value sees "new"
        l.context.root_commit = commit_b
        l.context.current_commit = commit_b
        l.get_value(field, record).should eq("new")
        # Clamp root=current=commit_a → path should be [commit_a] → get_value sees "old"
        l.context.root_commit = commit_a
        l.context.current_commit = commit_a
        l.get_value(field, record).should eq("old")
    end

    it "net read clamp with root=parent,current=open hides pre-parent writes" do
        l = Persistency::Default.new
        table = l.add_table("t")
        field = l.add_field(table, "f", nil)
        record = l.add_record(table)
        l.set_value(field, record, "oldest")  # on whatever commit is open
        l.close_and_add_commit
        parent_commit = l.context.current_commit
        l.close_and_add_commit
        open_commit = l.context.current_commit
        l.set_value(field, record, "newest")  # lands on open_commit
        # Clamp net path to [open_commit] only: should see "newest"
        l.context.root_commit = open_commit
        l.context.current_commit = open_commit
        l.get_value(field, record).should eq("newest")
        # Clamp to [parent_commit]: no writes at parent → returns nil
        l.context.root_commit = parent_commit
        l.context.current_commit = parent_commit
        l.get_value(field, record).should be_nil
    end

    it "meta-read default metadata_root_commit stays unclamped under net clamp" do
        l = Persistency::Default.new
        table = l.add_table("sales")
        field = l.add_field(table, "amount", nil)
        record = l.add_record(table)
        l.close_and_add_commit
        open_commit = l.context.current_commit
        l.set_value(field, record, 42i64)
        # Clamp net to [open_commit] only, leave metadata_root_commit at default
        l.context.root_commit = open_commit
        l.context.current_commit = open_commit
        # Meta-field reads (Names, BelongsTo) still return values written in earlier commits
        l.get_value(MetaFieldLIDs::Names, table).should eq("sales")
        l.get_value(MetaFieldLIDs::Names, field).should eq("amount")
    end

    it "metadata_root_commit clamps only meta reads, not net reads" do
        l = Persistency::Default.new
        table = l.add_table("t")
        field = l.add_field(table, "f", nil)
        record = l.add_record(table)
        l.close_and_add_commit
        mid = l.context.current_commit
        l.set_value(field, record, "v")  # net write at a later commit
        later = l.context.current_commit
        # Clamp meta to [mid..later] — schema writes from the initial commit become invisible
        l.context.metadata_root_commit = mid
        l.get_value(MetaFieldLIDs::Names, table).should be_nil  # name was written before mid
        # Net read unaffected
        l.get_value(field, record).should eq("v")
    end

    # === Phase 2: changes_in_open_commit summary ===

    it "changes_in_open_commit is empty on fresh persistency (no writes yet)" do
        l = Persistency::Default.new
        # No commits closed; context.current_commit == RootCommit
        l.changes_in_open_commit.empty?.should be_true
    end

    it "changes_in_open_commit counts cell edits by owning table" do
        l = Persistency::Default.new
        table_a = l.add_table("A")
        field_a = l.add_field(table_a, "f_a", nil)
        rec_a = l.add_record(table_a)
        table_b = l.add_table("B")
        field_b = l.add_field(table_b, "f_b", nil)
        rec_b = l.add_record(table_b)
        l.close_and_add_commit  # open commit for pending edits
        l.set_value(field_a, rec_a, "x1")
        l.set_value(field_a, rec_a, "x2")  # second write on same cell (still one entry at this commit)
        l.set_value(field_b, rec_b, "y1")
        changes = l.changes_in_open_commit
        changes.size.should eq(2)
        changes[table_a].cells_changed.should eq(1)
        changes[table_b].cells_changed.should eq(1)
        changes[table_a].records_added.should eq(0)
        changes[table_a].fields_added.should eq(0)
    end

    it "changes_in_open_commit counts record additions" do
        l = Persistency::Default.new
        table = l.add_table("T")
        l.add_field(table, "f", nil)
        l.close_and_add_commit  # seal baseline
        l.add_record(table)
        l.add_record(table)
        changes = l.changes_in_open_commit
        changes[table].records_added.should eq(2)
    end

    it "changes_in_open_commit counts field additions" do
        l = Persistency::Default.new
        table = l.add_table("T")
        l.close_and_add_commit  # seal baseline (table exists, no fields yet)
        l.add_field(table, "new_field", nil)
        changes = l.changes_in_open_commit
        changes[table].fields_added.should eq(1)
    end

    it "changes_in_open_commit counts record removals (records_removed)" do
        l = Persistency::Default.new
        table = l.add_table("T")
        f = l.add_field(table, "f", nil)
        r1 = l.add_record(table)
        r2 = l.add_record(table)
        l.set_value(f, r1, "v1")
        l.set_value(f, r2, "v2")
        l.close_and_add_commit  # seal baseline; r1, r2 belong to table
        l.remove_record(table, r1)  # one removal in open commit
        changes = l.changes_in_open_commit
        changes[table].records_removed.should eq(1)
        changes[table].records_added.should eq(0)
    end

    it "changes_in_open_commit counts field removals (fields_removed)" do
        l = Persistency::Default.new
        table = l.add_table("T")
        f = l.add_field(table, "f", nil)
        l.close_and_add_commit  # seal baseline
        l.remove_field(table, f)
        changes = l.changes_in_open_commit
        changes[table].fields_removed.should eq(1)
        changes[table].fields_added.should eq(0)
    end

    it "changes_in_open_commit attributes a removal to the original table" do
        # Remove a record at the open commit; attribution should land on the
        # table the record belonged to BEFORE the removal (BelongsTo wrote nil
        # at target — we have to look at the prior non-nil value).
        l = Persistency::Default.new
        table_a = l.add_table("A")
        l.add_field(table_a, "f", nil)
        rec_a = l.add_record(table_a)
        table_b = l.add_table("B")
        l.add_field(table_b, "f", nil)
        l.add_record(table_b)
        l.close_and_add_commit
        l.remove_record(table_a, rec_a)
        changes = l.changes_in_open_commit
        changes[table_a]?.try(&.records_removed).should eq(1)
        changes[table_b]?.try(&.records_removed).should eq(nil)  # untouched
    end
    it "changes_in_open_commit shows a record move as removed-from-source + added-to-target (T-010)" do
        l = Persistency::Default.new
        src = l.add_table("src"); sa = l.add_field(src, "a")
        r = l.add_record(src); l.set_value(sa, r, "x")
        dst = l.add_table("dst"); l.add_field(dst, "a")
        l.close_and_add_commit
        l.move_records([r], src, dst)
        changes = l.changes_in_open_commit
        changes[src].not_nil!.records_removed.should eq(1) # the record left the source
        changes[dst].not_nil!.records_added.should eq(1)   # and joined the target
        changes[src].not_nil!.cells_changed.should eq(0)   # the re-key is the move, not independent edits
        changes[dst].not_nil!.cells_changed.should eq(0)
        changes[src].not_nil!.records_added.should eq(0)
        changes[dst].not_nil!.records_removed.should eq(0)
    end
    it "changes_in_open_commit attributes a post-move removal to the table the record was in (T-010)" do
        l = Persistency::Default.new
        src = l.add_table("src"); l.add_field(src, "a")
        r = l.add_record(src)
        dst = l.add_table("dst"); l.add_field(dst, "a")
        l.close_and_add_commit               # C1: r created in src
        l.move_records([r], src, dst)        # C2: r moved to dst (src now in the BelongsTo history)
        l.close_and_add_commit
        l.remove_record(dst, r)              # C3 (target): remove it from dst
        changes = l.changes_in_open_commit
        changes[dst]?.try(&.records_removed).should eq(1)  # attributed to dst (where it was), not src
        changes[src]?.try(&.records_removed).should eq(nil)
    end

    # === Phase 3: selective commit via float_writes ===

    it "float_writes moves cell edits for listed tables to the new commit" do
        l = Persistency::Default.new
        table_a = l.add_table("A")
        field_a = l.add_field(table_a, "f", nil)
        rec_a = l.add_record(table_a)
        table_b = l.add_table("B")
        field_b = l.add_field(table_b, "f", nil)
        rec_b = l.add_record(table_b)
        l.close_and_add_commit  # seal baseline
        from_commit = l.context.current_commit
        l.set_value(field_a, rec_a, "a-new")
        l.set_value(field_b, rec_b, "b-new")
        # Close and allocate next commit
        l.close_and_add_commit
        to_commit = l.context.current_commit
        # Float only A's writes → A moves, B stays
        l.float_writes(from: from_commit, to: to_commit, defer_tables: Set{table_a})
        # Verify A at from → gone, at to → present
        l.context.current_commit = from_commit
        l.get_value(field_a, rec_a).should be_nil
        l.get_value(field_b, rec_b).should eq("b-new")
        l.context.current_commit = to_commit
        l.get_value(field_a, rec_a).should eq("a-new")
        l.get_value(field_b, rec_b).should eq("b-new")  # inherited via path
    end

    it "float_writes atomicity: record-add meta writes float together with cell writes" do
        l = Persistency::Default.new
        table = l.add_table("T")
        field = l.add_field(table, "f", nil)
        l.close_and_add_commit  # baseline
        from_commit = l.context.current_commit
        # In open commit: add new record + initial cell value
        new_rec = l.add_record(table)
        l.set_value(field, new_rec, "v")
        # Close and allocate next commit
        l.close_and_add_commit
        to_commit = l.context.current_commit
        l.float_writes(from: from_commit, to: to_commit, defer_tables: Set{table})
        # At from_commit: new record shouldn't exist (Predecessors/TableLastRecord/BelongsTo all floated)
        l.context.current_commit = from_commit
        l.get_value(field, new_rec).should be_nil
        # At to_commit: new record's cell is visible
        l.context.current_commit = to_commit
        l.get_value(field, new_rec).should eq("v")
    end

    # === cells_written_at / records_with_writes_at ===

    it "cells_written_at returns only user-field writes at target commit" do
        l = Persistency::Default.new
        table = l.add_table("T")
        f1 = l.add_field(table, "f1", nil)
        f2 = l.add_field(table, "f2", nil)
        rec = l.add_record(table)
        l.set_value(f1, rec, "v")
        # All writes above are on the initial open commit.
        target = l.context.current_commit
        written = l.cells_written_at(target)
        written.includes?({f1, rec}).should be_true
        # Meta-field writes (BelongsTo, Names, TableLast*, Predecessors) are NOT
        # included even though they also landed on `target`.
        written.none? { |f, _| f < 0 }.should be_true
        # f2 has no value write yet → not in the set
        written.includes?({f2, rec}).should be_false
    end

    it "cells_written_at result is memoized by version" do
        l = Persistency::Default.new
        table = l.add_table("T")
        f = l.add_field(table, "f", nil)
        rec = l.add_record(table)
        l.set_value(f, rec, "v")
        target = l.context.current_commit
        s1 = l.cells_written_at(target)
        s2 = l.cells_written_at(target)
        # Same-object identity: same version + same commit → cached Set instance.
        s1.same?(s2).should be_true
        # After a write (version bump), result recomputed.
        l.set_value(f, rec, "w")  # same cell, still at `target`
        s3 = l.cells_written_at(target)
        s3.same?(s1).should be_false
        # Content still contains the cell.
        s3.includes?({f, rec}).should be_true
    end

    it "records_with_writes_at includes newly-added records even without user-field writes" do
        l = Persistency::Default.new
        table = l.add_table("T")
        f = l.add_field(table, "f", nil)
        l.close_and_add_commit  # seal setup
        commit = l.context.current_commit
        new_rec = l.add_record(table)  # lands in commit, no cell writes
        records = l.records_with_writes_at(commit, table)
        records.should contain(new_rec)
    end

    it "records_with_writes_at from cell writes in an existing record" do
        l = Persistency::Default.new
        table = l.add_table("T")
        f = l.add_field(table, "f", nil)
        rec = l.add_record(table)
        l.close_and_add_commit
        commit = l.context.current_commit
        l.set_value(f, rec, "v")
        records = l.records_with_writes_at(commit, table)
        records.should contain(rec)
    end

    it "float_writes with empty defer set is a no-op" do
        l = Persistency::Default.new
        table = l.add_table("T")
        field = l.add_field(table, "f", nil)
        rec = l.add_record(table)
        l.close_and_add_commit
        from_commit = l.context.current_commit
        l.set_value(field, rec, "x")
        l.close_and_add_commit
        to_commit = l.context.current_commit
        l.float_writes(from: from_commit, to: to_commit, defer_tables: Set(TableLID).new)
        # Everything stays where it was
        l.context.current_commit = from_commit
        l.get_value(field, rec).should eq("x")
        l.context.current_commit = to_commit
        l.get_value(field, rec).should eq("x")  # still inherited via path
    end

    it "orthogonality: meta clamp doesn't leak into net reads" do
        l = Persistency::Default.new
        table = l.add_table("t")
        field = l.add_field(table, "f", nil)
        record = l.add_record(table)
        l.set_value(field, record, "v1")
        l.close_and_add_commit
        mid = l.context.current_commit
        l.set_value(field, record, "v2")  # lands on mid (it's the open commit)
        # Clamp only meta — net reads unaffected
        l.context.metadata_root_commit = mid  # hide pre-mid meta writes (Names etc.)
        # metadata_commit was auto-synced to mid via current_commit=; force it stays at current
        # Net reads: full path, see latest value
        l.get_value(field, record).should eq("v2")
        # Meta reads: clamped — "f" and "t" names were written pre-mid, invisible now
        l.get_value(MetaFieldLIDs::Names, field).should be_nil
    end
end

describe "Persistency::Generic::LoadSave (.embrace file format)" do
  it "saves as plain zlib-compressed JSON, not encrypted" do
    l = Persistency::Default.new
    bytes = l.save
    # The saved bytes must decompress directly as a zlib stream to JSON —
    # i.e. no AES layer in front (an open format anyone can read).
    json = Compress::Zlib::Reader.new(IO::Memory.new(bytes)).gets_to_end
    json.should start_with("{")
  end
end
