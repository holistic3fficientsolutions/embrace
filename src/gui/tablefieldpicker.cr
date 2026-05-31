# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../persistency"

# TablePicker and FieldPicker - state management for table/field selection
# In CrymbleUI, rendering is done by the host (Shape) using combo_box DSL.
# These classes manage the data: available tables/fields, selection state, CRUD operations.

module GUI::Widget

class TablePicker
    @persistency : Persistency::Default
    getter context : Persistency::Context
    @version : Int32? = nil
    @allow_create : Bool
    @suppress_empty : Bool
    @prefill_table : Bool
    @lid : Persistency::TableLID? = nil
    @lid_index = 0
    @lids = Array(Persistency::TableLID?).new
    @names = Array(String).new
    @changed = false
    @added_lid : Persistency::TableLID? = nil

    def initialize(@persistency : Persistency::Default, @context : Persistency::Context, *, @lid : Persistency::TableLID? = nil, @allow_create : Bool = false, @suppress_empty : Bool = false, @prefill_table : Bool = false)
    end

    def lid : Persistency::TableLID?
        update
        @lid
    end

    def lid=(lid : Persistency::TableLID?) : Persistency::TableLID?
        if @lid != lid
            @lid = lid
            @changed = true
            update(true)
        end
        lid
    end

    def consume_added_lid : Persistency::TableLID?
        res, @added_lid = @added_lid, nil
        res
    end

    def changed? : Bool
        update
        res, @changed = @changed, false
        res
    end

    def names : Array(String)
        update
        @names
    end

    def lid_index : Int32
        update
        @lid_index
    end

    def lids : Array(Persistency::TableLID?)
        update
        @lids
    end

    def allow_create? : Bool
        @allow_create
    end

    def select_index(index : Int32) : Nil
        if index >= 0 && index < @lids.size && index != @lid_index
            @lid = @lids[index]
            @changed = true
            update(true)
        end
    end

    def add_table(name : String) : Nil
        @persistency.contexts.push(@context)
        table_lid = @persistency.add_table(name)
        if @prefill_table
            @persistency.add_field(table_lid, Constant::Unnamed)
            @persistency.add_record(table_lid)
        end
        @context = @persistency.contexts.pop
        @added_lid = table_lid
        self.lid = table_lid
    end

    def rename_current(name : String) : Nil
        if lid = @lid
            @persistency.contexts.push(@context)
            @persistency.set_value(MetaFieldLIDs::Names, lid, name)
            @context = @persistency.contexts.pop
        end
    end

    def remove_current : Nil
        if lid = @lid
            @persistency.contexts.push(@context)
            @persistency.remove_table(lid)
            @context = @persistency.contexts.pop
            @lid = nil
        end
    end

    private def update(force = false) : Nil
        @persistency.contexts.push(@context)
        version = @persistency.version + @persistency.context.version
        if force || (@version != version)
            table = @persistency.get_table(MetaFieldLIDs::TableLastTable)
            table.sort! { |x, y| x[2].as(String) <=> y[2].as(String) }
            @lids = [] of Persistency::TableLID?
            @names = [] of String
            if table.empty? || !@suppress_empty
                @lids << nil
                @names << "(no table)"
            end
            @lids += table.map(&.[0].as(Persistency::TableLID?))
            @names += table.map(&.[2].as(String))
            index = @lids.index(@lid)
            if index.nil?
                @changed = true
                index = 0
            end
            @lid_index = index
            @lid = @lids[index]
            @version = version
        end
        @context = @persistency.contexts.pop
    end
end

class FieldPicker
    @persistency : Persistency::Default
    @context : Persistency::Context
    @table_lid : Persistency::FieldLID?
    @version : Int32? = nil
    @allow_create : Bool
    @suppress_empty : Bool
    @suppress_references : Bool
    @lid : Persistency::FieldLID? = nil
    @lid_index = 0
    @lids = Array(Persistency::FieldLID?).new
    @names = Array(String).new
    @changed = false
    @added_lid : Persistency::FieldLID? = nil

    def initialize(@persistency : Persistency::Default, @context : Persistency::Context, @table_lid : Persistency::FieldLID?, *, @lid : Persistency::FieldLID? = nil, @allow_create : Bool = true, @suppress_empty : Bool = false, @suppress_references : Bool = true)
    end

    def lid : Persistency::FieldLID?
        update
        @lid
    end

    def lid=(lid : Persistency::FieldLID?) : Persistency::FieldLID?
        if @lid != lid
            @lid = lid
            @changed = true
            update(true)
        end
        lid
    end

    def consume_added_lid : Persistency::FieldLID?
        res, @added_lid = @added_lid, nil
        res
    end

    def changed? : Bool
        update
        res, @changed = @changed, false
        res
    end

    def names : Array(String)
        update
        @names
    end

    def lid_index : Int32
        update
        @lid_index
    end

    def lids : Array(Persistency::FieldLID?)
        update
        @lids
    end

    def allow_create? : Bool
        @allow_create && !@table_lid.nil?
    end

    def select_index(index : Int32) : Nil
        if index >= 0 && index < @lids.size && index != @lid_index
            @lid = @lids[index]
            @changed = true
            update(true)
        end
    end

    def add_field(name : String, ref_field_lid : Persistency::FieldLID? = nil) : Nil
        if table_lid = @table_lid
            @persistency.contexts.push(@context)
            field_lid = @persistency.add_field(table_lid, name, ref_field_lid)
            @context = @persistency.contexts.pop
            @added_lid = field_lid
            self.lid = field_lid
        end
    end

    def rename_current(name : String) : Nil
        if lid = @lid
            @persistency.contexts.push(@context)
            @persistency.set_value(MetaFieldLIDs::Names, lid, name)
            @context = @persistency.contexts.pop
        end
    end

    def remove_current : Nil
        if (table_lid = @table_lid) && (lid = @lid)
            @persistency.contexts.push(@context)
            @persistency.remove_field(table_lid, lid)
            @context = @persistency.contexts.pop
            @lid = nil
        end
    end

    private def update(force = false) : Nil
        @persistency.contexts.push(@context)
        version = @persistency.version + @persistency.context.version
        if force || (@version != version)
            @lids = [] of Persistency::FieldLID?
            @names = [] of String
            field_lids = [] of Persistency::FieldLID
            field_lids = @persistency.get_field_lids(@table_lid.not_nil!) if @table_lid
            if field_lids.empty? || !@suppress_empty
                @lids << nil
                @names << "(no field)"
            end
            if @table_lid
                field_lids.each do |lid|
                    if !@suppress_references || @persistency.get_value(MetaFieldLIDs::RefersTo, lid).nil?
                        name = @persistency.get_value(MetaFieldLIDs::Names, lid).as(String)
                        @lids << lid
                        @names << name
                    end
                end
            end
            index = @lids.index(@lid)
            if index.nil?
                @changed = true
                index = 0
            end
            @lid_index = index
            @lid = @lids[index]
            @version = version
        end
        @context = @persistency.contexts.pop
    end
end

end # module GUI::Widget
