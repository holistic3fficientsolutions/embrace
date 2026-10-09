# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../global"
require "../persistency"
require "../constants"
require "./tablefieldpicker"
require "crymble-ui"

# Dialog state classes. A dialog is not a window of its own: it is a state object EmbraceApp keeps in its
# dialog list and renders as a window_panel in build (embrace_dialogs.cr), while it is open?.
# Each dialog has state for its fields and callbacks for Ok / Cancel.

module Dialogs

# What EmbraceApp's dialog list reads of a dialog: its id, whether it is still open, and closing it.
module Hosted
    abstract def id : String
    abstract def open? : Bool
    abstract def close : Nil
end

# Base for embrace's own dialogs - provides common state
abstract class Base
    include Hosted

    getter id : String
    getter title : String
    getter? open : Bool = true

    def initialize(@title : String, @id : String = "dialog_#{object_id}")
    end

    def close : Nil
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
    getter name = CrymbleUI::Source(String).new("")

    def initialize(title : String, &@block : String ->)
        super(title, "creator_#{object_id}")
    end

    def accept
        @block.call(@name.get)
        close
    end
end

class Renamer < Base
    getter block : Proc(String, Nil)
    getter name_old : String
    getter name_new : CrymbleUI::Source(String)

    def initialize(title : String, @name_old : String, &@block : String ->)
        super(title, "renamer_#{object_id}")
        @name_new = CrymbleUI::Source(String).new(@name_old)
    end

    def accept
        @block.call(@name_new.get)
        close
    end
end

class AddField < Base
    getter block : Proc(String, Persistency::FieldLID?, Nil)
    getter name = CrymbleUI::Source(String).new("")
    property ref_table_lid : Persistency::TableLID? = nil
    property ref_field_lid : Persistency::FieldLID? = nil
    getter persistency : Persistency::Default
    getter context : Persistency::Context
    getter suppress_reference : Bool

    def initialize(title : String, @persistency : Persistency::Default, @context : Persistency::Context, *, @suppress_reference : Bool = false, &@block : String, Persistency::FieldLID? ->)
        super(title, "addfield_#{object_id}")
    end

    def accept
        @persistency.with_context(@context) do
            @block.call(@name.get, @ref_field_lid)
        end
        close
    end
end

class ImportTable < Base
    getter block : Proc(String, String, Nil)
    getter wildcard : String
    getter tablename = CrymbleUI::Source(String).new("(new table)")
    getter filename = CrymbleUI::Source(String).new("")
    # Set once its field has taken the keyboard: a later rebuild (one a file dialog opened on top of it triggers)
    # must not take it back from that dialog.
    property focused_once : Bool = false

    def initialize(title : String, @wildcard : String, &@block : String, String ->)
        super(title, "importtable_#{object_id}")
    end

    def accept
        @block.call(@filename.get, @tablename.get)
        close
    end
end

class FactorOut < Base
    getter block : Proc(Persistency::TableLID, Persistency::FieldLID, Nil)
    getter persistency : Persistency::Default
    getter context : Persistency::Context
    getter field_lid : Persistency::FieldLID
    getter table_picker : GUI::Widget::TablePicker
    getter field_picker : GUI::Widget::FieldPicker

    def initialize(title : String, @persistency : Persistency::Default, @context : Persistency::Context, @field_lid : Persistency::FieldLID, &@block : Persistency::TableLID, Persistency::FieldLID ->)
        super(title, "factorout_#{object_id}")
        # allow_create lets the user spin up the target table (and, via the
        # field picker, its field) inline — the "fluffy" v1 flow. The table is
        # created empty (no prefilled record), so factor-out itself fills it
        # with the distinct values. Dialog and both pickers share @context, so
        # a freshly-created table/field is visible to the field picker and to
        # #accept.
        @table_picker = GUI::Widget::TablePicker.new(@persistency, @context, allow_create: true)
        @field_picker = GUI::Widget::FieldPicker.new(@persistency, @context, @table_picker.lid, suppress_references: true)
    end

    # Re-target the field picker whenever the chosen table changed — a different
    # table has different fields. Call once per rebuild (and after add_table).
    def sync_field_picker! : Nil
        if @table_picker.changed?
            @field_picker = GUI::Widget::FieldPicker.new(@persistency, @context, @table_picker.lid, suppress_references: true)
        end
    end

    def ready? : Bool
        !@table_picker.lid.nil? && !@field_picker.lid.nil?
    end

    def accept
        if (table_lid = @table_picker.lid) && (field_lid = @field_picker.lid)
            @persistency.with_context(@context) do
                @block.call(table_lid, field_lid)
            end
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
        persistency.with_context(@context) do
            persistency.get_field_lids(@table_lid).each do |lid|
                @field_lids << lid
                @field_names << persistency.display_name(lid) # blank -> "(unnamed)"
                @field_selected << keep.includes?(lid)
            end
        end
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
        persistency.with_context(@context) do
            persistency.associate_fields(@table_lid, selected, mux, val)
        end
        refresh_fields
    end

    def dissociate!
        return unless (mux = @mux_field_lid) && (val = @value_field_lid)
        new_field_lids = persistency.with_context(@context) do
            persistency.dissociate_fields(@table_lid, mux, val).tap do |lids|
                lids.each { |fld| @configurator.toggle_select(@configurator.tree[fld]) }
            end
        end
        refresh_fields(new_field_lids.to_set)
    end
end

# The open / save dialog: crymbleui's FileDialog (its model and its panel), reporting what it refuses in embrace's
# words - "Cannot open folder 'sub': ...", "Cannot create folder 'x': ..." - in the status bar. The mapping is for the
# TEXT only: an unmapped File::Error would reach the status bar too, in the library's words.
class FileBrowser < CrymbleUI::FileDialog
    include Hosted

    def initialize(title : String, wildcard : String, start : String | Path = ".", &on_accept : String -> Nil)
        super(title, wildcard, start, "dirbrowser_#{object_id}", &on_accept)
    end

    def navigate(name : String) : Nil
        super
    rescue ex : File::Error
        raise ConditionsNotMet.new("Cannot open folder '#{name.chomp('/')}': #{ex.message}")
    end

    def navigate_to_part(count : Int32) : Nil
        super
    rescue ex : File::Error
        raise ConditionsNotMet.new("Cannot open folder '#{path.parts[count - 1]?}': #{ex.message}")
    end

    def goto(target : String | Path) : Nil
        super
    rescue ex : File::Error
        raise ConditionsNotMet.new("Cannot open folder '#{target}': #{ex.message}")
    end

    def create_folder(name : String) : Nil
        super
    rescue ex : File::Error
        raise ConditionsNotMet.new("Cannot create folder '#{name}': #{ex.message}")
    end
end

end # module Dialogs
