require "spec"
require "../../spec/spec_helper"
require "../../src/table/raw"
require "../../src/table/pivot"
require "../../src/global"
require "../../src/virtualtable"
require "../../src/persistency"

include Table::VirtualTable
include Table

private def ref2rankvalue(arg)
    arg.map do |row|
        row.map {|el| el.is_a?(ReferenceCell(BaseCell)) ? el.rank.to_s+"-"+el.value.to_s : el}
    end
end

module SpecHelpers::VTPivot
    def self.setup
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
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
            Nowhere

            cities
            city    | liesin_country
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city | eyecolor_color
            Sauron  | Mordor       | Red
            Samwise | Shire        | Brown
            Alan    | Boston       | Blue
            Denny   | Boston       | Hazel

            indirecttask
            who2_name  | project1
            Alan       | lawsuiting

            days
            day
            Monday
            Tuesday
            Wednesday
            Thursday
            Friday

            indirectallocation
            who_name | d_day | participating

            directallocation
            amount  | name2   | project2    | q
            10.0    | Carol   | Alpha        | Q1
            10      | Alice   | Beta         | Q3
            50      | Carol   | Alpha        | Q3
            10      | Carol   | Alpha        | Q4
            100     | Alice   | Beta         | Q4
            80      | Carol   | Gamma    | Q1
            100     | Carol   | Gamma    | Q2
            100     | Alice   | Gamma    | Q4
            100     | Bob     | Gamma    | Q4
            80      | Alice   | Gamma    | Q2

            directtasks
            name3   | task          | state         | project3    | priority
            Carol   | Design        | 1-Ready       | Alpha        | 1-High
            Alice   | Code          | 2-InWork      | Beta         | 1-High
            Carol   | Architecture  | 2-InWork      | Alpha        | 1-High
            Carol   | Requirement   | 3-Done        | Alpha        | 2-Medium
            Alice   | Test          | 3-Done        | Beta         | 2-Medium
            Carol   | Design        | 1-Ready       | Gamma    | 2-Medium
            Carol   | Test          | 2-InWork      | Gamma    | 2-Medium
            Alice   | Test          | 2-InWork      | Gamma    | 3-Low
            Bob     | Code          | 2-InWork      | Gamma    | 3-Low
            Alice   | Code          | 1-Ready       | Gamma    | 3-Low

            flrows
            flr
            flr1
            flr2

            flcols
            flc
            flc1
            flc2

            flclasses
            flcl  | flrr_flr  | flcc_flc
            flunu | flr1      | flc1
            flcol | flr1      | flc2
            flrow | flr2      | flc1
            flagg | flr2      | flc2

            fieldlist
            flclass_flcl | flasc | flhier

            hcsatt
            hcsatr
            hclow
            hchigh

            hchuet
            hchuer
            hcgreen
            hcred

            hct
            hccol       | hchue_hchuer | hcsat_hcsatr
            hcgraygreen | hcgreen      | hclow
            hcfullgreen | hcgreen      | hchigh
            hcgrayred   | hcred        | hclow
            hcfullred   | hcred        | hchigh

            hcmyt
            hcmycol_hccol
            hcgraygreen
        EOT
        {persistency, hash}
    end
end

describe Table::Lazy::Pivot do
    it "works" do
        # the following line is a crystal compiler bug workaround (c.f. https://github.com/crystal-lang/crystal/issues/13935)
        Table::Lazy::Pivot::Simple(Cell,BaseCell).new(Helper(Cell).string2table(4, ""), Hash(Int32,Int32).new,
            [] of {column: Int32, sort_asc?: Bool}, [] of {column: Int32, sort_asc?: Bool})

        # preparation: DB structure
        l = Persistency::Default.new
        t_states = l.add_table("status")
        f_states = l.add_field(t_states, "status")
        r_todo = l.add_record(t_states)
        l.set_value(f_states, r_todo, "todo")
        r_in_work = l.add_record(t_states)
        l.set_value(f_states, r_in_work, "in work")
        r_done = l.add_record(t_states)
        l.set_value(f_states, r_done, "done")

        t_prios = l.add_table("prios")
        f_prios = l.add_field(t_prios, "prio")
        r_low = l.add_record(t_prios)
        l.set_value(f_prios, r_low, "low")
        r_mid = l.add_record(t_prios)
        l.set_value(f_prios, r_mid, "mid")
        r_high = l.add_record(t_prios)
        l.set_value(f_prios, r_high, "high")

        t_tasks = l.add_table("tasks")
        f_tasks_status = l.add_field(t_tasks, "status", f_states)
        f_tasks_prio = l.add_field(t_tasks, "prio", f_prios)

        # preparation: DB content
        r1 = l.add_record(t_tasks)
        l.set_value(f_tasks_status, r1, r_in_work)
        l.set_value(f_tasks_prio, r1, r_low)
        r2 = l.add_record(t_tasks)
        l.set_value(f_tasks_status, r2, r_todo)
        l.set_value(f_tasks_prio, r2, r_low)

        # preparation: VT structure
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, t_tasks)
        c.toggle_select(c.tree)

        # running query
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq([
            [1, "2-in work", "1-low"],
            [2, "1-todo"   , "1-low"]])

        # creating shape
        # col_name    pivot_class                                   level       rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            1,     Table::Lazy::Pivot::Classes::Column.value,            0, true,
            0,     Table::Lazy::Pivot::Classes::Aggregate.value,         0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)

        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        hier_pivot_table.size.should eq([2,2])

        c.toggle_expand(c.tree[f_tasks_status])
        c.toggle_expand(c.tree[f_tasks_status][f_states])
        c.toggle_select(c.tree[f_tasks_status][f_states][PseudoFields::ShowAll]) # this alone doesn't trigger DB FULL JOIN (anymore)...
        c.toggle_select(c.tree[f_tasks_status][f_states][f_states]) # ... hence we need to select sth. from fields as well
        ref2rankvalue(vt.to_a2).should eq([
            [1        , "2-in work", "1-low"  , "in work" ],
            [2        , "1-todo"   , "1-low"  , "todo"    ],
            [NilRecord, NilRecord  , NilRecord, "done"    ]])

        hier_pivot_table.size.should eq([2,4])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilRecord, "1-todo", "2-in work", "3-done"],
            [NilRecord, 2       , 1          , nil     ]]
        )

        # now we test some tricky border cases; this also checks stacked reference tags and references
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            3,     Table::Lazy::Pivot::Classes::Column.value,            0, true, # i.e. sort lexicographically by referenced field
            1,     Table::Lazy::Pivot::Classes::Column.value,            0, true,
            0,     Table::Lazy::Pivot::Classes::Aggregate.value,         0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["done"   , "done"  , "in work"  , "todo"  ],
            [NilRecord, "3-done", "2-in work", "1-todo"],
            [NilRecord, nil     , 1          , 2       ]])

        # TODO(test): moving a cell that contains NilRecord into another cell — clarify whether this should be allowed
        frozen = l.context.current_commit
        l.close_and_add_commit
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_move(0, [2,0], [2,2])#.should eq([])
            ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["in work", "in work"  , "todo"  ],
            [NilRecord, "2-in work", "1-todo"],
            [NilRecord, 1          , 2       ]])
        end

        # moving a cell into a cluster where the cluster header has a NilRecord
        l.context.current_commit = frozen
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_move(0, [2,2], [1,0])#.should eq([])
            ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["done" , "done" , "todo" ],
            [NilRecord, "2-done", "1-todo"],
            [NilRecord, 1 , 2 ]])
        end
    end
end

describe Table::Lazy::Pivot do
    it "works" do
        # preparation: DB structure
        l = Persistency::Default.new
        t_states = l.add_table("status")
        f_states = l.add_field(t_states, "status")
        t_prios = l.add_table("prios")
        f_prios = l.add_field(t_prios, "prio")
        t_tasks = l.add_table("tasks")
        f_name = l.add_field(t_tasks, "name")
        f_project = l.add_field(t_tasks, "project")
        f_tasks_status = l.add_field(t_tasks, "status", f_states)
        f_tasks_prio = l.add_field(t_tasks, "prio", f_prios)
        f_text = l.add_field(t_tasks, "text")
        # preparation: enums
        r_todo = l.add_record(t_states)
        l.set_value(f_states, r_todo, "todo")
        r_in_work = l.add_record(t_states)
        l.set_value(f_states, r_in_work, "in work")
        r_done = l.add_record(t_states)
        l.set_value(f_states, r_done, "done")
        r_low = l.add_record(t_prios)
        l.set_value(f_prios, r_low, "low")
        r_mid = l.add_record(t_prios)
        l.set_value(f_prios, r_mid, "mid")
        r_high = l.add_record(t_prios)
        l.set_value(f_prios, r_high, "high")
        # preparation: DB content
        r1 = l.add_record(t_tasks)
        l.set_value(f_name, r1, "Alice")
        l.set_value(f_project, r1, "Alpha")
        l.set_value(f_tasks_status, r1, r_todo)
        # l.set_value(f_tasks_prio, r1, nil) # not yet assigned
        l.set_value(f_text, r1, "task #1")
        r2 = l.add_record(t_tasks)
        l.set_value(f_name, r2, "Alice")
        l.set_value(f_project, r2, "Alpha")
        l.set_value(f_tasks_status, r2, r_done)
        l.set_value(f_tasks_prio, r2, r_mid)
        l.set_value(f_text, r2, "task #2")
        r3 = l.add_record(t_tasks)
        l.set_value(f_name, r3, "Alice")
        l.set_value(f_project, r3, "Beta")
        l.set_value(f_tasks_status, r3, r_in_work)
        l.set_value(f_tasks_prio, r3, r_high)
        l.set_value(f_text, r3, "task #3")
        r4 = l.add_record(t_tasks)
        l.set_value(f_name, r4, "Bob")
        l.set_value(f_project, r4, "Beta")
        l.set_value(f_tasks_status, r4, r_in_work)
        l.set_value(f_tasks_prio, r4, r_mid)
        l.set_value(f_text, r4, "task #4")
        # preparation: VT structure
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, t_tasks)
        c.toggle_expand(c.tree[f_tasks_status])
        c.toggle_expand(c.tree[f_tasks_status][f_states])
        c.toggle_expand(c.tree[f_tasks_prio])
        c.toggle_expand(c.tree[f_tasks_prio][f_prios])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[PseudoFields::ShowAll])
        c.toggle_select(c.tree[f_tasks_status][f_states][PseudoFields::ShowAll])
        c.toggle_select(c.tree[f_tasks_prio][f_prios][PseudoFields::ShowAll])
        # c.toggle_select(c.tree[f_tasks_status][f_states])
        # c.toggle_select(c.tree[f_tasks_prio][f_prios])

        # running query
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq(
            # rank name     project *status    *prio              text      statusrank status     priorank prio
            [[1, "Alice", "Alpha", "1-todo"   , "0-(no reference)", "task #1"]  ,# 1, "todo"   , NilRecord, NilRecord],
            [ 2, "Alice", "Alpha", "3-done"   , "2-mid"           , "task #2"]  ,# 3, "done"   , 2        , "mid"    ],
            [ 3, "Alice", "Beta" , "2-in work", "3-high"          , "task #3"]  ,# 2, "in work", 3        , "high"   ],
            [ 4, "Bob"  , "Beta" , "2-in work", "2-mid"           , "task #4"]]#,  2, "in work", 2        , "mid"    ]]
        )

        # creating shape
        # col_name    pivot_class                                     level         rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            3,     Table::Lazy::Pivot::Classes::Column.value,          0,   true,
            4,     Table::Lazy::Pivot::Classes::Column.value,          0,   true,
            2,     Table::Lazy::Pivot::Classes::Row.value,             0,   true,
            1,     Table::Lazy::Pivot::Classes::Row.value,             0,   true,
            5,     Table::Lazy::Pivot::Classes::Aggregate.value,       0,   false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)

        # # a non-VT alternative, yields a Shape size of [5,6]
        # raw_table = Helper(Cell).string2table(5, <<-EOT)
        #     Alice Alpha todo noref task1
        #     Alice Alpha done mid task2
        #     Alice Beta in_work high task3
        #     Bob Beta in_work mid task4
        #     EOT
        # indexed_table = Table::Lazy::Raw::Indexed.new(raw_table, 1)
        # hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(indexed_table, fieldlist_table)
        # p hier_pivot_table.size

        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        hier_pivot_table.size.should eq([5,12])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, NilDeadArea, "1-todo", "1-todo", "1-todo", "1-todo", "2-in work", "2-in work", "2-in work", "3-done", "3-done", "3-done"],
            [NilDeadArea, NilDeadArea, "0-(no reference)", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high"],
            ["Alpha", "Alice", "task #1", nil, nil, nil, nil, nil, nil, nil, "task #2", nil],
            ["Beta", "Alice", nil, nil, nil, nil, nil, nil, "task #3", nil, nil, nil],
            ["Beta", "Bob", nil, nil, nil, nil, nil, "task #4", nil, nil, nil, nil]
        ])

        tabs = [] of Int32?
        hier_pivot_table.size[0].times do |ri|
            hier_pivot_table.size[1].times do |ci|
                c = hier_pivot_table.get_table([ri,ci])
                tabs << c.size[0]
            end
        end
        tabs.should eq([0, 0, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0])
        tabs = [] of Array({Int32, Cell})
        hier_pivot_table.size[0].times do |ri|
            hier_pivot_table.size[1].times do |ci|
                c = hier_pivot_table.get_clusters([ri,ci]).map do |el|
                    {el[0], el[1][0].is_a?(ReferenceCell) ? el[1][0].as(ReferenceCell).value : el[1][0]}
                end
                tabs << c
            end
        end
        tabs.should eq([[] of Array({Int32, Cell}), [] of Array({Int32, Cell}), [{3, "todo"}], [{3, "todo"}], [{3, "todo"}], [{3, "todo"}], [{3, "in work"}], [{3, "in work"}], [{3, "in work"}], [{3, "done"}], [{3, "done"}], [{3, "done"}], [] of Array({Int32, Cell}), [] of Array({Int32, Cell}), [{3, "todo"}, {4, "(no reference)"}], [{3, "todo"}, {4, "low"}], [{3, "todo"}, {4, "mid"}], [{3, "todo"}, {4, "high"}], [{3, "in work"}, {4, "low"}], [{3, "in work"}, {4, "mid"}], [{3, "in work"}, {4, "high"}], [{3, "done"}, {4, "low"}], [{3, "done"}, {4, "mid"}], [{3, "done"}, {4, "high"}], [{2, "Alpha"}], [{2, "Alpha"}, {1, "Alice"}], [{3, "todo"}, {4, "(no reference)"}, {2, "Alpha"}, {1, "Alice"}], [{3, "todo"}, {4, "low"}, {2, "Alpha"}, {1, "Alice"}], [{3, "todo"}, {4, "mid"}, {2, "Alpha"}, {1, "Alice"}], [{3, "todo"}, {4, "high"}, {2, "Alpha"}, {1, "Alice"}], [{3, "in work"}, {4, "low"}, {2, "Alpha"}, {1, "Alice"}], [{3, "in work"}, {4, "mid"}, {2, "Alpha"}, {1, "Alice"}], [{3, "in work"}, {4, "high"}, {2, "Alpha"}, {1, "Alice"}], [{3, "done"}, {4, "low"}, {2, "Alpha"}, {1, "Alice"}], [{3, "done"}, {4, "mid"}, {2, "Alpha"}, {1, "Alice"}], [{3, "done"}, {4, "high"}, {2, "Alpha"}, {1, "Alice"}], [{2, "Beta"}], [{2, "Beta"}, {1, "Alice"}], [{3, "todo"}, {4, "(no reference)"}, {2, "Beta"}, {1, "Alice"}], [{3, "todo"}, {4, "low"}, {2, "Beta"}, {1, "Alice"}], [{3, "todo"}, {4, "mid"}, {2, "Beta"}, {1, "Alice"}], [{3, "todo"}, {4, "high"}, {2, "Beta"}, {1, "Alice"}], [{3, "in work"}, {4, "low"}, {2, "Beta"}, {1, "Alice"}], [{3, "in work"}, {4, "mid"}, {2, "Beta"}, {1, "Alice"}], [{3, "in work"}, {4, "high"}, {2, "Beta"}, {1, "Alice"}], [{3, "done"}, {4, "low"}, {2, "Beta"}, {1, "Alice"}], [{3, "done"}, {4, "mid"}, {2, "Beta"}, {1, "Alice"}], [{3, "done"}, {4, "high"}, {2, "Beta"}, {1, "Alice"}], [{2, "Beta"}], [{2, "Beta"}, {1, "Bob"}], [{3, "todo"}, {4, "(no reference)"}, {2, "Beta"}, {1, "Bob"}], [{3, "todo"}, {4, "low"}, {2, "Beta"}, {1, "Bob"}], [{3, "todo"}, {4, "mid"}, {2, "Beta"}, {1, "Bob"}], [{3, "todo"}, {4, "high"}, {2, "Beta"}, {1, "Bob"}], [{3, "in work"}, {4, "low"}, {2, "Beta"}, {1, "Bob"}], [{3, "in work"}, {4, "mid"}, {2, "Beta"}, {1, "Bob"}], [{3, "in work"}, {4, "high"}, {2, "Beta"}, {1, "Bob"}], [{3, "done"}, {4, "low"}, {2, "Beta"}, {1, "Bob"}], [{3, "done"}, {4, "mid"}, {2, "Beta"}, {1, "Bob"}], [{3, "done"}, {4, "high"}, {2, "Beta"}, {1, "Bob"}]])

        # now we start modifying
        (hier_pivot_table[[2,2]] = "mytask").should eq([2,2])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, NilDeadArea, "1-todo", "1-todo", "1-todo", "1-todo", "2-in work", "2-in work", "2-in work", "3-done", "3-done", "3-done"],
            [NilDeadArea, NilDeadArea, "0-(no reference)", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high"],
            ["Alpha", "Alice", "mytask", nil, nil, nil, nil, nil, nil, nil, "task #2", nil],
            ["Beta", "Alice", nil, nil, nil, nil, nil, nil, "task #3", nil, nil, nil],
            ["Beta", "Bob", nil, nil, nil, nil, nil, "task #4", nil, nil, nil, nil]
        ])
        (hier_pivot_table[[3,0]] = "Gamma").should eq([3,0])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, NilDeadArea, "1-todo", "1-todo", "1-todo", "1-todo", "2-in work", "2-in work", "2-in work", "3-done", "3-done", "3-done"],
            [NilDeadArea, NilDeadArea, "0-(no reference)", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high"],
            ["Alpha", "Alice", "mytask", nil, nil, nil, nil, nil, nil, nil, "task #2", nil],
            ["Gamma", "Alice", nil, nil, nil, nil, nil, nil, "task #3", nil, nil, nil],
            ["Gamma", "Bob", nil, nil, nil, nil, nil, "task #4", nil, nil, nil, nil]
        ])
        (hier_pivot_table[[2,1]] = "Aaron").should eq([2,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, NilDeadArea, "1-todo", "1-todo", "1-todo", "1-todo", "2-in work", "2-in work", "2-in work", "3-done", "3-done", "3-done"],
            [NilDeadArea, NilDeadArea, "0-(no reference)", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high"],
            ["Alpha", "Aaron", "mytask", nil, nil, nil, nil, nil, nil, nil, "task #2", nil],
            ["Gamma", "Alice", nil, nil, nil, nil, nil, nil, "task #3", nil, nil, nil],
            ["Gamma", "Bob", nil, nil, nil, nil, nil, "task #4", nil, nil, nil, nil]
        ])
        hier_pivot_table[[0,2]].class.should eq(ReferenceCell(BaseCell)) # returns a reference cell...
        hier_pivot_table[[0,3]].as(ReferenceCell).value = "tbd" # ... but can be written to with non-reference type (global rename); the other use case is further down
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, NilDeadArea, "1-tbd", "1-tbd", "1-tbd", "1-tbd", "2-in work", "2-in work", "2-in work", "3-done", "3-done", "3-done"],
            [NilDeadArea, NilDeadArea, "0-(no reference)", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high", "1-low", "2-mid", "3-high"],
            ["Alpha", "Aaron", "mytask", nil, nil, nil, nil, nil, nil, nil, "task #2", nil],
            ["Gamma", "Alice", nil, nil, nil, nil, nil, nil, "task #3", nil, nil, nil],
            ["Gamma", "Bob", nil, nil, nil, nil, nil, "task #4", nil, nil, nil, nil]
        ])
        hier_pivot_table[[1,10]].as(ReferenceCell).value = "medium" # global rename
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, NilDeadArea, "1-tbd", "1-tbd", "1-tbd", "1-tbd", "2-in work", "2-in work", "2-in work", "3-done", "3-done", "3-done"],
            [NilDeadArea, NilDeadArea, "0-(no reference)", "1-low", "2-medium", "3-high", "1-low", "2-medium", "3-high", "1-low", "2-medium", "3-high"],
            ["Alpha", "Aaron", "mytask", nil, nil, nil, nil, nil, nil, nil, "task #2", nil],
            ["Gamma", "Alice", nil, nil, nil, nil, nil, nil, "task #3", nil, nil, nil],
            ["Gamma", "Bob", nil, nil, nil, nil, nil, "task #4", nil, nil, nil, nil]
        ])

        # col_name    pivot_class                                   level       rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            3,     Table::Lazy::Pivot::Classes::Column.value,            0, true,
            0,     Table::Lazy::Pivot::Classes::Row.value,               0, true,
            4,     Table::Lazy::Pivot::Classes::Aggregate.value,         0, false,
            1,     Table::Lazy::Pivot::Classes::Aggregate.value,         0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)

        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        hier_pivot_table.size.should eq([5,7])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-tbd"           , "1-tbd", "2-in work", "2-in work", "3-done"  , "3-done"],
            [1          , "0-(no reference)", "Aaron", nil        , nil        , nil       , nil     ],
            [2          , nil               , nil    , nil        , nil        , "2-medium", "Aaron" ],
            [3          , nil               , nil    , "3-high"   , "Alice"    , nil       , nil     ],
            [4          , nil               , nil    , "2-medium" , "Bob"      , nil       , nil     ]
        ])
        rc = hier_pivot_table[[2,5]].as(ReferenceCell) # returns a reference cell
        rc.rank = 1 # changing in dropdown from "medium" to "low"
        (hier_pivot_table[[2,5]] = rc).should eq([2,5]) # writing back as a ReferenceCell
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-tbd"           , "1-tbd", "2-in work", "2-in work", "3-done", "3-done"],
            [1          , "0-(no reference)", "Aaron", nil        , nil        , nil     , nil     ],
            [2          , nil               , nil    , nil        , nil        , "1-low" , "Aaron" ],
            [3          , nil               , nil    , "3-high"   , "Alice"    , nil     , nil     ],
            [4          , nil               , nil    , "2-medium" , "Bob"      , nil     , nil     ]
        ])
        rc = hier_pivot_table[[1,1]].as(ReferenceCell)
        rc.rank = 3 # changing in dropdown from "(no reference)" to "high"
        (hier_pivot_table[[1,1]] = rc).should eq([1,1]) # writing back
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-tbd" , "1-tbd", "2-in work", "2-in work", "3-done", "3-done"],
            [1          , "3-high", "Aaron", nil        , nil        , nil     , nil     ],
            [2          , nil     , nil    , nil        , nil        , "1-low" , "Aaron" ],
            [3          , nil     , nil    , "3-high"   , "Alice"    , nil     , nil     ],
            [4          , nil     , nil    , "2-medium" , "Bob"      , nil     , nil     ]
        ])
        hier_pivot_table.hyperplane_move(0, [4,3], [3,1]).should eq([3,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-tbd"   , "1-tbd", "2-in work", "2-in work", "3-done", "3-done"],
            [1          , "3-high"  , "Aaron", nil        , nil        , nil     , nil     ],
            [2          , nil       , nil    , nil        , nil        , "1-low" , "Aaron" ],
            [3          , "2-medium", "Bob"  , nil        , nil        , nil     , nil     ],
            [4          , nil       , nil    , "3-high"   , "Alice"    , nil     , nil     ]
        ])
        hier_pivot_table.hyperplane_move(0, [3,1], [4,1]).should eq([4,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-tbd"   , "1-tbd", "2-in work", "2-in work", "3-done", "3-done"],
            [1          , "3-high"  , "Aaron", nil        , nil        , nil     , nil     ],
            [2          , nil       , nil    , nil        , nil        , "1-low" , "Aaron" ],
            [3          , nil       , nil    , "3-high"   , "Alice"    , nil     , nil     ],
            [4          , "2-medium", "Bob"  , nil        , nil        , nil     , nil     ]
        ])
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
            Nowhere

            cities
            city    | liesin_country
            Mordor  | MiddleEarth
            Shire   | MiddleEarth
            Boston  | USA
            Seattle | USA

            persons
            name    | livesin_city | eyecolor_color
            Sauron  | Mordor       | Red
            Samwise | Shire        | Brown
            Alan    | Boston       | Blue
            Denny   | Boston       | Hazel
        EOT

        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["persons"])
        c.toggle_expand(c.tree[hash["livesin"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
        c.toggle_expand(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]][hash["country"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]])
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["city"]])
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["livesin"]][hash["city"]][hash["liesin"]][hash["country"]][PseudoFields::ShowAll])
        # layout: rank, name, livesin (ref), eyecolor (ref), city, country (ref)
        vt = c.run
        ref2rankvalue(vt.to_a2).should eq([
            [1        , "Sauron"  , "1-Mordor" , "1-Red"    , "Mordor"  , "1-MiddleEarth" ],
            [2        , "Samwise" , "2-Shire"  , "3-Brown"  , "Shire"   , "1-MiddleEarth" ],
            [3        , "Alan"    , "3-Boston" , "5-Blue"   , "Boston"  , "2-USA"         ],
            [4        , "Denny"   , "3-Boston" , "4-Hazel"  , "Boston"  , "2-USA"         ],
            [NilRecord, NilRecord , NilRecord  , NilRecord  , "Seattle" , "2-USA"         ]]
        )

        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            5, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            2, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            4, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            0, Table::Lazy::Pivot::Classes::Row.value      , 1, true , # kanban style
            1, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)

        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "2-USA"  , "2-USA"  , "2-USA"  , "2-USA"   , "2-USA"    , "2-USA"    , "2-USA"     , "3-Nowhere" ],
            ["1-Mordor"     , "1-Mordor"     , "1-Mordor"     , "2-Shire"      , "2-Shire"      , "2-Shire"      , NilRecord, NilRecord, NilRecord, "3-Boston", "3-Boston" , "3-Boston" , "4-Seattle" , nil         ],
            ["Mordor"       , "Mordor"       , "Mordor"       , "Shire"        , "Shire"        , "Shire"        , "Seattle", "Seattle", "Seattle", "Boston"  , "Boston"   , "Boston"   , nil         , nil         ],
            [1              , "Sauron"       , "1-Red"        , 2              , "Samwise"      , "3-Brown"      , NilRecord, NilRecord, NilRecord, 3         , "Alan"     , "5-Blue"   , nil         , nil         ],
            [nil            , nil            , nil            , nil            , nil            , nil            , nil      , nil      , nil      , 4         , "Denny"    , "4-Hazel"  , nil         , nil         ]]
        )

        (hier_pivot_table[[4,9]] = 1i64).should eq([3,9]) # assigning to a rank cell; returns proper new index
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "2-USA"  , "2-USA"  , "2-USA"  , "2-USA"   , "2-USA"    , "2-USA"    , "2-USA"     , "3-Nowhere" ],
            ["1-Mordor"     , "1-Mordor"     , "1-Mordor"     , "2-Shire"      , "2-Shire"      , "2-Shire"      , NilRecord, NilRecord, NilRecord, "3-Boston", "3-Boston" , "3-Boston" , "4-Seattle" , nil         ],
            ["Mordor"       , "Mordor"       , "Mordor"       , "Shire"        , "Shire"        , "Shire"        , "Seattle", "Seattle", "Seattle", "Boston"  , "Boston"   , "Boston"   , nil         , nil         ],
            [2              , "Sauron"       , "1-Red"        , 3              , "Samwise"      , "3-Brown"      , NilRecord, NilRecord, NilRecord, 1         , "Denny"    , "4-Hazel"   , nil         , nil         ],
            [nil            , nil            , nil            , nil            , nil            , nil            , nil      , nil      , nil      , 4         , "Alan"    , "5-Blue"  , nil         , nil         ]]
        )
        (hier_pivot_table[[3,9]] = 4i64).should eq([4,9])

        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            5, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            4, Table::Lazy::Pivot::Classes::Column.value   , 0, true , # we just exchange columns 4 and 2 here
            2, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            0, Table::Lazy::Pivot::Classes::Row.value      , 1, true , # kanban style
            1, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)

        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "1-MiddleEarth", "2-USA"   , "2-USA"    , "2-USA"    , "2-USA"  , "2-USA"  , "2-USA"  , "2-USA"    , "3-Nowhere" ],
            ["Mordor"       , "Mordor"       , "Mordor"       , "Shire"        , "Shire"        , "Shire"        , "Boston"  , "Boston"   , "Boston"   , "Seattle", "Seattle", "Seattle", "Seattle"  , nil         ],
            ["1-Mordor"     , "1-Mordor"     , "1-Mordor"     , "2-Shire"      , "2-Shire"      , "2-Shire"      , "3-Boston", "3-Boston" , "3-Boston" , NilRecord, NilRecord, NilRecord, "4-Seattle", nil         ],
            [1              , "Sauron"       , "1-Red"        , 2              , "Samwise"      , "3-Brown"      , 3         , "Alan"     , "5-Blue"   , NilRecord, NilRecord, NilRecord, nil        , nil         ],
            [nil            , nil            , nil            , nil            , nil            , nil            , 4         , "Denny"    , "4-Hazel"  , nil      , nil      , nil      , nil        , nil         ]]
        )

        # testing constraints of header cell
        cell = hier_pivot_table[[2,0]].as(ReferenceCell(BaseCell))
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor)) # constrained as in pivot (i.e. non-ReferenceCell in [1,0] is constraining!)

        cell.constrain({} of Int32=>Int32)
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor Shire Boston Seattle))

        cell.constrain({5 => 1}) # VT column 5, 1 is the rank of country "MiddleEarth"
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor Shire))

        cell.constrain({5 => 1, 4 => 1}) # VT column 5, 1 is the rank of country "MiddleEarth", VT column 4, 1 is the rank of city Mordor
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor))

        cell.constrain({4 => 1}) # VT column 4, 1 is the rank of city Mordor
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor))

        cell.constrain({5 => 2}) # VT column 5, 2 is the rank of country "USA"
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Boston Seattle))

        hier_pivot_table.each.map {|el| el.is_a?(ReferenceCell(BaseCell)) ?
            el.each_defined_fulfilling.map {|e| e.rank.to_s+"-"+e.value.to_s}.join("/") : el.to_s}.join("; ").gsub("Struct()","").should eq(
                "1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; 1-MiddleEarth/2-USA/3-Nowhere; Mordor; Mordor; Mordor; Shire; Shire; Shire; Boston; Boston; Boston; Seattle; Seattle; Seattle; Seattle; ; 3-Boston/4-Seattle; 3-Boston/4-Seattle; 3-Boston/4-Seattle; 2-Shire; 2-Shire; 2-Shire; 3-Boston; 3-Boston; 3-Boston; NilRecord; NilRecord; NilRecord; 4-Seattle; ; 1; Sauron; 1-Red/2-Grey/3-Brown/4-Hazel/5-Blue/6-Silver; 2; Samwise; 1-Red/2-Grey/3-Brown/4-Hazel/5-Blue/6-Silver; 3; Alan; 1-Red/2-Grey/3-Brown/4-Hazel/5-Blue/6-Silver; NilRecord; NilRecord; NilRecord; ; ; ; ; ; ; ; ; 4; Denny; 1-Red/2-Grey/3-Brown/4-Hazel/5-Blue/6-Silver; ; ; ; ; ")

        # testing constraint of intersection cell
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            5, Table::Lazy::Pivot::Classes::Column.value    , 0, true ,
            0, Table::Lazy::Pivot::Classes::Row.value       , 1, true ,
            2, Table::Lazy::Pivot::Classes::Aggregate.value , 0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-MiddleEarth", "1-MiddleEarth", "2-USA"  , "2-USA"    , "3-Nowhere"],
            [1              , "1-Mordor"     , 3        , "3-Boston" , nil        ],
            [2              , "2-Shire"      , 4        , "3-Boston" , nil        ],
            [nil            , nil            , NilRecord, NilRecord  , nil        ]]
        )
        cell = hier_pivot_table[[2,1]].as(ReferenceCell(BaseCell))
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Mordor Shire)) # constrained as in pivot
        cell = hier_pivot_table[[1,3]].as(ReferenceCell(BaseCell))
        cell.each_defined_fulfilling.map(&.value).to_a.should eq(%w(Boston Seattle)) # constrained as in pivot
    end
    it "checking assignment use cases (without aggregates)" do # this is "copied" from pivot_spec (the Raw::Memory test case)
        # preparation DB layout
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            table
            c1  | c2  | c3  | c4  | c5 | c6
            c1a | r1a | c2a | r2a | a1 | a2
            c1a | r1a | c2b | r2a | a1 | a2
            c1a | r1a | c2b | r2b | a1 | a2
            c1a | r1b | c2a | r2a | a1 | a2
            c1a | r1b | c2b | r2b | a1 | a2
            c1a | r1b | c2b | r2b | a1 | a2
            c1b | r1b | c2b | r2b | a1 | a2
        EOT

        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["table"])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[PseudoFields::Rank]) # de-select Rank again
        vt = c.run
        # Name    Task          State         Project     Priority
        # the unused columns "a1" and "a2" are not referenced in fieldlist_table, but _are_ showing up in #get_table below!
        # col_name    pivot_class               level       rowcol_sort_asc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Column.value   , 0, true ,
            2, Table::Lazy::Pivot::Classes::Column.value   , 1, true , # hierarchy
            1, Table::Lazy::Pivot::Classes::Row.value      , 0, true ,
            3, Table::Lazy::Pivot::Classes::Row.value      , 1, true  # hierarchy
            ])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)

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
        vt.to_a2.should eq([
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
    it "hyperplane_add/_remove and references" do
        # preparation DB layout
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
            city    | liesin_country
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

            allocation
            who_name  | project
            Alan      | lawsuiting
        EOT

        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["persons"])
        c.toggle_select(c.tree)
        vt = c.run

        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["allocation"])
        c.toggle_expand(c.tree[hash["who"]])
        c.toggle_expand(c.tree[hash["who"]][hash["name"]])
        c.toggle_expand(c.tree[hash["who"]][hash["name"]][hash["livesin"]])
        c.toggle_expand(c.tree[hash["who"]][hash["name"]][hash["livesin"]][hash["city"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["who"]][hash["name"]][hash["livesin"]])
        vt = c.run
        expand_alls = [
            c.tree[PseudoFields::ShowAll],                              # "allocation"
            c.tree[hash["who"]][hash["name"]][PseudoFields::ShowAll]    # "persons"
        ]

        ref2rankvalue(vt.to_a2).should eq([
            [1, "3-Alan", "lawsuiting", "3-Boston"]
        ])

        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            3, Table::Lazy::Pivot::Classes::Column.value   , 0, false,
            1, Table::Lazy::Pivot::Classes::Column.value,    0, true ,
            0, Table::Lazy::Pivot::Classes::Row.value      , 1, true ,
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)

        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  ],
            ["3-Alan"  , "3-Alan"    ],
            [1         , "lawsuiting"]
        ])
        expand_alls.map {|n| c.is_selected?(n)}.should eq([false,false])

        hier_pivot_table[[1,1]].as(ReferenceCell).each_defined_fulfilling.to_a.map {|el| el.rank.to_s+"-"+el.value.to_s}.should eq(["3-Alan", "4-Denny"])
        rc = hier_pivot_table[[1,1]].as(ReferenceCell)
        rc.rank = 4 # switching header to Denny, keeping constraints
        (hier_pivot_table[[1,1]] = rc).should eq([1,0]) # don't forget to write back
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  ],
            ["4-Denny" , "4-Denny"   ],
            [1         , "lawsuiting"]
        ])

        rc = hier_pivot_table[[1,1]].as(ReferenceCell)
        rc.rank = 1 # checking Sauron, breaking constraints (Boston -> Mordor)
        (hier_pivot_table[[1,1]] = rc).should eq([1,0]) # don't forget to write back
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Mordor", "1-Mordor"  ],
            ["1-Sauron", "1-Sauron"  ],
            [1         , "lawsuiting"]
        ])

        rc = hier_pivot_table[[1,1]].as(ReferenceCell)
        rc.rank = 3 # back to Alan
        (hier_pivot_table[[1,1]] = rc).should eq([1,0]) # don't forget to write back

        index2 = hier_pivot_table.hyperplane_add(0, [1,1]) # copying from a header cell -> new record, same cluster; introducing another fulfilling person (from Boston)
        index2.should eq([1,2])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  , "3-Boston", "3-Boston"],
            ["3-Alan"  , "3-Alan"    , "4-Denny" , "4-Denny" ],
            [1         , "lawsuiting", 2         , nil       ]])
        expand_alls.map {|n| c.is_selected?(n)}.should eq([false,false]) # still having ShowAll disabled, dispite having more than one tables

        index3 = hier_pivot_table.hyperplane_add(0, [1,1]) # adding another one, this time no fulfilling available
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  , "3-Boston", "3-Boston", "3-Boston", "3-Boston"],
            ["3-Alan"   , "3-Alan"    , "4-Denny" , "4-Denny" , "5-"      , "5-"],
            [1          , "lawsuiting", 2         , nil       , 3         , nil]
        ])
        hier_pivot_table.hyperplane_remove(0, index3) # undoing

        hier_pivot_table.hyperplane_remove(0, index2) # undoing, also removing from "allocation", leaving as before
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  ],
            ["3-Alan"  , "3-Alan"    ],
            [1         , "lawsuiting"]
        ])
        expand_alls.map {|n| c.is_selected?(n)}.should eq([false,false])

        index2 = hier_pivot_table.hyperplane_add(0, [2,1]) # cloning a non-header cell
        index2.should eq([2,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  ],
            ["3-Alan"  , "3-Alan"    ],
            [1         , "lawsuiting"],
            [2         , "lawsuiting"]
        ])
        expand_alls.map {|n| c.is_selected?(n)}.should eq([false,false])

        hier_pivot_table.hyperplane_remove(0, index2) # undoing, also removing from "allocation", leaving as before
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  ],
            ["3-Alan"  , "3-Alan"    ],
            [1         , "lawsuiting"]
        ])
        expand_alls.map {|n| c.is_selected?(n)}.should eq([false,false])

        index2 = hier_pivot_table.hyperplane_add(0, [0,0]) # copying from a header cell -> new record, same cluster; introducing another person
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  , "1-Mordor", "1-Mordor"],
            ["3-Alan"  , "3-Alan"    , "1-Sauron", "1-Sauron"],
            [1         , "lawsuiting", 2         , nil       ]
        ])
        expand_alls.map {|n| c.is_selected?(n)}.should eq([false,false])
        vt.hyperplane_get_ids(0).should eq(Set{0,1,2,3})

        # demonstrating that also Hierarchic is "just" a raw table
        raw = Lazy::Raw::Permuted.new(hier_pivot_table, [1,0])
        ref2rankvalue(raw.to_a2).should eq([
            ["3-Boston", "3-Alan"  , 1           ],
            ["3-Boston", "3-Alan"  , "lawsuiting"],
            ["1-Mordor", "1-Sauron", 2           ],
            ["1-Mordor", "1-Sauron", nil         ]])
    end
    it "testing non-Kanban" do
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            tasks
            name | task
            A    | x
            B    | y
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["tasks"])
        c.toggle_select(c.tree)
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            1, Table::Lazy::Pivot::Classes::Column.value   , 0, true,
            0, Table::Lazy::Pivot::Classes::Row.value      , 0, true, # non-Kanban
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, false])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        matrix_rc = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        matrix_rc.to_a2.should eq ([[NilDeadArea, "A", "B"], [1, "x", nil], [2, nil, "y"]])
        indices = [] of Index
        matrix_rc.each.with_index2 {|_,index| indices << index.dup}
        indices.map {|index| matrix_rc.get_assignability(index)}.should eq([
            Table::Lazy::Pivot::Assignability::Not     , Table::Lazy::Pivot::Assignability::Directly  , Table::Lazy::Pivot::Assignability::Directly,
            Table::Lazy::Pivot::Assignability::Directly, Table::Lazy::Pivot::Assignability::Directly  , Table::Lazy::Pivot::Assignability::Indirectly,
            Table::Lazy::Pivot::Assignability::Directly, Table::Lazy::Pivot::Assignability::Indirectly, Table::Lazy::Pivot::Assignability::Directly
        ])
        matrix_rc.hyperplane_add(0, [1,2]).should eq([1,2])
        matrix_rc.to_a2.should eq ([[NilDeadArea, "A", "B"], [1, nil, nil], [2, "x", nil], [3, nil, "y"]])
    end
    it "testing Kanban" do
        l, hash = SpecHelpers::VTPivot.setup
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["indirecttask"])
        c.toggle_expand(c.tree[hash["who2"]])
        c.toggle_expand(c.tree[hash["who2"]][hash["name"]])
        c.toggle_expand(c.tree[hash["who2"]][hash["name"]][hash["livesin"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["who2"]][hash["name"]][hash["livesin"]])
        vt = c.run # rank, *who, project, *livesin
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Row.value,          1, true,
            3, Table::Lazy::Pivot::Classes::Column.value,       0, true,
            1, Table::Lazy::Pivot::Classes::Column.value,       0, true,
            2, Table::Lazy::Pivot::Classes::Aggregate.value,    0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  ],
            ["3-Alan"  , "3-Alan"    ],
            [1         , "lawsuiting"]
        ])
        hier_pivot_table.hyperplane_add(0, [2,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  ],
            ["3-Alan"  , "3-Alan"    ],
            [1         , "lawsuiting"],
            [2         , "lawsuiting"]
        ])
        hier_pivot_table.hyperplane_add(0, [1,1])
        hier_pivot_table[[2,3]] = "a"
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  , "3-Boston", "3-Boston"],
            ["3-Alan"  , "3-Alan"    , "4-Denny" , "4-Denny" ],
            [1         , "lawsuiting", 3         , "a"       ],
            [2         , "lawsuiting", nil       , nil       ]
        ])
        index = hier_pivot_table.hyperplane_add(0, [3,3])
        hier_pivot_table[index] = "b"
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["3-Boston", "3-Boston"  , "3-Boston", "3-Boston"],
            ["3-Alan"  , "3-Alan"    , "4-Denny" , "4-Denny" ],
            [1         , "lawsuiting", 3         , "a"       ],
            [2         , "lawsuiting", 4         , "b"       ]
        ])
    end
    it "cloning works" do
        # preparation DB layout
        l = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(l, hash)
        help << <<-EOT
            allocation
            who  | project
            Alan | lawsuiting
        EOT

        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["allocation"])
        c.toggle_select(c.tree)
        c2 = c.clone(false)
        vt = c.run
        vt2 = c2.run
        ref2rankvalue(vt.to_a2).should eq([[1, "Alan", "lawsuiting"]])
        c.toggle_select(c.tree[PseudoFields::Rank])
        ref2rankvalue(vt.to_a2).should eq([["Alan", "lawsuiting"]])
        ref2rankvalue(vt2.to_a2).should eq([[1, "Alan", "lawsuiting"]])
        c2.toggle_select(c2.tree[PseudoFields::Rank])
        ref2rankvalue(vt2.to_a2).should eq([["Alan", "lawsuiting"]])
    end
    it "checking formerly unbalanced Simple cluster trees" do
        l, hash = SpecHelpers::VTPivot.setup
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["cities"])
        c.toggle_expand(c.tree[hash["liesin"]])
        c.toggle_expand(c.tree[hash["liesin"]][hash["country"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["liesin"]][hash["country"]][PseudoFields::ShowAll])
        vt = c.run # rank, city, *liesin
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            2, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            1, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            0, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-MiddleEarth", "Mordor" , 1  ],
            ["1-MiddleEarth", "Shire"  , 2  ],
            ["2-USA"        , "Boston" , 3  ],
            ["2-USA"        , "Seattle", 4  ],
            ["3-Nowhere"    , nil      , nil]])
    end
    it "tokenize issue when using ShowAll and another cluster" do
        l, hash = SpecHelpers::VTPivot.setup
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["indirectallocation"])
        c.toggle_expand(c.tree[hash["d"]])
        c.toggle_expand(c.tree[hash["d"]][hash["day"]])
        c.toggle_expand(c.tree[hash["who"]])
        c.toggle_expand(c.tree[hash["who"]][hash["name"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["d"]][hash["day"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["who"]][hash["name"]][PseudoFields::ShowAll])
        vt = c.run # rank, *who, *d, participating
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            2, Table::Lazy::Pivot::Classes::Row.value,       0, true, # d over Rank, in same cluster (e.g. Row)
            0, Table::Lazy::Pivot::Classes::Row.value,       0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        # would trigger assert in VT#tokenize_projection, hence commented out right now
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Monday"   , nil],
            ["2-Tuesday"  , nil],
            ["3-Wednesday", nil],
            ["4-Thursday" , nil],
            ["5-Friday"   , nil]])
    end
    it "need different default handling in VT#hyperplane_add" do
        l, hash = SpecHelpers::VTPivot.setup
        # this works easily:
        # c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["indirectallocation"])
        # c.toggle_select(c.tree)
        # this now as well:
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["cities"])
        c.toggle_expand(c.tree[hash["city"]])
        c.toggle_expand(c.tree[hash["city"]][hash["livesin"]])
        c.toggle_expand(c.tree[hash["city"]][hash["livesin"]][hash["name"]])
        c.toggle_expand(c.tree[hash["city"]][hash["livesin"]][hash["name"]][hash["who"]])
        c.toggle_select(c.tree[hash["city"]][hash["livesin"]][hash["name"]][hash["who"]])
        vt = c.run # rank, *who, *d, participating
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            1, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        hier_pivot_table.get_assignability([0,0]).should eq(Table::Lazy::Pivot::Assignability::Indirectly)
        hier_pivot_table.hyperplane_add(0, [0,0]) # triggered crash at virtualtable.cr:500, #hyperplane_add
    end
    it "assigning non-reference to reference raises exception" do
        l, hash = SpecHelpers::VTPivot.setup
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["indirectallocation"])
        c.toggle_select(c.tree)
        vt = c.run # rank, *who, *d, participating
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            0, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            1, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        hier_pivot_table.get_assignability([0,0]).should eq(Table::Lazy::Pivot::Assignability::Indirectly)
        index = hier_pivot_table.hyperplane_add(0, [0,0])
        index.should eq([0,1])
        expect_raises(ConditionsNotMet) do
            hier_pivot_table[index] = 12i64
        end
    end
    it "shift in fieldlist after selecting additional field" do
        l, hash = SpecHelpers::VTPivot.setup
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["indirectallocation"])
        c.toggle_expand(c.tree[hash["d"]])
        c.toggle_expand(c.tree[hash["d"]][hash["day"]])
        c.toggle_expand(c.tree[hash["who"]])
        c.toggle_expand(c.tree[hash["who"]][hash["name"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["d"]][hash["day"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["who"]][hash["name"]][PseudoFields::ShowAll])
        vt = c.run # rank, *who, *d, participating
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            2, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            1, Table::Lazy::Pivot::Classes::Column.value,    0, true,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea  , "1-Sauron"  , "2-Samwise", "3-Alan"   , "4-Denny"],
            ["1-Monday"   , nil         , nil        , nil        , nil      ],
            ["2-Tuesday"  , nil         , nil        , nil        , nil      ],
            ["3-Wednesday", nil         , nil        , nil        , nil      ],
            ["4-Thursday" , nil         , nil        , nil        , nil      ],
            ["5-Friday"   , nil         , nil        , nil        , nil      ]
        ])
        vt.hyperplane_get_ids(0).to_a.should eq([0, 1, 2, 3])
        c.toggle_select(c.tree[hash["who"]][hash["name"]][hash["name"]]) # now id 4
        hier_pivot_table.to_a2
        c.toggle_select(c.tree[hash["who"]][hash["name"]][hash["name"]]) # now gone
        hier_pivot_table.to_a2
        c.toggle_select(c.tree[hash["who"]][hash["name"]][hash["name"]]) # now id 5
        ref2rankvalue(hier_pivot_table.to_a2).should eq([ # ok
            [NilDeadArea  , NilRecord , "1-Sauron", "2-Samwise", "3-Alan", "4-Denny"],
            [NilRecord    , "#4"      , nil       , nil        , nil     , nil      ],
            ["1-Monday"   , nil       , nil       , nil        , nil     , nil      ],
            ["2-Tuesday"  , nil       , nil       , nil        , nil     , nil      ],
            ["3-Wednesday", nil       , nil       , nil        , nil     , nil      ],
            ["4-Thursday" , nil       , nil       , nil        , nil     , nil      ],
            ["5-Friday"   , nil       , nil       , nil        , nil     , nil      ]
        ])
        vt.hyperplane_get_ids(0).to_a.should eq([0, 1, 2, 3, 5]) # here's the bug
    end
    it "fieldlist use case" do
        l, hash = SpecHelpers::VTPivot.setup
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["fieldlist"])
        c.toggle_expand(c.tree[hash["flclass"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]][hash["flr"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]][hash["flc"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]][hash["flr"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]][hash["flc"]][PseudoFields::ShowAll])
        vt = c.run # rank, *flclass, flasc, flhier, *flrr, *flcc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            5, Table::Lazy::Pivot::Classes::Column.value,    0, true,
            1, Table::Lazy::Pivot::Classes::Column.value,    1, true,
            4, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            0, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, NilDeadArea, "1-flc1" , "1-flc1" , "1-flc1" , "2-flc2" , "2-flc2" , "2-flc2" ],
            ["1-flr1"   , NilRecord  , NilRecord, NilRecord, "1-flunu", NilRecord, NilRecord, "2-flcol"],
            ["1-flr1"   , NilRecord  , NilRecord, NilRecord, nil      , NilRecord, NilRecord, nil      ],
            ["2-flr2"   , NilRecord  , NilRecord, NilRecord, "3-flrow", NilRecord, NilRecord, "4-flagg"],
            ["2-flr2"   , NilRecord  , NilRecord, NilRecord, nil      , NilRecord, NilRecord, nil      ]
        ])
        indices = [] of Index
        hier_pivot_table.each.with_index2 {|_,index| indices << index.dup}
        indices.map {|index| hier_pivot_table.get_assignability(index)}.should eq([
            Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Directly,
            Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Directly,
            Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Indirectly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Indirectly,
            Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Directly,
            Lazy::Pivot::Assignability::Directly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Indirectly, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Not, Lazy::Pivot::Assignability::Indirectly
        ])
    end
    it "hierarchic constraining works" do
        l, hash = SpecHelpers::VTPivot.setup
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(l, hash["hcmyt"])
        c.toggle_expand(c.tree[hash["hcmycol"]])
        c.toggle_expand(c.tree[hash["hcmycol"]][hash["hccol"]])
        c.toggle_expand(c.tree[hash["hcmycol"]][hash["hccol"]][hash["hchue"]])
        c.toggle_expand(c.tree[hash["hcmycol"]][hash["hccol"]][hash["hchue"]][hash["hchuer"]])
        c.toggle_expand(c.tree[hash["hcmycol"]][hash["hccol"]][hash["hcsat"]])
        c.toggle_expand(c.tree[hash["hcmycol"]][hash["hccol"]][hash["hcsat"]][hash["hcsatr"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["hcmycol"]][hash["hccol"]][hash["hchue"]])
        c.toggle_select(c.tree[hash["hcmycol"]][hash["hccol"]][hash["hcsat"]])
        vt = c.run # rank, hccol, *hchue, *hcsat
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            3, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            2, Table::Lazy::Pivot::Classes::Row.value,       1, true, # first hierarchy
            1, Table::Lazy::Pivot::Classes::Row.value,       2, true, # second hierarchy
            0, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([["1-hclow", "1-hcgreen", "1-hcgraygreen", 1]])
        cell = hier_pivot_table[[0,2]].as(ReferenceCell).each_defined_fulfilling.to_a
        cell.size.should eq(1) # single value (1-hcgraygreen), if multi-level constraining with several fields works correctly
    end
    it "hunting bugs" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            flrows
            flr
            flr1
            flr2

            flcols
            flc
            flc1
            flc2

            flclasses
            flcl  | flrr_flr  | flcc_flc
            flunu | flr1      | flc1
            flcol | flr1      | flc2
            flrow | flr2      | flc1
            flagg | flr2      | flc2

            fieldlist
            flclass_flcl | flasc | flhier
            flunu        | x     | y
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["fieldlist"])
        c.toggle_expand(c.tree[hash["flclass"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]][hash["flr"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]][hash["flc"]])
        c.toggle_select(c.tree)
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]][hash["flr"]][PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]][hash["flc"]][PseudoFields::ShowAll])
        vt = c.run # rank, *flclass, flasc, flhier, *flrr, *flcc
        fieldlist_table = Helper(FieldlistCell).array2table(4, [
            5, Table::Lazy::Pivot::Classes::Column.value,    0, true,
            1, Table::Lazy::Pivot::Classes::Column.value,    1, true, # first hierarchy
            4, Table::Lazy::Pivot::Classes::Row.value,       0, true,
            0, Table::Lazy::Pivot::Classes::Row.value,       1, true, # first hierarchy
            2, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true,
            3, Table::Lazy::Pivot::Classes::Aggregate.value, 0, true])
        fieldlist_table = Table::Lazy::Raw::Indexed.new(fieldlist_table, 1)
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-flc1"   , "1-flc1" , "1-flc1" , "1-flc1" , "2-flc2"   , "2-flc2" , "2-flc2" , "2-flc2" ],
            ["1-flr1"   , NilDeadArea, "1-flunu", "1-flunu", nil      , NilDeadArea, NilRecord, NilRecord, "2-flcol"], # TODO(test): first nil stems from a non-empty 1-flunu — should it be 1-flunu too?
            ["1-flr1"   , 1          , "x"      , "y"      , nil      , NilRecord  , NilRecord, NilRecord, nil      ],
            ["2-flr2"   , NilDeadArea, NilRecord, NilRecord, "3-flrow", NilDeadArea, NilRecord, NilRecord, "4-flagg"],
            ["2-flr2"   , NilRecord  , NilRecord, NilRecord, nil      , NilRecord  , NilRecord, NilRecord, nil      ]
        ])
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_remove(0, [1,6])
        end
        hier_pivot_table.hyperplane_add(0, [0,1]).should eq([0,9])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea       , "1-flc1"   , "1-flc1" , "1-flc1" , "1-flc1" , "2-flc2"   , "2-flc2" , "2-flc2" , "2-flc2" , "3-"       , "3-", "3-"],
            ["0-(no reference)", nil        , nil      , nil      , nil      , nil        , nil      , nil      , nil      , NilDeadArea, "5-", "5-"],
            ["0-(no reference)", nil        , nil      , nil      , nil      , nil        , nil      , nil      , nil      , 2          , nil , nil ],
            ["1-flr1"          , NilDeadArea, "1-flunu", "1-flunu", nil      , NilDeadArea, NilRecord, NilRecord, "2-flcol", nil        , nil , nil ],
            ["1-flr1"          , 1          , "x"      , "y"      , nil      , NilRecord  , NilRecord, NilRecord, nil      , nil        , nil , nil ],
            ["2-flr2"          , NilDeadArea, NilRecord, NilRecord, "3-flrow", NilDeadArea, NilRecord, NilRecord, "4-flagg", nil        , nil , nil ],
            ["2-flr2"          , NilRecord  , NilRecord, NilRecord, nil      , NilRecord  , NilRecord, NilRecord, nil      , nil        , nil , nil ]
        ])
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_add(0, [4,4]) # Adding not possible, cannot properly assign clusters; ignoring command (ConditionsNotMet)
        end
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_add(0, [4,8]) # Adding not possible, cannot properly assign clusters; ignoring command (ConditionsNotMet)
        end
    end
    it "hunting bugs #2" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            flrows
            flr
            flr1
            flr2

            flcols
            flc
            flc1
            flc2

            flclasses
            flcl  | flrr_flr | flcc_flc
            flunu | flr1     | flc1
            flcol | flr1     | flc2
            flrow | flr2     | flc1
            flagg | flr2     | flc2
            nil   | flr1     | flc1

            fieldlist
            flclass_flcl | flasc | flhier
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["fieldlist"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_expand(c.tree[hash["flclass"]])
        c.toggle_select(c.tree[hash["flclass"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][Table::VirtualTable::PseudoFields::ShowAll])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]][hash["flr"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flrr"]][hash["flr"]][Table::VirtualTable::PseudoFields::ShowAll])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]])
        c.toggle_expand(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]][hash["flc"]])
        c.toggle_select(c.tree[hash["flclass"]][hash["flcl"]][hash["flcc"]][hash["flc"]][Table::VirtualTable::PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["flasc"]])
        c.toggle_select(c.tree[hash["flhier"]])
        vt = c.run # rank, *flclass, flasc, flhier, *flrr, *flcc
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,4,2,0,true,
            2,0,2,1,true,
            3,2,3,0,true,
            4,3,3,0,true,
            5,5,1,0,true,
            6,1,1,1,true])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea , "1-flc1"   , "1-flc1" , "1-flc1" , "1-flc1" , "1-flc1", "2-flc2"   , "2-flc2" , "2-flc2" , "2-flc2" ],
            ["1-flr1"    , NilDeadArea, NilRecord, NilRecord, "1-flunu", "5-"    , NilDeadArea, NilRecord, NilRecord, "2-flcol"],
            ["1-flr1"    , NilRecord  , "#2"     , "#2"     , nil      , nil     , NilRecord  , NilRecord, NilRecord, nil      ],
            ["2-flr2"    , NilDeadArea, NilRecord, NilRecord, "3-flrow", nil     , NilDeadArea, NilRecord, NilRecord, "4-flagg"],
            ["2-flr2"    , NilRecord  , NilRecord, NilRecord, nil      , nil     , NilRecord  , NilRecord, NilRecord, nil      ]
        ])
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_remove(0, [2,2])
        end
    end
    it "hunting bugs #3" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            persons
            name
            Sauron
            Samwise
            Alan
            Denny

            days
            day
            Monday
            Tuesday
            Wednesday
            Thursday
            Friday

            indirectallocation
            who2_name | d_day | participating

        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["indirectallocation"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_expand(c.tree[hash["who2"]])
        c.toggle_select(c.tree[hash["who2"]])
        c.toggle_expand(c.tree[hash["who2"]][hash["name"]])
        c.toggle_select(c.tree[hash["who2"]][hash["name"]][Table::VirtualTable::PseudoFields::ShowAll])
        c.toggle_expand(c.tree[hash["d"]])
        c.toggle_select(c.tree[hash["d"]])
        c.toggle_expand(c.tree[hash["d"]][hash["day"]])
        c.toggle_select(c.tree[hash["d"]][hash["day"]][Table::VirtualTable::PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["participating"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,3,3,0,true,
            2,2,1,0,true,
            3,1,2,0,true,
            4,0,0,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-Monday", "2-Tuesday", "3-Wednesday", "4-Thursday", "5-Friday"],
            ["1-Sauron" , nil       , nil        , nil          , nil         , nil       ],
            ["2-Samwise", nil       , nil        , nil          , nil         , nil       ],
            ["3-Alan"   , nil       , nil        , nil          , nil         , nil       ],
            ["4-Denny"  , nil       , nil        , nil          , nil         , nil       ]
        ])
        rc = hier_pivot_table[[2,0]].as(ReferenceCell)
        rc.rank.should eq(2)
        rc.rank = 4
        (hier_pivot_table[[2,0]] = rc).should eq([2,0]) # does not trigger Exception, yields original index; but
        # hier_pivot_table.hyperplane_add(0, [1,1]) # forces update; value still "nil"; not necessary in GUI; hence added update forcing in Hierarchic
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-Monday", "2-Tuesday", "3-Wednesday", "4-Thursday", "5-Friday"],
            ["1-Sauron" , nil       , nil        , nil          , nil         , nil       ],
            ["2-Samwise", nil       , nil        , nil          , nil         , nil       ],
            ["3-Alan"   , nil       , nil        , nil          , nil         , nil       ],
            ["4-Denny"  , nil       , nil        , nil          , nil         , nil       ]
        ])
    end
    it "hunting bugs #4" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
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
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["cities"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_select(c.tree[hash["city"]])
        c.toggle_select(c.tree[hash["liesin"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,1,3,0,true,
            2,2,1,0,true,
            3,0,2,1,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-MiddleEarth", "1-MiddleEarth" , "2-USA", "2-USA"  ],
            [1              , "Mordor"        , 3      , "Boston" ],
            [2              , "Shire"         , 4      , "Seattle"]
        ])
        hier_pivot_table.hyperplane_add(0, [1,2]).should eq([1,2])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-MiddleEarth", "1-MiddleEarth", "2-USA", "2-USA"  ],
            [1              , "Mordor"       , 3      , nil      ],
            [2              , "Shire"        , 4      , "Boston" ],
            [nil            , nil            , 5      , "Seattle"]
        ])
    end
    it "hunting bugs #5" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            countries
            country
            MiddleEarth
            USA
            Nowhere
            nil

            cities
            city | liesin_country
            Mordor | MiddleEarth
            Shire | MiddleEarth
            Boston | USA
            Seattle | USA
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["cities"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_select(c.tree[hash["city"]])
        c.toggle_expand(c.tree[hash["liesin"]])
        c.toggle_select(c.tree[hash["liesin"]])
        c.toggle_expand(c.tree[hash["liesin"]][hash["country"]])
        c.toggle_select(c.tree[hash["liesin"]][hash["country"]][Table::VirtualTable::PseudoFields::ShowAll])
        c.toggle_select(c.tree[hash["liesin"]][hash["country"]][Table::VirtualTable::PseudoFields::Rank])
        c.toggle_select(c.tree[hash["liesin"]][hash["country"]][hash["country"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,2,0,true,
            2,1,3,0,true,
            3,2,3,0,true,
            4,3,2,0,true,
            5,4,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq ([
            [1        , 1, "Mordor" , "1-MiddleEarth", "MiddleEarth"],
            [2        , 1, "Shire"  , "1-MiddleEarth", "MiddleEarth"],
            [3        , 2, "Boston" , "2-USA"        , "USA"        ],
            [4        , 2, "Seattle", "2-USA"        , "USA"        ],
            [NilRecord, 3, NilRecord, NilRecord      , "Nowhere"    ],
            [NilRecord, 4, NilRecord, NilRecord      , nil          ]
        ])
        hier_pivot_table.hyperplane_add(0, [4,4]) # shouldn't fail (and also only fails partially in GUI...)
        (hier_pivot_table[[5,4]] = "a").should eq([5,4]) # shouldn't change return index
    end
    it "hunting bugs #6" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
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
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["cities"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_expand(c.tree[hash["city"]])
        c.toggle_select(c.tree[hash["city"]])
        c.toggle_expand(c.tree[hash["city"]][hash["livesin"]])
        c.toggle_select(c.tree[hash["city"]][hash["livesin"]][hash["name"]])
        c.toggle_select(c.tree[hash["liesin"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,2,0,true,
            2,1,3,0,true,
            3,2,3,0,true,
            4,3,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq ([
            [1, "Mordor", "MiddleEarth", "Sauron" ],
            [2, "Shire" , "MiddleEarth", "Samwise"],
            [3, "#2"    , "#2"         , "#2"     ]
        ])
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_add(0, [1,3]) # shouldn't fail partially
        end
        ref2rankvalue(hier_pivot_table.to_a2).should eq ([ # unchanged
            [1, "Mordor", "MiddleEarth", "Sauron" ],
            [2, "Shire" , "MiddleEarth", "Samwise"],
            [3, "#2"    , "#2"         , "#2"     ]
        ])
    end
    it "hunting bugs #7 pass 1" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            persons
            namep
            alan
            denny
            wanda

            projects
            p
            lawsuit
            peace

            allocation
            person_namep | country  | project_p
            alan         | usa      | lawsuit
            wanda        | unknown2 | peace
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        c.toggle_select(c.tree[hash["person"]])
        c.toggle_select(c.tree[hash["country"]])
        c.toggle_select(c.tree[hash["project"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,2,2,0,true,
            2,0,2,0,true,
            3,1,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-lawsuit", "1-alan" , "usa"     ], # with above configuration "Alan" is actually unconstrained
            ["2-peace"  , "3-wanda", "unknown2"]
        ])
        hier_pivot_table.hyperplane_add(0, [0,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-lawsuit", "1-alan" , "usa"     ],
            ["1-lawsuit", "2-denny", nil       ],
            ["2-peace"  , "3-wanda", "unknown2"]
        ])
    end
    it "hunting bugs #7 pass 2" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            persons
            namep
            alan
            denny
            wanda

            allocation
            person_namep | country  | project
            alan         | usa      | lawsuit
            wanda        | unknown2 | lawsuit
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        c.toggle_select(c.tree[hash["person"]])
        c.toggle_select(c.tree[hash["country"]])
        c.toggle_select(c.tree[hash["project"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,2,2,0,true,
            2,0,2,0,true,
            3,1,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["lawsuit" , "1-alan"  , "usa"      ], # with above configuration "Alan" is actually unconstrained
            ["lawsuit" , "3-wanda" , "unknown2" ]
        ])
        hier_pivot_table.hyperplane_add(0, [0,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["lawsuit", "1-alan" , "usa"     ],
            ["lawsuit", "2-denny", nil       ],
            ["lawsuit", "3-wanda", "unknown2"]
        ])
    end
    it "hunting bugs #7 fail" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            persons
            namep
            alan
            denny
            wanda

            allocation
            person_namep | country  | project
            alan         | usa      | lawsuit
            wanda        | unknown2 | peace
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        c.toggle_select(c.tree[hash["person"]])
        c.toggle_select(c.tree[hash["country"]])
        c.toggle_select(c.tree[hash["project"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,2,2,0,true,
            2,0,2,0,true,
            3,1,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["lawsuit", "1-alan" , "usa"     ], # with above configuration "Alan" is actually unconstrained
            ["peace"  , "3-wanda", "unknown2"]
        ])
        hier_pivot_table.hyperplane_add(0, [0,1]) # this should actually insert "Denny", but it triggers exception
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["lawsuit", "1-alan" , "usa"     ],
            ["lawsuit", "2-denny", nil       ],
            ["peace"  , "3-wanda", "unknown2"]
        ])
    end
    it "hunting bugs #8" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            xtab
            x
            Alanx
            Sauronx

            Cities
            NameC
            Boston
            Mordor

            Persons
            Person | City_NameC
            Alan   | Boston
            Sauron | Mordor
            nil    | Boston

            Allocations
            Name_Person | xx_x
            Alan        | Alanx
            Sauron      | Sauronx
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["Allocations"])
        c.toggle_expand(c.tree[hash["Name"]])
        c.toggle_select(c.tree[hash["Name"]])
        c.toggle_expand(c.tree[hash["Name"]][hash["Person"]])
        c.toggle_select(c.tree[hash["Name"]][hash["Person"]][hash["City"]])
        c.toggle_select(c.tree[hash["xx"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,2,0,true,
            2,1,2,0,true,
            3,2,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Alan"  , "1-Alanx"  , "1-Boston"],
            ["2-Sauron", "2-Sauronx", "2-Mordor"]
        ])
        hier_pivot_table.hyperplane_add(0, [0,1]) # working on reference-only cluster
        c.is_selected?(c.tree[PseudoFields::ShowAll]).should eq(false) # insert did not switch on "ShowAll"
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Alan"  , "1-Alanx"  , "1-Boston"],
            ["1-Alan"  , "2-Sauronx", "1-Boston"],
            ["2-Sauron", "2-Sauronx", "2-Mordor"]
        ])
    end
    it "hunting bugs #9" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            xtab
            x
            Alanx
            Sauronx

            Cities
            NameC
            Boston
            Mordor

            Persons
            Person | City_NameC
            Alan   | Boston
            Sauron | Mordor
            nil    | Boston

            Allocations
            Name_Person | xx_x
            Alan        | Alanx
            Sauron      | Sauronx
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["Allocations"])
        c.toggle_expand(c.tree[hash["Name"]])
        c.toggle_expand(c.tree[hash["Name"]][hash["Person"]])
        c.toggle_select(c.tree[hash["Name"]][hash["Person"]][hash["City"]])
        c.toggle_select(c.tree[hash["xx"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,2,0,true,
            2,1,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Alanx"  , "1-Boston"],
            ["2-Sauronx", "2-Mordor"]
        ])
        hier_pivot_table.hyperplane_add(0, [0,0]) # would work if ShowAll would be set for "Allocation"; presumably the same as bug#8
        c.is_selected?(c.tree[PseudoFields::ShowAll]).should eq(true) # insert had to switch on "ShowAll"
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Alanx"  , "1-Boston"],
            ["2-Sauronx", "2-Mordor"],
            ["3-"       , NilRecord ]
        ])
    end
    it "testing rank overflow" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            allocation
            person
            alan
            wanda
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["allocation"])
        c.toggle_select(c.tree)
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,2,0,true,
            2,1,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [1, "alan" ],
            [2, "wanda"]
        ])
        hier_pivot_table[[0,0]] = 123456789012
    end
    it "hunting bugs #10" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Cities
            City    | Country
            Arizona | XX
            Boston  | USA
            Mordor  | Middleearth

            Persons
            Person | CityR_City
            Alan   | Boston
            Denny  | Boston
            Sauron | Mordor

            Allocations
            PersonR_Person | Time    |  Allocation
            Alan           | Present |  100
            Sauron         | Former  |  100
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["Allocations"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_expand(c.tree[hash["PersonR"]])
        c.toggle_select(c.tree[hash["PersonR"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]][hash["CityR"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]][hash["CityR"]][hash["City"]])
        c.toggle_select(c.tree[hash["PersonR"]][hash["Person"]][hash["CityR"]][hash["City"]][hash["Country"]])
        c.toggle_select(c.tree[hash["Time"]])
        c.toggle_select(c.tree[hash["Allocation"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,3,3,0,true,
            2,0,0,0,true,
            3,4,2,0,true,
            4,1,2,0,true,
            5,2,1,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea  , NilDeadArea, "Former", "Present"],
            ["Middleearth", "3-Sauron" , 100     , nil      ],
            ["USA"        , "1-Alan"   , nil     , 100      ]
        ])
        hier_pivot_table.hyperplane_add(0, [2,1])
        c.is_selected?(c.tree[Table::VirtualTable::PseudoFields::ShowAll]).should eq(false)
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_add(0, [2,1])
        end
        c.is_selected?(c.tree[Table::VirtualTable::PseudoFields::ShowAll]).should eq(false)
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::ShowAll]) # in case this is set, GUI crashed right after following ConditionsNotMet, before introduction of #force_update
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea  , NilDeadArea, nil, "Former", "Present"],
            ["Middleearth", "3-Sauron" , nil, 100     , nil      ],
            ["USA"        , "1-Alan"   , nil, nil     , 100      ],
            ["USA"        , "2-Denny"  , nil, nil     , nil      ]
        ])
        expect_raises(ConditionsNotMet) do
            hier_pivot_table.hyperplane_add(0, [2,1])
        end
    end
    it "hunting bugs #11" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Persons
            Person | City
            Jared | Arizona
            Melanie | Arizona

            Allocations
            PersonR_Person | Country
            Melanie | USA
            Jared | USA
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["Allocations"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_expand(c.tree[hash["PersonR"]])
        c.toggle_select(c.tree[hash["PersonR"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]])
        c.toggle_select(c.tree[hash["PersonR"]][hash["Person"]][hash["City"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,2,2,0,true,
            2,0,2,0,true,
            3,1,3,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["Arizona", 1, "2-Melanie"],
            ["Arizona", 2, "1-Jared"  ]
        ])
        rc = hier_pivot_table[[1,2]].as(ReferenceCell)
        rc.each_defined_fulfilling.to_a.map {|el| el.rank.to_s+"-"+el.value.to_s}.should eq(["1-Jared", "2-Melanie"])
    end
    it "hunting bugs #12" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Persons
            Person | City
            Jared | Arizona
            Melanie | Arizona

            Allocations
            PersonR_Person | Country | Times | Project | Allocation
            Melanie | USA | Future | Survival | 100
            Jared | USA | Future | Survival | 100
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["Allocations"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_expand(c.tree[hash["PersonR"]])
        c.toggle_select(c.tree[hash["PersonR"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]])
        c.toggle_select(c.tree[hash["PersonR"]][hash["Person"]][hash["City"]])
        c.toggle_select(c.tree[hash["Country"]])
        c.toggle_select(c.tree[hash["Times"]])
        c.toggle_select(c.tree[hash["Project"]])
        c.toggle_select(c.tree[hash["Allocation"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,2,0,true,
            2,1,2,0,true,
            3,2,3,0,true,
            4,3,3,0,true,
            5,4,3,0,true,
            6,5,3,0,true,
            7,6,2,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [1, "2-Melanie", "Arizona", "USA", "Future", "Survival", 100],
            [2, "1-Jared"  , "Arizona", "USA", "Future", "Survival", 100]
        ])
        rc = hier_pivot_table[[0,1]].as(ReferenceCell)
        rc.each_defined_fulfilling.to_a.map {|el| el.rank.to_s+"-"+el.value.to_s}.should eq(["1-Jared", "2-Melanie"])
        hier_pivot_table.hyperplane_add(0, [0,1])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [1, "1-Jared"  , "Arizona", nil  , nil     , nil       , nil], # since in the cluster "Rank==1" above we have only Melanie, Jared is ok here
            [2, "2-Melanie", "Arizona", "USA", "Future", "Survival", 100],
            [3, "1-Jared"  , "Arizona", "USA", "Future", "Survival", 100]
        ])
    end
    it "hunting bugs #13" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            Cities
            City | Country
            Arizona | USA
            Wedora | unknown

            Projects
            Project
            Adventure
            Autonomy

            Persons
            Person | CityR_City
            Alan | Arizona
            Liothan | Wedora
            Tomeija | Wedora

            Allocations
            PersonR_Person | ProjectR_Project | Allocation
            Liothan | Adventure | 100
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["Allocations"])
        c.toggle_select(c.tree[Table::VirtualTable::PseudoFields::Rank])
        c.toggle_expand(c.tree[hash["PersonR"]])
        c.toggle_select(c.tree[hash["PersonR"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]][hash["CityR"]])
        c.toggle_select(c.tree[hash["PersonR"]][hash["Person"]][hash["CityR"]])
        c.toggle_expand(c.tree[hash["PersonR"]][hash["Person"]][hash["CityR"]][hash["City"]])
        c.toggle_select(c.tree[hash["PersonR"]][hash["Person"]][hash["CityR"]][hash["City"]][hash["Country"]]) # important, needs to be part of VT for this boundary case
        c.toggle_select(c.tree[hash["ProjectR"]])
        c.toggle_select(c.tree[hash["Allocation"]])
        vt = c.run
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,0,0,true,
            2,2,2,0,true,
            3,4,2,0,true,
            4,1,2,0,true,
            5,3,3,0,true,
            6,5,0,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Adventure", "2-Wedora", "2-Liothan", 100]
        ])
        rc = hier_pivot_table[[0,2]].as(ReferenceCell)
        rc.rank = 0
        c.is_selected?(c.tree[Table::VirtualTable::PseudoFields::ShowAll]).should eq(false)
        hier_pivot_table[[0,2]] = rc
        c.is_selected?(c.tree[Table::VirtualTable::PseudoFields::ShowAll]).should eq(true)
        hier_pivot_table[[0,2]] = rc
        c.is_selected?(c.tree[Table::VirtualTable::PseudoFields::ShowAll]).should eq(true)
        rc.rank = 1
        hier_pivot_table[[0,2]] = rc
        hier_pivot_table.hyperplane_add(0, [0,0])
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            ["1-Adventure" , "1-Arizona" , "1-Alan"           , 100],
            ["2-Autonomy"  , NilRecord   , "0-(no reference)" , nil]
        ])
    end
    it "hunting bugs #14" do
        persistency = Persistency::Default.new
        hash = Hash(String, FieldLID|TableLID|RecordLID).new
        help = TableReader(Persistency::Default,Persistency::Cell).new(persistency, hash)
        help << <<-EOT
            indices
            index
            a
            b

            service
            row_index | col_index
        EOT
        c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["service"])
        c.toggle_expand(c.tree[hash["row"]])
        c.toggle_select(c.tree[hash["row"]])
        c.toggle_expand(c.tree[hash["row"]][hash["index"]])
        c.toggle_select(c.tree[hash["row"]][hash["index"]][Table::VirtualTable::PseudoFields::ShowAll])
        c.toggle_expand(c.tree[hash["col"]])
        c.toggle_select(c.tree[hash["col"]])
        c.toggle_expand(c.tree[hash["col"]][hash["index"]])
        c.toggle_select(c.tree[hash["col"]][hash["index"]][Table::VirtualTable::PseudoFields::ShowAll])
        vt = c.run # be aware: no aggregate block defined
        fieldlist_table = Helper(FieldlistCell).array2table(5, [
            1,0,2,0,true,
            2,1,1,0,true
        ])
        hier_pivot_table = Table::Lazy::Pivot::Hierarchic(Cell,BaseCell,FieldlistCell).new(vt, fieldlist_table)
        ref2rankvalue(hier_pivot_table.to_a2).should eq([
            [NilDeadArea, "1-a", "2-b"],
            ["1-a"      , nil  , nil  ],
            ["2-b"      , nil  , nil  ]
        ])
        expect_raises(ConditionsNotMet) do
            hier_pivot_table[[1,1]] = 42i64 # direct assignment
        end
        hier_pivot_table.hyperplane_add(0, [1,1]).should eq([1,1])
        persistency.get_table(hash["service"]).map(&.[1..]).size.should eq(1) # one row
        hier_pivot_table.hyperplane_remove(0, [1,1])
        persistency.get_table(hash["service"]).map(&.[1..]).size.should eq(1) # TODO(pivot): Hierarchic currently leaves this [1,0] table in place rather than removing it
        expect_raises(ConditionsNotMet) do
            hier_pivot_table[[1,1]] = 42i64 # assignment after hyperplane was inserted
        end
    end
end
