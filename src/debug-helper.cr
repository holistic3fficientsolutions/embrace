# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../src/virtualtable" # for VT* below

module Helper(T)
    def self.string2table(columns : Int32, text : String) : Table::Lazy::Raw::Memory(T)
        arr = text.split(/[ \t\n,]+/).select{|el| el!=""}.map do |el|
            if res = el.to_i64?
            elsif res = el.to_f? # TODO(debug): must stay in line with T
            elsif el == "true"
                res = true
            elsif el == "false"
                res = false
            elsif el == "nil"
                res = nil
            else
                res = el
            end
            res.as(T) # cast avoids need of really creating all possible values in this block
        end.as(Array(T))
        Table::Lazy::Raw::Memory(T).new([arr.size//columns,columns]).load(arr)
    end
    def self.array2table(columns : Int32, arr : Array) : Table::Lazy::Raw::Memory(T)
        Table::Lazy::Raw::Memory(T).new([arr.size//columns,columns]).load(arr.map {|el| (el.is_a?(Int32) ? el.to_i64 : el).as(T)})
    end
end

def get_callstack : String
    stack = ""
    begin
        raise Exception.new
    rescue ex
        stack = ex.inspect_with_backtrace
    end
    stack
end

def toBaseCellsArray(arr)
    arr.map do |el|
        if el.is_a?(Int)
            el.to_i64.as(Cell)
        else
            el.as(Cell)
        end
    end
end

# # install "Smart Column Indenter" VSC extension,
# # mark lines, hit Ctrl-I Ctrl-N (or from context menu)
# # use underscore for reference fields (new_referenced)
# # be careful: only first columns can define reference tags!

# persons
# name   | livesin_city | eyecolor_color
# Sauron | Mordor       | Red
# Alan   | Boston       | Grey
class TableReader(T,U)
    def initialize(@persistency : T, @hash = Hash(String, FieldLID|TableLID|RecordLID).new)
    end
    def <<(table_content : String) # see also #dump below; mainly for testing purposes
        lines = table_content.split("\n")
        while !lines.empty?
            table_name = lines.shift.strip
            assert(!@hash.has_key?(table_name))
            @hash[table_name] = table_lid = @persistency.add_table(table_name)
            header = split(lines.shift, "|")
            index2field_lid = header.map do |field|
                field = split(field.as(String), "_")
                if isref = (field.size > 1)
                    lid = @persistency.add_field(table_lid, field[0].as(String), @hash[field[1].as(String)])
                    @hash[field[0].as(String)] = lid if !@hash.has_key?(field[0].as(String)) # still needed for (old) specs, but disturbs for more flexible (debug) table reading from file
                else
                    lid = @hash[field[0].as(String)] = @persistency.add_field(table_lid, field[0].as(String))
                end
                {lid, isref}
            end
            while (line = lines.shift?) && (line.strip.size > 0)
                record_lid = @persistency.add_record(table_lid)
                split(line, "|").each_with_index do |cell,field_index|
                    if index2field_lid[field_index][1]
                        # reference
                        cell2 = @hash[cell]? # reference -> we take the LID
                    else
                        # no reference
                        cell2 = cell
                        # attention: since at this point during parse it's not known if we will serve as a reference, we cannot check
                        @hash[cell.as(String)] = record_lid if (field_index==0)&&(cell.is_a?(String)) # if we _define_ referencable fields
                    end
                    @persistency.set_value(index2field_lid[field_index][0], record_lid, cell2)
                end
            end
            break if line.nil? # newline starts all over, EOF exists
        end
    end
    private def split(string : String, sep : String) : Array(U)
        string.split(sep).map(&.strip).map{|el| translate(el)}
    end
    private def translate(el : String) : U
        if res = el.to_i64?
        elsif res = el.to_f? # TODO(debug): must stay in line with U
        elsif el == "true"
            res = true
        elsif el == "false"
            res = false
        elsif el == "nil" || el == ""
            res = nil
        else
            res = el
        end
        res.as(U) # cast avoids need of really creating all possible values in this block
    end
end

class TableWriter(T,U)
    def initialize(@persistency : T)
    end
    def dump : String # counterpart to #<< above; mainly for testing purposes
        # beware: currently not doing top. sort (but silently assuming tables have been created in topsort order)
        res = Array(String).new
        recordlid2value = Hash(RecordLID,U).new
        tabletable = @persistency.get_table(MetaFieldLIDs::TableLastTable) # columns RecordLID==TableLID, rank, name
        tabletable.each do |row|
            table_lid, table_name = row[0].as(FieldLID), row[2].as(String)
            field_lids = @persistency.get_field_lids(table_lid) # : Array(FieldLID)
            target_fieldindex2name = Hash(Int32,String).new
            field_lids.each.with_index do |field_lid, i|
                if target_field_lid = @persistency.get_value(MetaFieldLIDs::RefersTo, field_lid).as(FieldLID?)
                    target_fieldindex2name[i] = @persistency.get_value(MetaFieldLIDs::Names, target_field_lid).as(String)
                    recordlid2value.merge!(@persistency.get_field(target_field_lid, false)) {|k,v1,v2| assert(v1==v2)} # record_lid=>value, all reference tags (dense)
                end
            end
            res << table_name
            field_names = field_lids.map {|lid| @persistency.get_value(MetaFieldLIDs::Names, lid).as(String)}
            res << field_names.map_with_index {|el,i| target_fieldindex2name.has_key?(i) ? el+"_"+target_fieldindex2name[i] : el}.join(" | ")
            content = @persistency.get_table(table_lid) # : Array(Array(T)) # a shorthand; including leading RecordLID and Rank columns
            content.each do |row|
                res << row[2..].map_with_index {|el,i| target_fieldindex2name.has_key?(i) ? recordlid2value[el]? : el}.map {|el| el.nil? ? "nil" : el}.join(" | ")
            end
            res << ""
        end
        res.join("\n")
    end
end

class VTReader(T,U)
    getter configurator : Table::VirtualTable::Configurator(T,U)
    def initialize(@persistency : Persistency::Default, content : String)
        content = content.split("\n", remove_empty: true)
        table_name = content.shift
        table_name =~ /"(.*)"/
        table_name = $1.not_nil!
        table_lids = @persistency.get_table(MetaFieldLIDs::TableLastTable).map(&.[0].as(TableLID)) # columns RecordLID==TableLID, rank, name
        table_name2lid = table_lids.map {|el| {@persistency.get_value(MetaFieldLIDs::Names, el).as(String), el}}.to_h
        field_lids = table_lids.map {|table_lid| @persistency.get_field_lids(table_lid)}.flatten # Array(FieldLID)
        field_name2lids = field_lids.group_by {|lid| @persistency.get_value(MetaFieldLIDs::Names, lid).as(String)} # "Person"=>[13,42,...]
        @configurator = Table::VirtualTable::Configurator(T,U).new(@persistency, table_name2lid[table_name])
        content.each do |line|
            cmd = line.gsub("c.toggle_", "").gsub("c.tree", "").gsub("(",",").gsub(")","").gsub(/\[hash\["?([^]"]+)"?\]\]/, "\\1,").split(",", remove_empty: true)
            # ["expand", "indirecttask"]
            # ["select", "indirecttask", "Table::VirtualTable::PseudoFields::Rank"]
            path = @configurator.tree
            cmd[1..].each do |el|
                arg = case el
                when "[Table::VirtualTable::PseudoFields::Rank]"
                    Table::VirtualTable::PseudoFields::Rank
                when "[Table::VirtualTable::PseudoFields::ShowAll]"
                    Table::VirtualTable::PseudoFields::ShowAll
                else
                    field_name2lids[el]
                end
                if arg.is_a?(Array)
                    arg.each do |lid| # since this is debug code only, we go the easy way; configurator will only match for one field_lid
                        begin
                            path = path[lid]
                            break
                        rescue ex
                        end
                    end
                else
                    path = path[arg]
                end
            end
            case cmd[0]
            when "expand"
                @configurator.toggle_expand(path)
            when "select"
                @configurator.toggle_select(path)
            else
                assert(false)
            end
        end
    end
end

# c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash["fieldlist"])
# c.toggle_select(c.tree[hash[Table::VirtualTable::PseudoFields::Rank]])
# c.toggle_expand(c.tree[hash["who"]])
# c.toggle_select(c.tree[hash["who"]])
# c.toggle_expand(c.tree[hash["who"]][hash["persons"]])
# c.toggle_select(c.tree[hash["who"]][hash["persons"]][hash["livesin"]])
# c.toggle_select(c.tree[hash["project"]])
class VTWriter(T,U)
    def initialize(@configurator : Table::VirtualTable::Configurator(T,U))
    end
    def dump : String
        res = Array(String).new
        table_name = @configurator.persistency.get_value(MetaFieldLIDs::Names, @configurator.tree.value.as(TableLID)).as(String)
        res << "c = Table::VirtualTable::Configurator(Cell,BaseCell).new(persistency, hash[\"#{table_name}\"])"
        path = Array(String).new
        @configurator.tree.dfs_downup do |is_down,e,n,l|
            if !e.nil? # we ignore the virtual edge to the root node
                if is_down
                    if e.is_a?(FieldLID)
                        name = '"' + @configurator.persistency.get_value(MetaFieldLIDs::Names, e).as(String) + '"'
                        path << "[hash[#{name}]]"
                    else
                        name = e.inspect
                        path << "[#{name}]"
                    end
                    res << "c.toggle_expand(c.tree" + path.join + ")" if @configurator.is_expanded?(n)
                    res << "c.toggle_select(c.tree" + path.join + ")" if @configurator.is_selected?(n) && l%2==1
                else
                    path.pop
                end
            end
        end
        res.join("\n")
    end
end