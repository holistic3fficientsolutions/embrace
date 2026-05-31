require "spec"
require "../../spec/spec_helper"
require "../../src/table/lazy"
require "../../src/table/pivot"
require "../../src/global"

include Table # in order to be able to test protected methods

struct SimpleBaseCell
    def <=>(other : SimpleBaseCell)
        0
    end
end
alias MyBaseCell = SimpleBaseCell|String|Nil|NilDeadAreaStruct # String for "(cnt)"; in addition Int64 for Indexed, if used

describe Table::Lazy::Pivot do
    it "Pivot::Simple works, including header writing" do
        # Load    Name    Project     Quarter
        raw_table = Helper(BaseCell).string2table(4, <<-EOT)
            10.0    Carol   Alpha        Q1
            10      Alice   Beta         Q3
            50      Carol   Alpha        Q4
            10      Carol   Alpha        Q4
            100     Alice   Beta         Q4
            80      Carol   Gamma    Q1
            100     Carol   Gamma    Q2
            100     Alice   Gamma    Q4
            100     Bob     Gamma    Q4
            80      Alice   Gamma    Q2
            EOT
        table = Table::Lazy::Pivot::Simple(BaseCell, BaseCell).new(raw_table, Hash(Int32,Int32).new, [{column: 1, sort_asc?: true}], [{column: 3, sort_asc?: true}])
        # puts table.to_a2
        table.size.should eq([4,5])
        table[[0,1]].should eq("Q1")
        table[[0,1]] = "Q0"
        table.size.should eq([4,5])
        table[[0,1]].should eq("Q0")
        table[[0,1]] = "Q4"
        table.size.should eq([4,4])
        table[[0,1]].should eq("Q2")
    end
    it "checking Simple out-of-bounds in Hierarchic use case" do
        raw_table = Helper(BaseCell).string2table(2, <<-EOT)
            c1a r2a
            c1a r2b
            c1b r2b
        EOT
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Column.value   , 0, true,
            1, Table::Lazy::Pivot::Classes::Row.value      , 1, true
            ])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(raw_table, fieldlist_table)
        hier_pivot_table.size.should eq([3,4])
        hier_pivot_table.to_a2.should eq([["c1a", "c1a", "c1b", "c1b"], ["r2a", "#1", "r2b", "#1"], ["r2b", "#1", nil, nil]])
    end
    it "staff planning use cases" do
        # Load    Name    Project     Quarter
        raw_table = Helper(BaseCell).string2table(4, <<-EOT)
            10.0    Carol   Alpha        Q1
            10      Alice   Beta         Q3
            50      Carol   Alpha        Q4
            10      Carol   Alpha        Q4
            100     Alice   Beta         Q4
            80      Carol   Gamma    Q1
            100     Carol   Gamma    Q2
            100     Alice   Gamma    Q4
            100     Bob     Gamma    Q4
            80      Alice   Gamma    Q2
            EOT
        indexed_table = Table::Lazy::Raw::Indexed.new(raw_table, 1)
        fieldlist_table = Helper(FieldlistCell).array2table(4, [] of FieldlistCell)
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table)
        hier_pivot_table.to_a.should eq(["#10"])
        hier_pivot_table.get_table([0,0]).size.should eq([10,5])

        # col_index    pivot_class                        level   rowcol_sort_asc
        fieldlist_table2 = Helper(FieldlistCell).array2table(4, [
            4, Table::Lazy::Pivot::Classes::Column   .value, 0, true,
            3, Table::Lazy::Pivot::Classes::Row      .value, 0, true,
            2, Table::Lazy::Pivot::Classes::Row      .value, 0, true,
            0, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            1, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false])
        fieldlist_table2 = Table::Lazy::Raw::Indexed.new(fieldlist_table2, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table2)
        hier_pivot_table.to_a.should eq([NilDeadArea, NilDeadArea, "Q1", "Q1", "Q2", "Q2", "Q3", "Q3", "Q4", "Q4", "Alpha", "Carol", 0, 10.0, nil, nil, nil, nil, "#2/Σ5", "#2/Σ60", "Beta", "Alice", nil, nil, nil, nil, 1, 10, 4, 100, "Gamma", "Alice", nil, nil, 9, 80, nil, nil, 7, 100, "Gamma", "Bob", nil, nil, nil, nil, nil, nil, 8, 100, "Gamma", "Carol", 5, 80, 6, 100, nil, nil, nil, nil])
        hier_pivot_table.get_table([0,2]).size.should eq([2]) # two entries for Q1
        hier_pivot_table.get_table([0,8]).size.should eq([5]) # five entries for Q4
        hier_pivot_table.get_table([1,8]).size.should eq([2])
        (hier_pivot_table[[1,3]] = 120i64).should eq([1,3])
        hier_pivot_table.get_table([1,3]).size.should eq([1])
        hier_pivot_table.get_table([1,3])[[0]] = 130i64 # writing to sub-table
        hier_pivot_table[[1,3]].should eq(130i64)
        hier_pivot_table[[1,3]] = 120i64
        hier_pivot_table.get_table([0,0]).size.should eq([0]) # top left
        hier_pivot_table.get_table([0,2])[[0]].should eq("Q1")
        hier_pivot_table.to_a.should eq([NilDeadArea, NilDeadArea, "Q1", "Q1", "Q2", "Q2", "Q3", "Q3", "Q4", "Q4", "Alpha", "Carol", 0, 120, nil, nil, nil, nil, "#2/Σ5", "#2/Σ60", "Beta", "Alice", nil, nil, nil, nil, 1, 10, 4, 100, "Gamma", "Alice", nil, nil, 9, 80, nil, nil, 7, 100, "Gamma", "Bob", nil, nil, nil, nil, nil, nil, 8, 100, "Gamma", "Carol", 5, 80, 6, 100, nil, nil, nil, nil])
        # col_index           pivot_class                level     rowcol_sort_asc
        fieldlist_table3 = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Row      .value, 0, true,
            1, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            4, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true ])
        fieldlist_table3 = Table::Lazy::Raw::Indexed.new(fieldlist_table3, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table3)
        hier_pivot_table.to_a2.should eq([
            [0, 120, "Carol", "Alpha"    , "Q1"],
            [1, 10 , "Alice", "Beta"     , "Q3"],
            [2, 50 , "Carol", "Alpha"    , "Q4"],
            [3, 10 , "Carol", "Alpha"    , "Q4"],
            [4, 100, "Alice", "Beta"     , "Q4"],
            [5, 80 , "Carol", "Gamma", "Q1"],
            [6, 100, "Carol", "Gamma", "Q2"],
            [7, 100, "Alice", "Gamma", "Q4"],
            [8, 100, "Bob"  , "Gamma", "Q4"],
            [9, 80 , "Alice", "Gamma", "Q2"]])
        (hier_pivot_table[[3,0]] = 5i64).should eq([5,0]) # assigning to rank, hence moving
        hier_pivot_table.to_a2.should eq([
            [0, 120, "Carol", "Alpha"    , "Q1"],
            [1, 10 , "Alice", "Beta"     , "Q3"],
            [2, 50 , "Carol", "Alpha"    , "Q4"],
            [3, 100, "Alice", "Beta"     , "Q4"],
            [4, 80 , "Carol", "Gamma", "Q1"],
            [5, 10 , "Carol", "Alpha"    , "Q4"],
            [6, 100, "Carol", "Gamma", "Q2"],
            [7, 100, "Alice", "Gamma", "Q4"],
            [8, 100, "Bob"  , "Gamma", "Q4"],
            [9, 80 , "Alice", "Gamma", "Q2"]])
        (hier_pivot_table[[5,0]] = 3i64).should eq([3,0]) # and back again
        # col_index    pivot_class      level        rowcol_sort_asc
        fieldlist_table4 = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Column   .value, 0, true,
            1, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 1, true,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 2, true,
            4, Table::Lazy::Pivot::Classes::Aggregate.value, 3, true])
        fieldlist_table4 = Table::Lazy::Raw::Indexed.new(fieldlist_table4, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table4)
        hier_pivot_table.to_a.should eq([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 120, 10, 50, 10, 100, 80, 100, 100, 100, 80, "Carol", "Alice", "Carol", "Carol", "Alice", "Carol", "Carol", "Alice", "Bob", "Alice", "Alpha", "Beta", "Alpha", "Alpha", "Beta", "Gamma", "Gamma", "Gamma", "Gamma", "Gamma", "Q1", "Q3", "Q4", "Q4", "Q4", "Q1", "Q2", "Q4", "Q4", "Q2"])
        hier_pivot_table.hyperplane_move(0, [2,1], [2,0]).should eq([2,0]) # same effect as line below
        # hier_pivot_table[[0,0]] = 1i64 # same effect as line above
        hier_pivot_table.to_a.should eq([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 120, 50, 10, 100, 80, 100, 100, 100, 80, "Alice", "Carol", "Carol", "Carol", "Alice", "Carol", "Carol", "Alice", "Bob", "Alice", "Beta", "Alpha", "Alpha", "Alpha", "Beta", "Gamma", "Gamma", "Gamma", "Gamma", "Gamma", "Q3", "Q1", "Q4", "Q4", "Q4", "Q1", "Q2", "Q4", "Q4", "Q2"])
        hier_pivot_table.hyperplane_move(0, [2,0], [2,1]).should eq([2,1]) # move back again
        hier_pivot_table.to_a.should eq([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 120, 10, 50, 10, 100, 80, 100, 100, 100, 80, "Carol", "Alice", "Carol", "Carol", "Alice", "Carol", "Carol", "Alice", "Bob", "Alice", "Alpha", "Beta", "Alpha", "Alpha", "Beta", "Gamma", "Gamma", "Gamma", "Gamma", "Gamma", "Q1", "Q3", "Q4", "Q4", "Q4", "Q1", "Q2", "Q4", "Q4", "Q2"])
    end
    it "kanban use cases" do
        # Name    Task          State         Project     Priority
        raw_table = Helper(BaseCell).string2table(5, <<-EOT)
            Carol   Design        1-Ready       Alpha        1-High
            Alice   Code          2-InWork      Beta         1-High
            Carol   Architecture  2-InWork      Alpha        1-High
            Carol   Requirement   3-Done        Alpha        2-Medium
            Alice   Test          3-Done        Beta         2-Medium
            Carol   Design        1-Ready       Gamma    2-Medium
            Carol   Test          2-InWork      Gamma    2-Medium
            Alice   Test          2-InWork      Gamma    3-Low
            Bob     Code          2-InWork      Gamma    3-Low
            Alice   Code          1-Ready       Gamma    3-Low
            EOT
        indexed_table = Table::Lazy::Raw::Indexed.new(raw_table, 1)
        # col_index    pivot_class            level   rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [] of FieldlistCell)
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table)
        hier_pivot_table.to_a.should eq(["#10"])
        # col_index    pivot_class                               level    rowcol_sort_asc
        fieldlist_table2 = Helper(FieldlistCell).array2table(4, [
            3,     Table::Lazy::Pivot::Classes::Column.value,        0,    true,
            0,     Table::Lazy::Pivot::Classes::Aggregate.value,     0,    true,
            1,     Table::Lazy::Pivot::Classes::Aggregate.value,     0,    false,
            4,     Table::Lazy::Pivot::Classes::Aggregate.value,     0,    false,
            2,     Table::Lazy::Pivot::Classes::Aggregate.value,     0,    false])
        fieldlist_table2 = Table::Lazy::Raw::Indexed.new(fieldlist_table2, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table2)
        hier_pivot_table.to_a.should eq(["1-Ready", "1-Ready", "1-Ready", "1-Ready", "2-InWork", "2-InWork", "2-InWork", "2-InWork", "3-Done", "3-Done", "3-Done", "3-Done", "#3/Σ14", "#3", "#3", "#3", "#5/Σ24", "#5", "#5", "#5", "#2/Σ7", "#2", "#2", "#2"])
        # col_index    pivot_class      level    rowcol_sort_asc
        fieldlist_table3 = Helper(FieldlistCell).array2table(4, [
            3,     Table::Lazy::Pivot::Classes::Column.value,         0,   true,
            0,     Table::Lazy::Pivot::Classes::Row.value,            1,   true,
            1,     Table::Lazy::Pivot::Classes::Aggregate.value,      0,   false,
            4,     Table::Lazy::Pivot::Classes::Aggregate.value,      0,   false,
            2,     Table::Lazy::Pivot::Classes::Aggregate.value,      0,   false])
        fieldlist_table3 = Table::Lazy::Raw::Indexed.new(fieldlist_table3, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table3)
        hier_pivot_table.to_a.should eq(["1-Ready", "1-Ready", "1-Ready", "1-Ready", "2-InWork", "2-InWork", "2-InWork", "2-InWork", "3-Done", "3-Done", "3-Done", "3-Done", 0, "Carol", "Alpha", "Design", 1, "Alice", "Beta", "Code", 3, "Carol", "Alpha", "Requirement", 5, "Carol", "Gamma", "Design", 2, "Carol", "Alpha", "Architecture", 4, "Alice", "Beta", "Test", 9, "Alice", "Gamma", "Code", 6, "Carol", "Gamma", "Test", nil, nil, nil, nil, nil, nil, nil, nil, 7, "Alice", "Gamma", "Test", nil, nil, nil, nil, nil, nil, nil, nil, 8, "Bob", "Gamma", "Code", nil, nil, nil, nil])
        tabs = [] of Int32?
        hier_pivot_table.size[0].times do |ri|
            hier_pivot_table.size[1].times do |ci|
                c = hier_pivot_table.get_table([ri,ci])
                tabs << (c ? c.size[0] : nil)
            end
        end
        tabs.should eq([3, 3, 3, 3, 5, 5, 5, 5, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0])

        # col_index    pivot_class          level            rowcol_sort_asc
        fieldlist_table4 = Helper(FieldlistCell).array2table(4, [
            3,     Table::Lazy::Pivot::Classes::Column.value,       0,     true,
            5,     Table::Lazy::Pivot::Classes::Row.value,          0,     true,
            0,     Table::Lazy::Pivot::Classes::Row.value,          1,     true,
            1,     Table::Lazy::Pivot::Classes::Aggregate.value,    0,     false,
            4,     Table::Lazy::Pivot::Classes::Aggregate.value,    0,     false,
            2,     Table::Lazy::Pivot::Classes::Aggregate.value,    0,     false])
        fieldlist_table4 = Table::Lazy::Raw::Indexed.new(fieldlist_table4, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table4)
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "1-Ready", "1-Ready", "1-Ready", "1-Ready", "2-InWork", "2-InWork", "2-InWork", "2-InWork", "3-Done", "3-Done", "3-Done", "3-Done"],
            ["1-High", 0, "Carol", "Alpha", "Design", 1, "Alice", "Beta", "Code", nil, nil, nil, nil],
            ["1-High", nil, nil, nil, nil, 2, "Carol", "Alpha", "Architecture", nil, nil, nil, nil],
            ["2-Medium", 5, "Carol", "Gamma", "Design", 6, "Carol", "Gamma", "Test", 3, "Carol", "Alpha", "Requirement"],
            ["2-Medium", nil, nil, nil, nil, nil, nil, nil, nil, 4, "Alice", "Beta", "Test"],
            ["3-Low", 9, "Alice", "Gamma", "Code", 7, "Alice", "Gamma", "Test", nil, nil, nil, nil],
            ["3-Low", nil, nil, nil, nil, 8, "Bob", "Gamma", "Code", nil, nil, nil, nil]])
        hier_pivot_table.get_scrollorder.should eq({[1, 2, 3, 4, 5, 6, 0], [2, 3, 4, 1, 6, 7, 8, 5, 10, 11, 12, 9, 0]})

        (hier_pivot_table[[0,2]] = "4-Ready").should eq([0,9]) # changing a header cell
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "2-InWork", "2-InWork", "2-InWork", "2-InWork", "3-Done", "3-Done", "3-Done", "3-Done", "4-Ready", "4-Ready", "4-Ready", "4-Ready"],
            ["1-High", 1, "Alice", "Beta", "Code", nil, nil, nil, nil, 0, "Carol", "Alpha", "Design"],
            ["1-High", 2, "Carol", "Alpha", "Architecture", nil, nil, nil, nil, nil, nil, nil, nil],
            ["2-Medium", 6, "Carol", "Gamma", "Test", 3, "Carol", "Alpha", "Requirement", 5, "Carol", "Gamma", "Design"],
            ["2-Medium", nil, nil, nil, nil, 4, "Alice", "Beta", "Test", nil, nil, nil, nil],
            ["3-Low", 7, "Alice", "Gamma", "Test", nil, nil, nil, nil, 9, "Alice", "Gamma", "Code"],
            ["3-Low", 8, "Bob", "Gamma", "Code", nil, nil, nil, nil, nil, nil, nil, nil]])
        raw_table.to_a2.should eq([["Carol", "Design", "4-Ready", "Alpha", "1-High"], ["Alice", "Code", "2-InWork", "Beta", "1-High"], ["Carol", "Architecture", "2-InWork", "Alpha", "1-High"], ["Carol", "Requirement", "3-Done", "Alpha", "2-Medium"], ["Alice", "Test", "3-Done", "Beta", "2-Medium"], ["Carol", "Design", "4-Ready", "Gamma", "2-Medium"], ["Carol", "Test", "2-InWork", "Gamma", "2-Medium"], ["Alice", "Test", "2-InWork", "Gamma", "3-Low"], ["Bob", "Code", "2-InWork", "Gamma", "3-Low"], ["Alice", "Code", "4-Ready", "Gamma", "3-Low"]])

        (hier_pivot_table[[1,2]] = "Carol2").should eq([1,2]) # changing a normal (single) cell
        hier_pivot_table.to_a2.should eq([[NilDeadArea, "2-InWork", "2-InWork", "2-InWork", "2-InWork", "3-Done", "3-Done", "3-Done", "3-Done", "4-Ready", "4-Ready", "4-Ready", "4-Ready"], ["1-High", 1, "Carol2", "Beta", "Code", nil, nil, nil, nil, 0, "Carol", "Alpha", "Design"], ["1-High", 2, "Carol", "Alpha", "Architecture", nil, nil, nil, nil, nil, nil, nil, nil], ["2-Medium", 6, "Carol", "Gamma", "Test", 3, "Carol", "Alpha", "Requirement", 5, "Carol", "Gamma", "Design"], ["2-Medium", nil, nil, nil, nil, 4, "Alice", "Beta", "Test", nil, nil, nil, nil], ["3-Low", 7, "Alice", "Gamma", "Test", nil, nil, nil, nil, 9, "Alice", "Gamma", "Code"], ["3-Low", 8, "Bob", "Gamma", "Code", nil, nil, nil, nil, nil, nil, nil, nil]])
        raw_table.to_a2.should eq([["Carol", "Design", "4-Ready", "Alpha", "1-High"], ["Carol2", "Code", "2-InWork", "Beta", "1-High"], ["Carol", "Architecture", "2-InWork", "Alpha", "1-High"], ["Carol", "Requirement", "3-Done", "Alpha", "2-Medium"], ["Alice", "Test", "3-Done", "Beta", "2-Medium"], ["Carol", "Design", "4-Ready", "Gamma", "2-Medium"], ["Carol", "Test", "2-InWork", "Gamma", "2-Medium"], ["Alice", "Test", "2-InWork", "Gamma", "3-Low"], ["Bob", "Code", "2-InWork", "Gamma", "3-Low"], ["Alice", "Code", "4-Ready", "Gamma", "3-Low"]])

        (hier_pivot_table[[3,1]] = 1i64).should eq([3,1]) # changing an "index" cell
        hier_pivot_table.to_a2.should eq([[NilDeadArea, "2-InWork", "2-InWork", "2-InWork", "2-InWork", "3-Done", "3-Done", "3-Done", "3-Done", "4-Ready", "4-Ready", "4-Ready", "4-Ready"], ["1-High", 2, "Carol2", "Beta", "Code", nil, nil, nil, nil, 0, "Carol", "Alpha", "Design"], ["1-High", 3, "Carol", "Alpha", "Architecture", nil, nil, nil, nil, nil, nil, nil, nil], ["2-Medium", 1, "Carol", "Gamma", "Test", 4, "Carol", "Alpha", "Requirement", 6, "Carol", "Gamma", "Design"], ["2-Medium", nil, nil, nil, nil, 5, "Alice", "Beta", "Test", nil, nil, nil, nil], ["3-Low", 7, "Alice", "Gamma", "Test", nil, nil, nil, nil, 9, "Alice", "Gamma", "Code"], ["3-Low", 8, "Bob", "Gamma", "Code", nil, nil, nil, nil, nil, nil, nil, nil]])
        raw_table.to_a2.should eq([["Carol", "Design", "4-Ready", "Alpha", "1-High"], ["Carol", "Test", "2-InWork", "Gamma", "2-Medium"], ["Carol2", "Code", "2-InWork", "Beta", "1-High"], ["Carol", "Architecture", "2-InWork", "Alpha", "1-High"], ["Carol", "Requirement", "3-Done", "Alpha", "2-Medium"], ["Alice", "Test", "3-Done", "Beta", "2-Medium"], ["Carol", "Design", "4-Ready", "Gamma", "2-Medium"], ["Alice", "Test", "2-InWork", "Gamma", "3-Low"], ["Bob", "Code", "2-InWork", "Gamma", "3-Low"], ["Alice", "Code", "4-Ready", "Gamma", "3-Low"]])

        hier_pivot_table.hyperplane_remove(0, [1,3])
        hier_pivot_table.to_a2.should eq([[NilDeadArea, "2-InWork", "2-InWork", "2-InWork", "2-InWork", "3-Done", "3-Done", "3-Done", "3-Done", "4-Ready", "4-Ready", "4-Ready", "4-Ready"], ["1-High", 2, "Carol", "Alpha", "Architecture", nil, nil, nil, nil, 0, "Carol", "Alpha", "Design"], ["2-Medium", 1, "Carol", "Gamma", "Test", 3, "Carol", "Alpha", "Requirement", 5, "Carol", "Gamma", "Design"], ["2-Medium", nil, nil, nil, nil, 4, "Alice", "Beta", "Test", nil, nil, nil, nil], ["3-Low", 6, "Alice", "Gamma", "Test", nil, nil, nil, nil, 8, "Alice", "Gamma", "Code"], ["3-Low", 7, "Bob", "Gamma", "Code", nil, nil, nil, nil, nil, nil, nil, nil]])
    end
    it "Pivoting over arbitrary  BaseCell works" do
        raw_table = Table::Lazy::Raw::Memory(MyBaseCell).new([1,1])
        fieldlist_table = Table::Lazy::Raw::Memory(FieldlistCell).new([0,0])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(MyBaseCell,MyBaseCell,FieldlistCell).new(raw_table, fieldlist_table)
        hier_pivot_table.to_a.should eq(["#1"] of MyBaseCell)
    end
    it "simple padding test" do
        raw_table = Helper(BaseCell).string2table(2, <<-EOT)
            a1 v1
            a1 v2
            a1 v3
            a2 v4
        EOT
        indexed_table = Table::Lazy::Raw::Indexed.new(raw_table, 1)
        # col_index    pivot_class       level  rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            1, Table::Lazy::Pivot::Classes::Column.value   , 0, true,
            0, Table::Lazy::Pivot::Classes::Row.value      , 1, true, # hierarchy
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table)
        hier_pivot_table.size.should eq([4,4])
        hier_pivot_table.to_a2.should eq([
            ["a1", "a1", "a2", "a2"],
            [0   , "v1", 3   , "v4"],
            [1   , "v2", nil , nil ],
            [2   , "v3", nil , nil ]]) # padding test

        hier_pivot_table.hyperplane_add(0, [2,1]).should eq([2,1]) # adding hyperplane to existing non-header cell
        hier_pivot_table.to_a2.should eq([
            ["a1", "a1", "a2", "a2"],
            [0   , "v1", 4   , "v4"],
            [1   , "v2", nil , nil ],
            [2   , "v2", nil , nil ],
            [3   , "v3", nil , nil ]])

        hier_pivot_table.hyperplane_add(0, [0,1]).should eq([0,4]) # adding hyperplane to existing header cell
        hier_pivot_table.to_a2.should eq([
            ["a1", "a1", "a2", "a2", "~new_value_001", "~new_value_001"],
            [0   , "v1", 4   , "v4", 5   , nil ],
            [1   , "v2", nil , nil , nil , nil ],
            [2   , "v2", nil , nil , nil , nil ],
            [3   , "v3", nil , nil , nil , nil ]])
        hier_pivot_table.hyperplane_add(0, [0,2]).should eq([0,6]) # adding hyperplane to existing header cell
        hier_pivot_table.to_a2.should eq([
            ["a1", "a1", "a2", "a2", "~new_value_001", "~new_value_001", "~new_value_002", "~new_value_002"],
            [0   , "v1", 4   , "v4", 5               , nil             , 6               , nil             ],
            [1   , "v2", nil , nil , nil             , nil             , nil             , nil             ],
            [2   , "v2", nil , nil , nil             , nil             , nil             , nil             ],
            [3   , "v3", nil , nil , nil             , nil             , nil             , nil             ]])
        hier_pivot_table.hyperplane_remove(0, [0,4])
        hier_pivot_table.hyperplane_remove(0, [0,4])
        hier_pivot_table.to_a2.should eq([
            ["a1", "a1", "a2", "a2"],
            [0   , "v1", 4   , "v4"],
            [1   , "v2", nil , nil ],
            [2   , "v2", nil , nil ],
            [3   , "v3", nil , nil ]])
    end
    it "checking hyperplane_add use cases on Assignability::Directly" do
        # Name    Task          State         Project     Priority
        raw_table = Helper(BaseCell).string2table(8, <<-EOT)
            c1a r1a c2a r2a a1a a2a a3a ce
            c1a r1a c2b r2a a1b a2b a3b ce
            c1a r1a c2b r2b a1c a2c a3c ce
            c1a r1b c2a r2a a1d a2d a3d ce
            c1a r1b c2b r2b a1e a2e a3e ce
            c1a r1b c2b r2b a1f a2f a3f ce
            c1b r1b c2b r2b a1g a2g a3g ce
        EOT
        indexed_table = Table::Lazy::Raw::Indexed.new(raw_table, 1)
        # the extra column "ce" is not referenced in fieldlist_table and is _not_ showing up in #get_table below!
        # col_index    pivot_class               level     rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            1, Table::Lazy::Pivot::Classes::Column.value   , 0, true,
            3, Table::Lazy::Pivot::Classes::Column.value   , 1, true,  # hierarchy
            2, Table::Lazy::Pivot::Classes::Row.value      , 0, true,
            4, Table::Lazy::Pivot::Classes::Row.value      , 1, true,  # hierarchy
            0, Table::Lazy::Pivot::Classes::Row.value      , 1, true,
            5, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            6, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            7, Table::Lazy::Pivot::Classes::Aggregate.value, 1, false])# line break before
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table)
        hier_pivot_table.size.should eq([15,11])
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "c1a"      , "c1a"      , "c1a", "c1a"      , "c1a", "c1a"      , "c1b"      , "c1b"      , "c1b", "c1b"      ],
            ["r1a"      , NilDeadArea, NilDeadArea, "c2a", "c2a"      , "c2b", "c2b"      , nil        , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , 0          , "a1a", "a2a"      , nil  , nil        , nil        , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , 0          , "a3a", NilDeadArea, nil  , nil        , nil        , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , 1          , nil  , nil        , "a1b", "a2b"      , nil        , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , 1          , nil  , nil        , "a3b", NilDeadArea, nil        , nil        , nil  , nil        ],
            ["r1a"      , "r2b"      , 2          , nil  , nil        , "a1c", "a2c"      , nil        , nil        , nil  , nil        ],
            ["r1a"      , "r2b"      , 2          , nil  , nil        , "a3c", NilDeadArea, nil        , nil        , nil  , nil        ],
            ["r1b"      , NilDeadArea, NilDeadArea, "c2a", "c2a"      , "c2b", "c2b"      , NilDeadArea, NilDeadArea, "c2b", "c2b"      ],
            ["r1b"      , "r2a"      , 3          , "a1d", "a2d"      , nil  , nil        , "r2b"      , 6          , "a1g", "a2g"      ],
            ["r1b"      , "r2a"      , 3          , "a3d", NilDeadArea, nil  , nil        , "r2b"      , 6          , "a3g", NilDeadArea],
            ["r1b"      , "r2b"      , 4          ,  nil , nil        , "a1e", "a2e"      , nil        , nil        , nil  , nil        ],
            ["r1b"      , "r2b"      , 4          ,  nil , nil        , "a3e", NilDeadArea, nil        , nil        , nil  , nil        ],
            ["r1b"      , "r2b"      , 5          ,  nil , nil        , "a1f", "a2f"      , nil        , nil        , nil  , nil        ],
            ["r1b"      , "r2b"      , 5          ,  nil , nil        , "a3f", NilDeadArea, nil        , nil        , nil  , nil        ]]
        )
        indices = [] of Index
        hier_pivot_table.each.with_index2 {|_,index| indices << index.dup}
        ref_table = hier_pivot_table.to_a2
        num_checks = 0
        indices.each do |index|
            if hier_pivot_table.get_assignability(index) == Table::Lazy::Pivot::Assignability::Directly
                index2 = hier_pivot_table.hyperplane_add(0, index)
                hier_pivot_table.hyperplane_remove(0, index2)
                hier_pivot_table.to_a2.should eq(ref_table) # ... but after re-assigning the whole table needs to be in original state
                num_checks += 1
            end
        end
        num_checks.should eq(83) # out of 165
    end
    it "checking assignment use cases (with aggregates)" do
        # Name    Task          State         Project     Priority
        raw_table = Helper(BaseCell).string2table(8, <<-EOT)
            c1a r1a c2a r2a a1a a2a a3a ce
            c1a r1a c2b r2a a1b a2b a3b ce
            c1a r1a c2b r2b a1c a2c a3c ce
            c1a r1b c2a r2a a1d a2d a3d ce
            c1a r1b c2b r2b a1e a2e a3e ce
            c1a r1b c2b r2b a1f a2f a3f ce
            c1b r1b c2b r2b a1g a2g a3g ce
        EOT
        # the extra column "ce" is not referenced in fieldlist_table and is _not_ showing up in #get_table below!
        # col_index    pivot_class     level             rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            2, Table::Lazy::Pivot::Classes::Column.value   , 1, true , # hierarchy
            1, Table::Lazy::Pivot::Classes::Row.value      , 0, true ,
            3, Table::Lazy::Pivot::Classes::Row.value      , 1, true , # hierarchy
            4, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            5, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            6, Table::Lazy::Pivot::Classes::Aggregate.value, 1, false])# line break before
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(raw_table, fieldlist_table)

        # testing behaviour of Hierarchic#[]?
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "c1a"      , "c1a", "c1a"      , "c1a", "c1a"      , "c1b"      , "c1b", "c1b"      ],
            ["r1a"      , NilDeadArea, "c2a", "c2a"      , "c2b", "c2b"      , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , "a1a", "a2a"      , "a1b", "a2b"      , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , "a3a", NilDeadArea, "a3b", NilDeadArea, nil        , nil  , nil        ],
            ["r1a"      , "r2b"      , nil  , nil        , "a1c", "a2c"      , nil        , nil  , nil        ],
            ["r1a"      , "r2b"      , nil  , nil        , "a3c", NilDeadArea, nil        , nil  , nil        ],
            ["r1b"      , NilDeadArea, "c2a", "c2a"      , "c2b", "c2b"      , NilDeadArea, "c2b", "c2b"      ],
            ["r1b"      , "r2a"      , "a1d", "a2d"      , nil  , nil        , "r2b"      , "a1g", "a2g"      ],
            ["r1b"      , "r2a"      , "a3d", NilDeadArea, nil  , nil        , "r2b"      , "a3g", NilDeadArea],
            ["r1b"      , "r2b"      , nil  , nil        , "#2" , "#2"       , nil        , nil  , nil        ],
            ["r1b"      , "r2b"      , nil  , nil        , "#2" , NilDeadArea, nil        , nil  , nil        ]])

        # testing siblings
        hier_pivot_table.get_siblings([0,2]).should eq(%w(c1a c1b))
        hier_pivot_table.get_siblings([4,1]).should eq(%w(r2a r2b))

        # testing behaviour of Hierarchic#get_table
        indices = [] of Index
        hier_pivot_table.each.with_index2 {|_,index| indices << index.dup}
        indices.map {|index| hier_pivot_table.get_table(index).size}.should eq([ # with aggregates tables always have _one_ dim.
            [0], [6], [6], [6], [6], [6], [1], [1], [1],
            [3], [0], [1], [1], [2], [2], [0], [0], [0],
            [3], [2], [1], [1], [1], [1], [0], [0], [0],
            [3], [2], [1], [0], [1], [0], [0], [0], [0],
            [3], [1], [0], [0], [1], [1], [0], [0], [0],
            [3], [1], [0], [0], [1], [0], [0], [0], [0],
            [4], [0], [1], [1], [2], [2], [0], [1], [1],
            [4], [1], [1], [1], [0], [0], [1], [1], [1],
            [4], [1], [1], [0], [0], [0], [1], [1], [0],
            [4], [2], [0], [0], [2], [2], [0], [0], [0],
            [4], [2], [0], [0], [2], [0], [0], [0], [0]])

        # testing behaviour of Hierarchic#get_clusters
        indices.map {|index| hier_pivot_table.get_clusters(index).values.map(&.[0]).join(",")}.should eq([
            ""   , "c1a"        , "c1a"            , "c1a"            , "c1a"            , "c1a"            , "c1b"        , "c1b"            , "c1b"            ,
            "r1a", "c1a,r1a"    , "c1a,r1a,c2a"    , "c1a,r1a,c2a"    , "c1a,r1a,c2b"    , "c1a,r1a,c2b"    , "c1b,r1a"    , "c1b,r1a"        , "c1b,r1a"        ,
            "r1a", "c1a,r1a,r2a", "c1a,r1a,c2a,r2a", "c1a,r1a,c2a,r2a", "c1a,r1a,c2b,r2a", "c1a,r1a,c2b,r2a", "c1b,r1a"    , "c1b,r1a"        , "c1b,r1a"        ,
            "r1a", "c1a,r1a,r2a", "c1a,r1a,c2a,r2a", "c1a,r1a,c2a,r2a", "c1a,r1a,c2b,r2a", "c1a,r1a,c2b,r2a", "c1b,r1a"    , "c1b,r1a"        , "c1b,r1a"        ,
            "r1a", "c1a,r1a,r2b", "c1a,r1a,c2a,r2b", "c1a,r1a,c2a,r2b", "c1a,r1a,c2b,r2b", "c1a,r1a,c2b,r2b", "c1b,r1a"    , "c1b,r1a"        , "c1b,r1a"        ,
            "r1a", "c1a,r1a,r2b", "c1a,r1a,c2a,r2b", "c1a,r1a,c2a,r2b", "c1a,r1a,c2b,r2b", "c1a,r1a,c2b,r2b", "c1b,r1a"    , "c1b,r1a"        , "c1b,r1a"        ,
            "r1b", "c1a,r1b"    , "c1a,r1b,c2a"    , "c1a,r1b,c2a"    , "c1a,r1b,c2b"    , "c1a,r1b,c2b"    , "c1b,r1b"    , "c1b,r1b,c2b"    , "c1b,r1b,c2b"    ,
            "r1b", "c1a,r1b,r2a", "c1a,r1b,c2a,r2a", "c1a,r1b,c2a,r2a", "c1a,r1b,c2b,r2a", "c1a,r1b,c2b,r2a", "c1b,r1b,r2b", "c1b,r1b,c2b,r2b", "c1b,r1b,c2b,r2b",
            "r1b", "c1a,r1b,r2a", "c1a,r1b,c2a,r2a", "c1a,r1b,c2a,r2a", "c1a,r1b,c2b,r2a", "c1a,r1b,c2b,r2a", "c1b,r1b,r2b", "c1b,r1b,c2b,r2b", "c1b,r1b,c2b,r2b",
            "r1b", "c1a,r1b,r2b", "c1a,r1b,c2a,r2b", "c1a,r1b,c2a,r2b", "c1a,r1b,c2b,r2b", "c1a,r1b,c2b,r2b", "c1b,r1b"    , "c1b,r1b,c2b"    , "c1b,r1b,c2b"    ,
            "r1b", "c1a,r1b,r2b", "c1a,r1b,c2a,r2b", "c1a,r1b,c2a,r2b", "c1a,r1b,c2b,r2b", "c1a,r1b,c2b,r2b", "c1b,r1b"    , "c1b,r1b,c2b"    , "c1b,r1b,c2b"    ])

        # testing Hierarchic#get_header_info
        indices.map {|index| hier_pivot_table.get_header_info(index)}.should eq([
            nil      , {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0},
            {true, 0}, nil       , {false, 1}, {false, 1}, {false, 1}, {false, 1}, nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, nil       , {false, 1}, {false, 1}, {false, 1}, {false, 1}, nil       , {false, 1}, {false, 1},
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , {true, 1} , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , {true, 1} , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ])

        # testing Hierarchic#get_assignability
        indices.map {|index| hier_pivot_table.get_assignability(index).to_s}.should eq([
            "Not"     , "Directly", "Directly"  , "Directly"  , "Directly"  , "Directly"  , "Directly"  , "Directly"  , "Directly"  ,
            "Directly", "Not"     , "Directly"  , "Directly"  , "Directly"  , "Directly"  , "Indirectly", "Indirectly", "Indirectly",
            "Directly", "Directly", "Directly"  , "Directly"  , "Directly"  , "Directly"  , "Indirectly", "Indirectly", "Indirectly",
            "Directly", "Directly", "Directly"  , "Not"       , "Directly"  , "Not"       , "Indirectly", "Indirectly", "Indirectly",
            "Directly", "Directly", "Indirectly", "Indirectly", "Directly"  , "Directly"  , "Indirectly", "Indirectly", "Indirectly",
            "Directly", "Directly", "Indirectly", "Indirectly", "Directly"  , "Not"       , "Indirectly", "Indirectly", "Indirectly",
            "Directly", "Not"     , "Directly"  , "Directly"  , "Directly"  , "Directly"  , "Not"       , "Directly"  , "Directly"  ,
            "Directly", "Directly", "Directly"  , "Directly"  , "Indirectly", "Indirectly", "Directly"  , "Directly"  , "Directly"  ,
            "Directly", "Directly", "Directly"  , "Not"       , "Indirectly", "Indirectly", "Directly"  , "Directly"  , "Not"       ,
            "Directly", "Directly", "Indirectly", "Indirectly", "Drilldown" , "Drilldown" , "Indirectly", "Indirectly", "Indirectly",
            "Directly", "Directly", "Indirectly", "Indirectly", "Drilldown" , "Not"       , "Indirectly", "Indirectly", "Indirectly"])

        # testing Hierarchic#get_bounding_box (comprehensive test)
        coverage = Array(Array(Float32)).new(hier_pivot_table.size[0]) {Array(Float32).new(hier_pivot_table.size[1], 0.0)}
        boundings = indices.map do |index|
            bounds = hier_pivot_table.get_bounding_box(index)
            rows = (bounds[0][0]..bounds[1][0])
            cols = (bounds[0][1]..bounds[1][1])
            cluster = nil
            (rows.size*cols.size).should be > 0 # 1. no backward (empty) bounding boxes
            rows.each do |row|
                cols.each do |col|
                    cluster = hier_pivot_table.get_clusters(index).values.join if !cluster
                    cluster.should eq(hier_pivot_table.get_clusters(index).values.join) # 2. should be inline with clusters
                    coverage[row][col] += 1/(rows.size*cols.size)
                end
            end
            bounds.map {|el| "#{'A'+el[1]}#{el[0]}"}.join("")
        end
        coverage.flatten.map {|el| (el*100).to_i}.uniq.should eq([100]) # 3. no gaps, no illegal overlaps
        boundings.should eq ([ # 4. actual data
            #[0    , 1      , -1     , -1     , -1     , -1     , 1      , -1     , -1]          @projections
            "A0A0" , "B0F0" , "B0F0" , "B0F0" , "B0F0" , "B0F0" , "G0I0" , "G0I0" , "G0I0",      # 0,
            "A1A5" , "B1B1" , "C1D1" , "C1D1" , "E1F1" , "E1F1" , "G1I5" , "G1I5" , "G1I5",      # 1,
            "A1A5" , "B2B3" , "C2D3" , "C2D3" , "E2F3" , "E2F3" , "G1I5" , "G1I5" , "G1I5",      # -1,
            "A1A5" , "B2B3" , "C2D3" , "C2D3" , "E2F3" , "E2F3" , "G1I5" , "G1I5" , "G1I5",      # -1,
            "A1A5" , "B4B5" , "C4D5" , "C4D5" , "E4F5" , "E4F5" , "G1I5" , "G1I5" , "G1I5",      # -1,
            "A1A5" , "B4B5" , "C4D5" , "C4D5" , "E4F5" , "E4F5" , "G1I5" , "G1I5" , "G1I5",      # -1,
            "A6A10", "B6B6" , "C6D6" , "C6D6" , "E6F6" , "E6F6" , "G6G6" , "H6I6" , "H6I6",      # 1,
            "A6A10", "B7B8" , "C7D8" , "C7D8" , "E7F8" , "E7F8" , "G7G8" , "H7I8" , "H7I8",      # -1,
            "A6A10", "B7B8" , "C7D8" , "C7D8" , "E7F8" , "E7F8" , "G7G8" , "H7I8" , "H7I8",      # -1,
            "A6A10", "B9B10", "C9D10", "C9D10", "E9F10", "E9F10", "G9I10", "G9I10", "G9I10",     # -1,
            "A6A10", "B9B10", "C9D10", "C9D10", "E9F10", "E9F10", "G9I10", "G9I10", "G9I10"])    # -1
        # TODO(test): G9I10 is not in line with the clusters above — currently a minor issue

        # check, if all Assignability::Directly are really assignable
        ref_table = hier_pivot_table.to_a2
        num_checks = 0
        indices.each do |index|
            if hier_pivot_table.get_assignability(index) == Table::Lazy::Pivot::Assignability::Directly
                old_val = hier_pivot_table[index].as(String)
                new_val = old_val + "_new" # this way will not provoke a move (when assigned to a header cell)
                hier_pivot_table[index] = new_val
                hier_pivot_table[index].should eq(new_val) # we can only check locally (assignment might have a bigger impact)...
                hier_pivot_table[index] = old_val
                hier_pivot_table.to_a2.should eq(ref_table) # ... but after re-assigning the whole table needs to be in original state
                num_checks += 1
            end
        end
        num_checks.should eq(53) # out of 99 (46 are either nil or NilDeadArea or "(2)")

        # check, if all Assignability::Indirectly indices can make a #hyperplane_add (wrt. records)
        ref_table = hier_pivot_table.to_a2
        num_checks = 0
        indices.each do |index|
            if hier_pivot_table.get_assignability(index) == Table::Lazy::Pivot::Assignability::Indirectly
                index2 = hier_pivot_table.hyperplane_add(0, index)
                hier_pivot_table.hyperplane_remove(0, index2)
                hier_pivot_table.to_a2.should eq(ref_table)
                num_checks += 1
            end
        end
        num_checks.should eq(33) # out of 99

        # testing behaviour of Hierarchic#hyperplane_move into a nil area
        hier_pivot_table.hyperplane_move(0, [7,2], [9,7]).should eq([7,7]) # moving to a nil area might lead to a slip
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "c1a"      , "c1a", "c1a"      , "c1a", "c1a"      , "c1b"      , "c1b", "c1b"      ],
            ["r1a"      , NilDeadArea, "c2a", "c2a"      , "c2b", "c2b"      , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , "a1a", "a2a"      , "a1b", "a2b"      , nil        , nil  , nil        ],
            ["r1a"      , "r2a"      , "a3a", NilDeadArea, "a3b", NilDeadArea, nil        , nil  , nil        ],
            ["r1a"      , "r2b"      , nil  , nil        , "a1c", "a2c"      , nil        , nil  , nil        ],
            ["r1a"      , "r2b"      , nil  , nil        , "a3c", NilDeadArea, nil        , nil  , nil        ],
            ["r1b"      , NilDeadArea, "c2b", "c2b"      , nil  , nil        , NilDeadArea, "c2b", "c2b"      ],
            ["r1b"      , "r2b"      , "#2" , "#2"       , nil  , nil        , "r2a"      , "a1d", "a2d"      ],
            ["r1b"      , "r2b"      , "#2" , NilDeadArea, nil  , nil        , "r2a"      , "a3d", NilDeadArea],
            ["r1b"      , nil        , nil  , nil        , nil  , nil        , "r2b"      , "a1g", "a2g"      ],
            ["r1b"      , nil        , nil  , nil        , nil  , nil        , "r2b"      , "a3g", NilDeadArea]])
        indices = [] of Index
        hier_pivot_table.each.with_index2 {|_,index| indices << index.dup}
        indices.map {|index| hier_pivot_table.get_header_info(index)}.should eq([
            nil      , {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0}, {false, 0},
            {true, 0}, nil       , {false, 1}, {false, 1}, {false, 1}, {false, 1}, nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , nil       , nil       , nil       ,
            {true, 0}, nil       , {false, 1}, {false, 1}, nil       , nil       , nil       , {false, 1}, {false, 1},
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , {true, 1} , nil       , nil       ,
            {true, 0}, {true, 1} , nil       , nil       , nil       , nil       , {true, 1} , nil       , nil       ,
            {true, 0}, nil       , nil       , nil       , nil       , nil       , {true, 1} , nil       , nil       ,
            {true, 0}, nil       , nil       , nil       , nil       , nil       , {true, 1} , nil       , nil       ])
    end
    it "checking assignment use cases (without aggregates)" do
        # Name    Task          State         Project     Priority
        raw_table = Helper(BaseCell).string2table(6, <<-EOT)
            c1a r1a c2a r2a a1 a2
            c1a r1a c2b r2a a1 a2
            c1a r1a c2b r2b a1 a2
            c1a r1b c2a r2a a1 a2
            c1a r1b c2b r2b a1 a2
            c1a r1b c2b r2b a1 a2
            c1b r1b c2b r2b a1 a2
        EOT
        # the unused columns "a1" and "a2" are not referenced in fieldlist_table, but _are_ showing up in #get_table below!
        # col_index    pivot_class             level    rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            2, Table::Lazy::Pivot::Classes::Column.value   , 1, true , # hierarchy
            1, Table::Lazy::Pivot::Classes::Row.value      , 0, true ,
            3, Table::Lazy::Pivot::Classes::Row.value      , 1, true   # hierarchy
            ])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(raw_table, fieldlist_table)

        # testing behaviour of Hierarchic#[]?
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "c1a"      , "c1a", "c1a", "c1b"      , "c1b"],
            ["r1a"      , NilDeadArea, "c2a", "c2b", nil        , nil  ],
            ["r1a"      , "r2a"      , "#1" , "#1" , nil        , nil  ],
            ["r1a"      , "r2b"      , nil  , "#1" , nil        , nil  ],
            ["r1b"      , NilDeadArea, "c2a", "c2b", NilDeadArea, "c2b"],
            ["r1b"      , "r2a"      , "#1" , nil  , "r2b"      , "#1" ],
            ["r1b"      , "r2b"      , nil  , "#2" , nil        , nil  ]])

        # testing behaviour of Hierarchic#get_table
        indices = [] of Index
        hier_pivot_table.each.with_index2 {|_,index| indices << index.dup}
        indices.map {|index| hier_pivot_table.get_table(index).size}.should eq([ # without aggregates tables may have _two_ dim.
            [0], [6], [6   ], [6   ], [1], [1   ],
            [3], [0], [1   ], [2   ], [0], [0   ],
            [3], [2], [1, 2], [1, 2], [0], [0   ],
            [3], [1], [0   ], [1, 2], [0], [0   ],
            [4], [0], [1   ], [2   ], [0], [1   ],
            [4], [1], [1, 2], [0   ], [1], [1, 2],
            [4], [2], [0   ], [2, 2], [0], [0   ]])

        # testing behaviour of Hierarchic#get_clusters
        indices.map {|index| hier_pivot_table.get_clusters(index).values.map(&.[0]).join(",")}.should eq([
            ""   , "c1a"        , "c1a"            , "c1a"            , "c1b"        , "c1b"            ,
            "r1a", "c1a,r1a"    , "c1a,r1a,c2a"    , "c1a,r1a,c2b"    , "c1b,r1a"    , "c1b,r1a"        ,
            "r1a", "c1a,r1a,r2a", "c1a,r1a,c2a,r2a", "c1a,r1a,c2b,r2a", "c1b,r1a"    , "c1b,r1a"        ,
            "r1a", "c1a,r1a,r2b", "c1a,r1a,c2a,r2b", "c1a,r1a,c2b,r2b", "c1b,r1a"    , "c1b,r1a"        ,
            "r1b", "c1a,r1b"    , "c1a,r1b,c2a"    , "c1a,r1b,c2b"    , "c1b,r1b"    , "c1b,r1b,c2b"    ,
            "r1b", "c1a,r1b,r2a", "c1a,r1b,c2a,r2a", "c1a,r1b,c2b,r2a", "c1b,r1b,r2b", "c1b,r1b,c2b,r2b",
            "r1b", "c1a,r1b,r2b", "c1a,r1b,c2a,r2b", "c1a,r1b,c2b,r2b", "c1b,r1b"    , "c1b,r1b,c2b"    ])

        hier_pivot_table.hyperplane_add(0).should eq([2,2])
        raw_table.to_a2.should eq([
            ["c1a", "r1a", "c2a", "r2a", "a1", "a2"],
            ["c1a", "r1a", "c2b", "r2a", "a1", "a2"],
            ["c1a", "r1a", "c2b", "r2b", "a1", "a2"],
            ["c1a", "r1b", "c2a", "r2a", "a1", "a2"],
            ["c1a", "r1b", "c2b", "r2b", "a1", "a2"],
            ["c1a", "r1b", "c2b", "r2b", "a1", "a2"],
            ["c1b", "r1b", "c2b", "r2b", "a1", "a2"],
            [nil  , nil  , nil  , nil  , nil , nil ]]
        )
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea,         nil, nil  , "c1a"      , "c1a", "c1a", "c1b"      , "c1b"],
            [nil        , NilDeadArea, nil  , nil        , nil  , nil  , nil        , nil  ],
            [nil        ,         nil, "#1" , nil        , nil  , nil  , nil        , nil  ],
            ["r1a"      ,         nil, nil  , NilDeadArea, "c2a", "c2b", nil        , nil  ],
            ["r1a"      ,         nil, nil  , "r2a"      , "#1" , "#1" , nil        , nil  ],
            ["r1a"      ,         nil, nil  , "r2b"      , nil  , "#1" , nil        , nil  ],
            ["r1b"      ,         nil, nil  , NilDeadArea, "c2a", "c2b", NilDeadArea, "c2b"],
            ["r1b"      ,         nil, nil  , "r2a"      , "#1" , nil  , "r2b"      , "#1" ],
            ["r1b"      ,         nil, nil  , "r2b"      , nil  , "#2" , nil        , nil  ]]
        )

        hier_pivot_table.hyperplane_remove(0, [2,2]) # we undo the last change
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "c1a"      , "c1a", "c1a", "c1b"      , "c1b"],
            ["r1a"      , NilDeadArea, "c2a", "c2b", nil        , nil  ],
            ["r1a"      , "r2a"      , "#1" , "#1" , nil        , nil  ],
            ["r1a"      , "r2b"      , nil  , "#1" , nil        , nil  ],
            ["r1b"      , NilDeadArea, "c2a", "c2b", NilDeadArea, "c2b"],
            ["r1b"      , "r2a"      , "#1" , nil  , "r2b"      , "#1" ],
            ["r1b"      , "r2b"      , nil  , "#2" , nil        , nil  ]])

        hier_pivot_table.hyperplane_add(0, [6,2]).should eq([6,2])
        hier_pivot_table.to_a2.should eq([
            [NilDeadArea, "c1a"      , "c1a", "c1a", "c1b"      , "c1b"],
            ["r1a"      , NilDeadArea, "c2a", "c2b", nil        , nil  ],
            ["r1a"      , "r2a"      , "#1" , "#1" , nil        , nil  ],
            ["r1a"      , "r2b"      , nil  , "#1" , nil        , nil  ],
            ["r1b"      , NilDeadArea, "c2a", "c2b", NilDeadArea, "c2b"],
            ["r1b"      , "r2a"      , "#1" , nil  , "r2b"      , "#1" ],
            ["r1b"      , "r2b"      , "#1" , "#2" , nil        , nil  ]])
    end
    it "testing bounding box within a single Simple with more levels" do
        raw_table = Helper(BaseCell).string2table(5, <<-EOT)
            1 Alan   Boston lawsuiting xy
            2 Denny  Boston lawsuiting xy
        EOT
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            2, Table::Lazy::Pivot::Classes::Column.value   , 0, false,
            1, Table::Lazy::Pivot::Classes::Column.value,    0, true ,
            0, Table::Lazy::Pivot::Classes::Row.value      , 1, true ,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            4, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        matrix_rc = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(raw_table, fieldlist_table)
        matrix_rc.to_a2.should eq([
            ["Boston", "Boston"    , "Boston", "Boston", "Boston"    , "Boston"],
            ["Alan"  , "Alan"      , "Alan"  , "Denny" , "Denny"     , "Denny" ],
            [1       , "lawsuiting", "xy"    , 2       , "lawsuiting", "xy"    ]
        ])
        matrix_rc.get_bounding_box([0,1]).should eq({[0,0], [0,5]})
        matrix_rc.get_bounding_box([0,3]).should eq({[0,0], [0,5]})
        matrix_rc.get_bounding_box([2,1]).should eq({[2,1], [2,2]})
        indices = [] of Table::Index
        matrix_rc.each.with_index2 {|_,index| indices << index.dup}
        boundings = indices.map do |index|
            bounds = matrix_rc.get_bounding_box(index)
            rows = (bounds[0][0]..bounds[1][0])
            cols = (bounds[0][1]..bounds[1][1])
            bounds.map {|el| "#{'A'+el[1]}#{el[0]}"}.join("")
        end
        boundings.should eq(["A0F0", "A0F0", "A0F0", "A0F0", "A0F0", "A0F0", "A1C1", "A1C1", "A1C1", "D1F1", "D1F1", "D1F1", "A2A2", "B2C2", "B2C2", "D2D2", "E2F2", "E2F2"])
    end
    it "testing non-Kanban" do
        raw_table = Helper(BaseCell).string2table(2, <<-EOT)
            A x
            B y
        EOT
        indexed_table = Table::Lazy::Raw::Indexed.new(raw_table, 1)
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            1, Table::Lazy::Pivot::Classes::Column.value   , 0, true,
            0, Table::Lazy::Pivot::Classes::Row.value      , 0, true , # non-Kanban
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        matrix_rc = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table)
        matrix_rc.to_a2.should eq ([[NilDeadArea, "A", "B"], [0, "x", nil], [1, nil, "y"]])
        indices = [] of Index
        matrix_rc.each.with_index2 {|_,index| indices << index.dup}
        indices.map {|index| matrix_rc.get_assignability(index)}.should eq([
            Table::Lazy::Pivot::Assignability::Not     , Table::Lazy::Pivot::Assignability::Directly  , Table::Lazy::Pivot::Assignability::Directly,
            Table::Lazy::Pivot::Assignability::Directly, Table::Lazy::Pivot::Assignability::Directly  , Table::Lazy::Pivot::Assignability::Indirectly,
            Table::Lazy::Pivot::Assignability::Directly, Table::Lazy::Pivot::Assignability::Indirectly, Table::Lazy::Pivot::Assignability::Directly
        ])
        matrix_rc.hyperplane_add(0, [1,2]).should eq([1,2])
        matrix_rc.to_a2.should eq ([[NilDeadArea, "A", "B"], [0, nil, nil], [1, "x", nil], [2, nil, "y"]])
    end
    it "checking drop range bug" do
        # bug seems to happen when in the (outer?) cluster really is an element, but has some padding for the inner cluster
        raw_table = Helper(BaseCell).string2table(4, <<-EOT)
            0 Carol  B  B
            2 Alice  A  A
            3 Bob    A  A
        EOT
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            3,1,0,true,
            1,3,0,true,
            2,2,0,true,
            0,2,1,true
        ])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(BaseCell,BaseCell,FieldlistCell).new(raw_table, fieldlist_table)
        hier_pivot_table.get_scrollorder.should eq ({[1, 2, 3, 0], [2, 1, 4, 3, 0]}) # double check, since is also used internally for bounding
        hier_pivot_table.to_a2.should eq ([
            [NilDeadArea, "A", "A"    , "B", "B"    ],
            ["A"        , 2  , "Alice", nil, nil    ],
            ["A"        , 3  , "Bob"  , nil, nil    ],
            ["B"        , nil, nil    , 0  , "Carol"]
        ])
        hier_pivot_table.get_bounding_box([0,0]).should eq({[0, 0], [0, 0]})
        hier_pivot_table.get_bounding_box([0,1]).should eq({[0, 1], [0, 2]})
        hier_pivot_table.get_bounding_box([0,2]).should eq({[0, 1], [0, 2]})
        hier_pivot_table.get_bounding_box([0,3]).should eq({[0, 3], [0, 4]})
        hier_pivot_table.get_bounding_box([0,4]).should eq({[0, 3], [0, 4]})
        hier_pivot_table.get_bounding_box([1,3]).should eq({[1, 3], [2, 4]})
        hier_pivot_table.get_bounding_box([1,4]).should eq({[1, 3], [2, 4]})
        hier_pivot_table.get_bounding_box([2,3]).should eq({[1, 3], [2, 4]})
        hier_pivot_table.get_bounding_box([2,4]).should eq({[1, 3], [2, 4]})
        hier_pivot_table.get_bounding_box([3,1]).should eq({[3, 1], [3, 2]})
        hier_pivot_table.get_bounding_box([3,2]).should eq({[3, 1], [3, 2]})

        # now, we add the missing row "1 Alice A B"
        index = raw_table.hyperplane_add(0, [] of Int32)
        raw_table[[index[0],0]] = 1i64
        raw_table[[index[0],1]] = "Alice"
        raw_table[[index[0],2]] = "A"
        raw_table[[index[0],3]] = "B"
        hier_pivot_table.to_a2.should eq ([
            [NilDeadArea, "A", "A"    , "B", "B"    ],
            ["A"        , 2  , "Alice", 1  , "Alice"], # "1, Alice" added, size unchanged
            ["A"        , 3  , "Bob"  , nil, nil    ],
            ["B"        , nil, nil    , 0  , "Carol"]
        ])
        hier_pivot_table.get_bounding_box([1,3]).should eq({[1, 3], [1, 3]})
        hier_pivot_table.get_bounding_box([3,1]).should eq({[3, 1], [3, 2]})

        hier_pivot_table.get_bounding_box([2,3]).should eq({[2, 3], [2, 4]})
        hier_pivot_table.get_bounding_box([2,4]).should eq({[2, 3], [2, 4]})

        # testing Hierarchic#get_bounding_box (comprehensive test)
        indices = [] of Index
        hier_pivot_table.each.with_index2 {|_,index| indices << index.dup}
        coverage = Array(Array(Float32)).new(hier_pivot_table.size[0]) {Array(Float32).new(hier_pivot_table.size[1], 0.0)}
        indices.each do |index|
            bounds = hier_pivot_table.get_bounding_box(index)
            rows = (bounds[0][0]..bounds[1][0])
            cols = (bounds[0][1]..bounds[1][1])
            cluster = nil
            (rows.size*cols.size).should be > 0 # 1. no backward (empty) bounding boxes
            rows.each do |row|
                cols.each do |col|
                    cluster = hier_pivot_table.get_clusters(index).values.join if !cluster
                    cluster.should eq(hier_pivot_table.get_clusters(index).values.join) # 2. should be inline with clusters
                    coverage[row][col] += 1/(rows.size*cols.size)
                end
            end
        end
        coverage.flatten.map {|el| (el*100).to_i}.uniq.should eq([100]) # 3. no gaps, no illegal overlaps
    end
end

{% if false %}
{% end %}
