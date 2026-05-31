# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../global"
require "../persistency"
require "../constants"

# CrymbleUI dialog state classes
# In CrymbleUI, dialogs are not self-contained windows. Instead, they are
# state objects that EmbraceApp renders as window_panels in its build() method.
# Each dialog has:
#   - State for its fields
#   - A #build method returning a block for CrymbleUI DSL (called by the host)
#   - Callbacks for Ok/Cancel

module Dialogs

# Base for all dialogs - provides common state
abstract class Base
    getter id : String
    getter title : String
    property open : Bool = true

    def initialize(@title : String, @id : String = "dialog_#{object_id}")
    end

    def close
        @open = false
    end
end

# (About is rendered inline in embrace.cr)

class ImportantInformer < Base
    getter content : String
    @block : Proc(Nil)?

    def initialize(@content : String)
        super("Information", "informer_#{object_id}")
        @block = nil
    end

    def initialize(@content : String, &@block : ->)
        super("Information", "informer_#{object_id}")
    end

    def accept
        @block.try(&.call)
        close
    end
end

class Decider < Base
    getter block : Proc(Nil)

    def initialize(title : String, &@block : ->)
        super(title, "decider_#{object_id}")
    end

    def accept
        @block.call
        close
    end
end

class Creator < Base
    getter block : Proc(String, Nil)
    property name : String = ""

    def initialize(title : String, &@block : String ->)
        super(title, "creator_#{object_id}")
    end

    def accept
        @block.call(@name)
        close
    end
end

class Renamer < Base
    getter block : Proc(String, Nil)
    getter name_old : String
    property name_new : String

    def initialize(title : String, @name_old : String, &@block : String ->)
        super(title, "renamer_#{object_id}")
        @name_new = @name_old
    end

    def accept
        @block.call(@name_new)
        close
    end
end

class AddField < Base
    getter block : Proc(String, Persistency::FieldLID?, Nil)
    property name : String = ""
    property ref_table_lid : Persistency::TableLID? = nil
    property ref_field_lid : Persistency::FieldLID? = nil
    getter persistency : Persistency::Default
    getter context : Persistency::Context
    getter suppress_reference : Bool

    def initialize(title : String, @persistency : Persistency::Default, @context : Persistency::Context, *, @suppress_reference : Bool = false, &@block : String, Persistency::FieldLID? ->)
        super(title, "addfield_#{object_id}")
    end

    def accept
        @persistency.contexts.push(@context)
        @block.call(@name, @ref_field_lid)
        @persistency.contexts.pop
        close
    end
end

class ImportTable < Base
    getter block : Proc(String, String, Nil)
    getter wildcard : String
    property tablename : String = "(new table)"
    property filename : String = ""

    def initialize(title : String, @wildcard : String, &@block : String, String ->)
        super(title, "importtable_#{object_id}")
    end

    def accept
        @block.call(@filename, @tablename)
        close
    end
end

class FactorOut < Base
    getter block : Proc(Persistency::TableLID, Persistency::FieldLID, Nil)
    getter persistency : Persistency::Default
    getter context : Persistency::Context
    getter field_lid : Persistency::FieldLID
    property target_table_lid : Persistency::TableLID? = nil
    property target_field_lid : Persistency::FieldLID? = nil

    def initialize(title : String, @persistency : Persistency::Default, @context : Persistency::Context, @field_lid : Persistency::FieldLID, &@block : Persistency::TableLID, Persistency::FieldLID ->)
        super(title, "factorout_#{object_id}")
    end

    def accept
        if (table_lid = @target_table_lid) && (field_lid = @target_field_lid)
            @persistency.contexts.push(@context)
            @block.call(table_lid, field_lid)
            @persistency.contexts.pop
        end
        close
    end
end

class DisAssociateFields < Base
    getter configurator : Table::VirtualTable::Configurator(Cell, BaseCell)
    property context : Persistency::Context
    getter table_lid : Persistency::TableLID
    property mux_field_lid : Persistency::FieldLID? = nil
    property value_field_lid : Persistency::FieldLID? = nil
    getter field_lids : Array(Persistency::FieldLID)
    getter field_names : Array(String)
    property field_selected : Array(Bool)

    def initialize(title : String, @configurator : Table::VirtualTable::Configurator(Cell, BaseCell),
                   @context : Persistency::Context, @table_lid : Persistency::TableLID)
        super(title, "disassociate_#{object_id}")
        @field_lids = Array(Persistency::FieldLID).new
        @field_names = Array(String).new
        @field_selected = Array(Bool).new
        refresh_fields
    end

    private def persistency
        @configurator.persistency
    end

    def refresh_fields(keep_selected : Set(Persistency::FieldLID)? = nil)
        keep = keep_selected || (0...@field_lids.size).select { |i| @field_selected[i] }.map { |i| @field_lids[i] }.to_set
        @field_lids.clear
        @field_names.clear
        @field_selected.clear
        persistency.contexts.push(@context)
        persistency.get_field_lids(@table_lid).each do |lid|
            @field_lids << lid
            @field_names << persistency.get_value(MetaFieldLIDs::Names, lid).as(String)
            @field_selected << keep.includes?(lid)
        end
        persistency.contexts.pop
    end

    def select_mux(index : Int32)
        lid = picker_lids[index]?
        @value_field_lid = nil if @value_field_lid == lid
        if lid && (i = @field_lids.index(lid))
            @field_selected[i] = false
        end
        @mux_field_lid = lid
    end

    def select_value(index : Int32)
        lid = picker_lids[index]?
        @mux_field_lid = nil if @mux_field_lid == lid
        if lid && (i = @field_lids.index(lid))
            @field_selected[i] = false
        end
        @value_field_lid = lid
    end

    def picker_names : Array(String)
        ["(no field)"] + @field_names
    end

    def picker_lids : Array(Persistency::FieldLID?)
        [nil.as(Persistency::FieldLID?)] + @field_lids.map(&.as(Persistency::FieldLID?))
    end

    def mux_index : Int32
        @mux_field_lid.try { |lid| @field_lids.index(lid).try(&.+(1)) } || 0
    end

    def value_index : Int32
        @value_field_lid.try { |lid| @field_lids.index(lid).try(&.+(1)) } || 0
    end

    def can_associate? : Bool
        !@mux_field_lid.nil? && !@value_field_lid.nil? && @field_selected.count(true) > 0
    end

    def can_dissociate? : Bool
        !@mux_field_lid.nil? && !@value_field_lid.nil? && @field_selected.count(true) == 0
    end

    def associate!
        return unless (mux = @mux_field_lid) && (val = @value_field_lid)
        selected = (0...@field_lids.size).select { |i| @field_selected[i] }.map { |i| @field_lids[i] }
        persistency.contexts.push(@context)
        persistency.associate_fields(@table_lid, selected, mux, val)
        @context = persistency.contexts.pop
        refresh_fields
    end

    def dissociate!
        return unless (mux = @mux_field_lid) && (val = @value_field_lid)
        persistency.contexts.push(@context)
        new_field_lids = persistency.dissociate_fields(@table_lid, mux, val)
        new_field_lids.each do |fld|
            @configurator.toggle_select(@configurator.tree[fld])
        end
        @context = persistency.contexts.pop
        refresh_fields(new_field_lids.to_set)
    end
end

class DirBrowser < Base
    getter wildcard : String
    getter block : Proc(String, Nil)
    property path : Path
    property filename : String = ""
    property items : Array({String, String, String, File::Info})
    property sort_column : Int32 = 0
    property sort_ascending : Bool = true

    @@drives : Array(String)? = nil

    def initialize(title : String, @wildcard : String = "*", &@block : String ->)
        super("#{title} (#{@wildcard})", "dirbrowser_#{object_id}")
        @path = Path["."].expand
        @items = Array({String, String, String, File::Info}).new
        update
    end

    def drives : Array(String)
        update_drives if @@drives.nil?
        @@drives || [] of String
    end

    def navigate(dirname : String)
        begin
            new_path = (@path / dirname).normalize
            if Dir.entries(new_path)
                @path = new_path
                update
            end
        rescue ex
        end
    end

    def navigate_to_part(index : Int32)
        parts = @path.parts
        @path = Path.new(parts[0...index])
        update
    end

    def select_file(name : String)
        @filename = name
    end

    def accept
        name = @filename
        if !File.match?(@wildcard, name)
            if @wildcard =~ /^\*(.*)$/i
                name += $1
            end
        end
        @block.call((@path / name).to_s)
        close
    end

    def update(sort_column : Int32 = @sort_column, sort_ascending : Bool = @sort_ascending)
        # Toggle direction when clicking same column
        if sort_column == @sort_column
            @sort_ascending = !@sort_ascending
        else
            @sort_column = sort_column
            @sort_ascending = true
        end

        if @path.parts.size == 0
            update_drives if @@drives.nil?
            @items = @@drives.not_nil!.map { |el| {el, "", "", File.info(el)} }
        else
            all = Dir.new(@path).entries.reject do |el|
                fail = false
                begin
                    File.info(@path / el)
                rescue ex
                    fail = true
                end
                (el == ".") || fail
            end.map { |el| {el, File.info(@path / el)} }

            dirs = all.select { |el| el[1].directory? }
                .map { |el| {el[0] + "/", "", "", el[1]} }
                .sort { |x, y| x[0] <=> y[0] }

            files = all.select { |el| !el[1].directory? && File.match?(@wildcard, el[0]) }
                .map { |el| {el[0], el[1].size.format.rjust(15), el[1].modification_time.to_s, el[1]} }

            col = sort_column.clamp(0, 2)
            files = files.sort { |x, y| (sort_ascending ? 1 : -1) * (x[col].as(String) <=> y[col].as(String)) }
            @items = dirs + files
        end
    end

    private def update_drives
        {% if flag?(:win32) %}
        @@drives = ("A".."Z").map { |el| "#{el}:/" }.select do |path|
            begin
                Dir.exists?(path)
            rescue ex
            end
        end
        {% else %}
        @@drives = [] of String
        {% end %}
    end
end

end # module Dialogs
