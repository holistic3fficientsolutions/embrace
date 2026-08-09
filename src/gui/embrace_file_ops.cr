# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# File operations and shape management for EmbraceApp
# Extracted from embrace.cr for maintainability

class EmbraceApp < CrymbleUI::App
    private def shape_add : Nil
        context = @persistency.context.clone
        shape = ShapeState.new("Shape", @persistency, context)
        @shapes << shape
        request_rebuild
    end

    # Drill-down: spawn a new Shape that filters down to exactly the basic rows
    # under a Drilldown cell of parent_shape. Returns the new ShapeState on
    # success, nil if the cell isn't a Drilldown or drill isn't possible.
    def shape_drill_from_cell(parent_shape : ShapeState, index : Tuple(Int32, Int32)) : ShapeState?
        drilled = parent_shape.drill_from_cell(index)
        return nil unless drilled
        @shapes << drilled
        request_rebuild
        drilled
    end

    # Spawn a new Shape pre-selected on the given table. Used by the History
    # changes summary ("→ Shape" button) so the user can inspect a changed
    # table without losing their current Shape configuration.
    def shape_add_for_table(table_lid : TableLID) : Nil
        context = @persistency.context.clone
        title = @persistency.display_name(table_lid) # blank -> "(unnamed)"
        shape = ShapeState.new(title, @persistency, context, table_lid)
        @shapes << shape
        request_rebuild
    end

    # === File Operations ===

    # Save the current document to `name`. Returns true on success, false on failure
    # (statusbar warning). The on-disk file and the in-memory document are left intact
    # on any failure. Public so the file lifecycle is testable without driving dialogs.
    def save_document(name : String) : Bool
        data = serialize_document # in memory first: a serialization failure never touches the disk
        tmp = "#{name}.tmp.#{Process.pid}"
        begin
            File.open(tmp, "wb") do |h|
                h.write(data)
                h.flush; h.fsync # durable on disk before the rename replaces the good file
            end
            File.rename(tmp, name) # atomic replace (POSIX rename / Windows MoveFileEx REPLACE_EXISTING)
        rescue ex
            File.delete(tmp) if File.exists?(tmp) # best-effort: never leave a stray temp behind
            raise ex
        end
        @filename = name
        @last_save_version = @persistency.version
        set_statusbar_info("Saved #{name}")
        true
    rescue ex
        set_statusbar_warning("Couldn't save #{name} — #{file_error_cause(ex)}; the previous version on disk is untouched")
        false
    end

    # The serialize step, named so the save path is testable (Persistency itself can't be
    # subclassed to fail — it is a JSON::Serializable root class).
    private def serialize_document : Bytes
        @persistency.save
    end

    # Map a file-operation exception to a short, user-facing cause — never a Crystal class name,
    # API detail ("mode 'rb'"), or an internal path. Raw detail goes to stderr for debugging.
    private def file_error_cause(ex : Exception) : String
        case ex
        when File::NotFoundError     then "file not found"
        when File::AccessDeniedError then "permission denied"
        when File::Error             then "couldn't access the file"
        when ConditionsNotMet        then ex.message || "invalid file" # ConditionsNotMet messages are author-written + clean
        else
            # Same switch every other diagnostic uses, so the fault-INJECTION specs (which cause
            # these on purpose) do not print an alarming line on every green run.
            STDERR.puts("file op error: #{ex.class}: #{ex.message}") if CrymbleUI::Widget.enable_warnings
            "unexpected error"
        end
    end

    private def do_save(name : String)
        save_document(name)
        request_rebuild
    end

    private def do_save_as
        dialog = Dialogs::DirBrowser.new("Save file as...", "*.embrace") do |name|
            do_save(name)
        end
        add_dialog(dialog)
    end

    private def do_newfile_empty
        protect_unsaved_changes("create a new (empty) file") do
            do_newfile_empty_impl
            @shapes.clear
            shape_add
            set_statusbar_info("New file (empty)")
            request_rebuild
        end
    end

    private def do_newfile_empty_impl
        @filename = nil
        @persistency = Persistency::Default.new
        table_lid = @persistency.add_table("") # truth: un-named; displays as "(unnamed)" via display_name
        @persistency.add_field(table_lid, "")
        @persistency.add_record(table_lid)
        @last_save_version = @persistency.version
    end

    private def do_newfile_demo
        protect_unsaved_changes("create a new (demo) file") do
            @filename = nil
            @persistency = Persistency::Default.new
            hash = Hash(String, FieldLID|TableLID|RecordLID).new
            help = TableReader(Persistency::Default,Persistency::Cell).new(@persistency, hash)
            help << <<-EOT
                Cities
                City | Country
                Arizona | USA
                Boston | USA
                Chicago | USA
                Dalbreck | Remnant Kingdoms
                Mordor | Middle-earth
                Morrighan | Remnant Kingdoms
                New York | USA
                Reykjavik | Iceland
                San Francisco | USA
                Shire | Middle-earth
                Venda | Remnant Kingdoms
                unknown | unknown

                Times
                Time
                Former
                Future
                Present

                Projects
                Project
                Arts
                Autonomy
                Curiosity
                Healing
                Justice
                Law
                Loyalty
                Peace
                Suppression
                Survival

                Persons
                Person | City_City
                Alan | Boston
                Amanita | San Francisco
                Denny | Boston
                Helen | New York
                Jared | Arizona
                Jezelia | Morrighan
                Kaden | Venda
                Max | New York
                Melanie | Arizona
                Rafferty | Dalbreck
                Riley | Reykjavik
                Samwise | Shire
                Sauron | Mordor
                Wanda | unknown
                Will | Chicago

                Allocations
                Person_Person | Time_Time | Project_Project | Allocation
                Alan | Present | Law | 100
                Denny | Present | Law | 100
                Sauron | Former | Suppression | 100
                Samwise | Former | Peace | 100
                Wanda | Future | Peace | 100
                Melanie | Future | Survival | 100
                Jared | Future | Survival | 100
                Jezelia | Future | Autonomy | 100
                Rafferty | Future | Curiosity | 100
                Kaden | Future | Loyalty | 100
                Max | Present | Healing | 100
                Helen | Present | Healing | 100
                Will | Present | Justice | 100
                Riley | Present | Arts | 100
                Amanita | Present | Arts | 100
            EOT
            @shapes.clear
            shape_add
            @last_save_version = @persistency.version
            set_statusbar_info("New file (demo)")
            request_rebuild
        end
    end

    # Load a document from `name`, replacing the current one. Returns true on success;
    # on failure returns false (statusbar warning) leaving the in-memory document and
    # @filename untouched. Public so the file lifecycle is testable without driving dialogs.
    def load_document(name : String) : Bool
        data = File.open(name, "rb", &.getb_to_end)
        # Parse into a SCRATCH persistency; commit to @persistency only once it fully succeeds, so a
        # failure leaves the current document (and the still-good on-disk file it names) untouched.
        fresh = Persistency::Default.new
        fresh.load(data)
        if leaf = fresh.get_ordered_commit_leaves.last?
            fresh.context.current_commit = leaf # set the leaf on FRESH before shape_add clones its context
        end
        @persistency = fresh
        @last_save_version = @persistency.version
        @shapes.clear
        shape_add
        @filename = name
        set_statusbar_info("Loaded #{name}")
        true
    rescue ex
        set_statusbar_warning("Couldn't load #{name} — #{file_error_cause(ex)}")
        false
    end

    private def do_load
        dialog = Dialogs::DirBrowser.new("Load file...", "*.embrace") do |name|
            protect_unsaved_changes("load '#{name}'") do
                load_document(name)
                request_rebuild
            end
        end
        add_dialog(dialog)
    end

    # Import an xlsx table into `shape`'s persistency as a new Shape. Returns true on
    # success; on failure returns false leaving the document and context stack untouched.
    def import_document(shape : ShapeState, filename : String, tablename : String) : Bool
        # Push a THROWAWAY context dup: Persistency#import wraps its mutations in a transaction that
        # rolls back the data, but NOT the top Context object (close_and_add_commit mutates it in
        # place). The dup absorbs that and is discarded by the ensure-pop below, so the shape's own
        # context is never left pointing at a rolled-back commit.
        shape.persistency.contexts.push(shape.context.dup)
        begin
            table_lid = shape.persistency.import(filename, tablename)
            new_shape = ShapeState.new("Shape", shape.persistency, shape.persistency.context, table_lid)
            # ShapeState.new above reads the still-pushed context — THAT is what must
            # precede the pop; the array append itself reads nothing.
            @shapes << new_shape
            n = shape.persistency.get_record_lids(table_lid).size
            set_statusbar_info("Imported \"#{tablename}\" (#{n} records) from #{filename}")
            true
        rescue ex
            set_statusbar_warning("Couldn't import #{filename} — #{file_error_cause(ex)}; nothing was added")
            false
        ensure
            shape.persistency.contexts.pop
        end
    end

    # === Clipboard ===

    # Put the Shape's rendered grid on the system clipboard as TSV.
    #
    # ORDER IS LOAD-BEARING: everything is validated and the whole string built BEFORE
    # the clipboard is touched, because the failure message promises the clipboard is
    # unchanged — and a copy overwrites global, cross-application state with no undo.
    def copy_shape_to_clipboard(shape : ShapeState) : Bool
        adapter = shape.matrix_adapter
        raise ConditionsNotMet.new("this Shape has no table picked") unless adapter
        rows, cols = adapter.size
        raise ConditionsNotMet.new("this Shape has nothing to copy") if rows == 0 || cols == 0
        tsv = adapter.to_tsv
    rescue ex
        # Only the PREPARATION is guarded by this promise. Everything above runs
        # before the clipboard is touched, so "unchanged" is guaranteed here.
        set_statusbar_warning("Couldn't copy — #{file_error_cause(ex)}; the clipboard is unchanged")
        return false
    else
        # The write itself is deliberately OUTSIDE that rescue: if handing the text to
        # the OS fails, the clipboard's state is unknown, so claiming it is unchanged
        # would be a lie. Report it as its own case.
        begin
            CrymbleUI::Widget.clipboard.text = tsv
        rescue ex
            set_statusbar_warning("Couldn't copy — #{file_error_cause(ex)}")
            return false
        end
        set_statusbar_info("Copied #{rows} rows × #{cols} columns to the clipboard")
        true
    end

    # Build a new table from clipboard TSV and open a Shape on it.
    #
    # Reads @persistency.context rather than a Shape's, so this works with NO Shape
    # open — which is why it lives on the app menu rather than a Shape's. Otherwise it
    # mirrors import_document's atomicity: a throwaway context dup absorbs the fact
    # that a transaction rolls back data but NOT the Context object.
    def paste_clipboard_as_new_table : Bool
        text = CrymbleUI::Widget.clipboard.text
        # ONE emptiness predicate: the real backend returns "" for an empty clipboard,
        # for no owner AND for a conversion timeout — nil is reachable only in specs.
        raise ConditionsNotMet.new("nothing on the clipboard") if text.nil? || text.empty?
        rows = TSV.decode(text) # non-empty text always decodes to at least one row
        # The codec is policy-free, so the blank policy is applied HERE: pad to the
        # widest row so every record has the same fields, an absent cell becoming "".
        width = rows.max_of(&.size)
        cells = rows.map do |row|
            Array(Persistency::Cell).new(width) { |i| convert_pasted(row[i]? || "") }
        end
        @persistency.contexts.push(@persistency.context.dup)
        begin
            table_lid = @persistency.import_rows(cells, "", Array.new(width, ""))
            new_shape = ShapeState.new("Shape", @persistency, @persistency.context, table_lid)
            # ShapeState.new above reads the still-pushed context — THAT is what must
            # precede the pop; the array append itself reads nothing.
            @shapes << new_shape
            name = @persistency.display_name(table_lid) # "" stores unnamed; display it as such
            set_statusbar_info("Pasted as new table \"#{name}\" (#{cells.size} records) — fields are unnamed; " \
                               "if row 1 holds column names, right-click it and \"Take field names from record\"")
            true
        ensure
            @persistency.contexts.pop
        end
    rescue ex
        set_statusbar_warning("Couldn't paste — #{file_error_cause(ex)}; nothing was added")
        false
    end

    # A pasted field is user input, so it goes through the same parser as typing —
    # `'true` becomes a Bool, "42" an Int64. CellHelper.convert returns a tuple-wrapped
    # optional over the WIDER cell union, so it needs unwrapping and narrowing; the
    # narrowing is a `case`, never `.as`, which is a known crash surface against that
    # recursive union.
    private def convert_pasted(field : String) : Persistency::Cell
        converted = CellHelper.convert(field)
        return field unless converted
        case value = converted[0]
        when String, Int64, Float64, Bool, Nil then value
        else # CellHelper.convert cannot produce anything else; its wider declared
             # return type is an artifact. Assert rather than silently coping.
            raise ConditionsNotMet.new("unsupported pasted value")
        end
    end

    private def do_quit
        protect_unsaved_changes("quit") { quit }
    end

    # Add dialog, or bring existing one to front if already open
    private def add_dialog(dialog : Dialogs::Base)
        existing = @dialogs.find { |d| d.id == dialog.id && d.open }
        if existing
            find(existing.id).try { |w| w.as(CrymbleUI::WindowPanel).bring_to_front if w.is_a?(CrymbleUI::WindowPanel) }
        else
            @dialogs << dialog
        end
        request_rebuild
    end

    private def protect_unsaved_changes(message : String, &block : ->)
        if @last_save_version == @persistency.version
            yield
        elsif @pending_confirm
            find("confirm").try { |w| w.as(CrymbleUI::WindowPanel).bring_to_front }
        else
            @pending_confirm = {"You have unsaved changes - are you sure to #{message}?", block}
            request_rebuild
        end
    end
end
