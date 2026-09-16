# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../global"
require "../persistency"
require "../constants"
require "./tablefieldpicker"

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
            @field_names << persistency.display_name(lid) # blank -> "(unnamed)"
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
    # Double-click bookkeeping, held HERE because the browser's MatrixAdapter is rebuilt on every
    # frame and a click asks for a rebuild — so state left on the adapter is gone before the second
    # click arrives. This is the carrier crymbleui's DirBrowser adapter documents as the host's job.
    property last_click_file : String? = nil
    # Show everything, not just what matches the wildcard — a file saved under the wrong extension
    # is otherwise invisible AND unopenable, with nothing in the dialog to say so.
    property show_all : Bool = false
    # The highlighted row: a name (directories carry their trailing "/"), and its index for the
    # arrow keys. Distinct from `filename`, which is what Ok would accept — selecting a directory
    # must not put "sub/" in the filename field.
    getter selected_name : String = ""
    getter selected_index : Int32 = -1
    # Set once the dialog has taken focus, so a rebuild does not steal it back mid-typing.
    property focused_once : Bool = false
    # Where the keyboard starts. Browsing (Load) wants the LIST, because that is what the arrow
    # keys drive — they reach the focused widget long before any panel shortcut, so a list you
    # cannot focus is a list you cannot walk. Naming a file (Save as) wants the text field.
    property focus_list : Bool = false

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
        @selected_name = name
        @selected_index = index_of(name)
    end

    # A directory is selected without being entered, and without touching `filename`.
    def select_dir(name : String)
        @selected_name = name
        @selected_index = index_of(name)
    end

    # Arrow keys. Moving onto a file fills the name field, the way clicking it does; moving onto a
    # directory only highlights it.
    def move_selection(delta : Int32)
        return if @items.empty?
        @selected_index = if @selected_index < 0
                              delta > 0 ? 0 : @items.size - 1
                          else
                              (@selected_index + delta).clamp(0, @items.size - 1)
                          end
        name, _, _, info = @items[@selected_index]
        @selected_name = name
        @filename = name unless info.directory?
    end

    # Enter. On a directory that means walking into it; on anything else, accepting what the
    # filename field holds — so Enter after typing a name still does what it always did.
    def activate_selection
        activate_index(@selected_index)
    end

    # Enter on a specific row, which is how the keyboard arrives: the arrow keys move the MATRIX's
    # own cursor, not this dialog's selection, so the row under that cursor is the one to act on.
    def activate_index(index : Int32)
        # `index` is -1 when nothing is selected, and @items[-1]? is the LAST row in Crystal, not
        # nil — so without this guard "Enter with no selection" quietly accepted the bottom file
        # of the listing instead of the name in the field.
        item = index < 0 ? nil : @items[index]?
        if item.nil?
            accept
        elsif item[3].directory?
            navigate(item[0].rstrip('/'))
        else
            select_file(item[0])
            accept
        end
    end

    def create_folder(name : String) : Nil
        return if name.empty?
        Dir.mkdir_p(@path / name)
        refresh
    rescue ex
        # A name the filesystem refuses (a stray "/", a permission) is the user's typo, not a crash.
    end

    private def index_of(name : String) : Int32
        @items.index { |(n, _, _, _)| n == name } || -1
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

    # Re-read the directory, KEEPING the current order. This used to take the sort arguments and
    # toggle when the column matched, so `update` with no arguments — from the constructor, from
    # navigate, from the drive buttons — reversed the sort every time: the browser opened
    # descending and flipped on every folder you walked into.
    def update
        refresh
    end

    # The user clicked a column header: the same column reverses, a different one starts ascending.
    def sort_by(sort_column : Int32)
        if sort_column == @sort_column
            @sort_ascending = !@sort_ascending
        else
            @sort_column = sort_column
            @sort_ascending = true
        end
        refresh
    end

    private def refresh
        sort_column = @sort_column
        sort_ascending = @sort_ascending
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

            files = all.select { |el| !el[1].directory? && (@show_all || File.match?(@wildcard, el[0])) }
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
