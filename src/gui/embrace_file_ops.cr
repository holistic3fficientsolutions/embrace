# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# File operations and shape management for EmbraceApp
# Extracted from embrace.cr for maintainability

class EmbraceApp < CrymbleUI::App
    # A new Shape opens on the branch of the Shape the user is in - the frontmost open Shape
    # panel - at that branch's tip. With no Shape open there is no branch to follow: it starts
    # where the document was loaded, and ShapeState#update snaps that to a tip. (Seeding from the
    # load position unconditionally opened every new Shape on the same branch, wherever the user
    # was working.)
    private def shape_add : Nil
        origin = front_shape
        context = origin ? origin.branch_tip_context : @persistency.context.clone
        @shapes << ShapeState.new("Shape", @persistency, context)
        request_rebuild
    end

    # The Shape the user is in: the frontmost open Shape panel (a click brings a panel to the
    # front). A Shape's panel carries the Shape's id (build_shape_panel).
    private def front_shape : ShapeState?
        return nil unless r = root
        by_id = @shapes.index_by(&.id)
        front = r.find_all_panels.reject(&.closed).compact_map { |panel|
            panel.id.try { |id| by_id[id]? }.try { |shape| {panel.z_index, shape} }
        }.max_by?(&.[0])
        front.try(&.[1])
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
    #
    # The context comes from `source` — the Shape whose summary was clicked —
    # never from `@persistency.context`. The row's counts were read under that
    # Shape's context, and a per-Shape commit or branch fork leaves the app's
    # base context behind on another commit (another BRANCH, once a Shape has
    # forked one), so the app context would open the table on data the clicked
    # row never described.
    def shape_add_for_table(source : ShapeState, table_lid : TableLID) : Nil
        context = source.context.clone
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
        write_atomically(name, serialize_document) # in memory first: a serialization failure never touches the disk
        @filename = name
        @last_save_version = @persistency.version
        set_statusbar_info("Saved #{name}")
        true
    rescue ex
        set_statusbar_warning("Couldn't save #{name} — #{file_error_cause(ex)}; the previous version on disk is untouched")
        false
    end

    # `data` at `name`, whole or not at all: written beside it, made durable, then renamed over it - a failure at
    # any step leaves what was at `name` untouched. Saving and the recovery copy both write this way.
    private def write_atomically(name : String, data : Bytes) : Nil
        tmp = "#{name}.tmp.#{Process.pid}"
        File.open(tmp, "wb") do |h|
            h.write(data)
            h.flush; h.fsync # durable on disk before the rename replaces the good file
        end
        File.rename(tmp, name) # atomic replace (POSIX rename / Windows MoveFileEx REPLACE_EXISTING)
    rescue ex
        File.delete(tmp) if tmp && File.exists?(tmp) # best-effort: never leave a stray temp behind
        raise ex
    end

    # Keep the unsaved work of an app that is ending on an error (Recovery.guarded), and say how that went. Returns
    # the copy's path, or nil when nothing was unsaved or nothing could be kept. Never raises: it runs on the way out
    # of a crash and must not replace the error that caused it. Touches no widget - the UI may be what failed.
    def write_recovery_copy(now : Time? = nil) : String?
        return if @last_save_version == @persistency.version
        path = nil
        Recovery.say(begin
            path = recovery_copy(now || Time.local)
            "Unsaved work kept in #{path}"
        rescue ex
            "Unsaved work not kept: #{ex.message}"
        end)
        path
    end

    # A copy in Recovery.dir, checked to parse back, written atomically under a name no other copy has; its absolute
    # path. Raises what stops it, for write_recovery_copy to say.
    private def recovery_copy(now : Time) : String
        dir = Recovery.dir || raise Recovery::NO_DIR
        data = serialize_document
        Persistency::Default.new.load(data) # the parse Load does: a copy that fails it would only look like a rescue
        Dir.mkdir_p(dir)
        stem = File.join(File.expand_path(dir),
            "#{@filename.try { |f| File.basename(f, ".embrace") } || "untitled"} #{now.to_s("%Y-%m-%d %H-%M-%S")}")
        path = "#{stem}.embrace"
        taken = 1
        while File.exists?(path)
            path = "#{stem} #{taken += 1}.embrace"
        end
        write_atomically(path, data)
        path
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
        dialog = Dialogs::FileBrowser.new("Save file as...", "*.embrace") do |name|
            # Picking a name that already exists is the one destructive thing this dialog can do,
            # and it did it silently. The write itself is atomic, so nothing can be left
            # half-replaced — but a file that was someone else's work is still gone, with no undo.
            if File.exists?(name)
                @pending_confirm = {"#{name} already exists - overwrite it?", ->{ do_save(name); nil }}
                request_rebuild
            else
                do_save(name)
            end
        end
        add_dialog(dialog)
    end

    private def do_newfile_empty
        protect_unsaved_changes("create a new (empty) file") do
            do_newfile_empty_impl
            clear_shapes
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
            clear_shapes
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
        clear_shapes
        shape_add
        @filename = name
        set_statusbar_info("Loaded #{name}")
        true
    rescue ex
        set_statusbar_warning("Couldn't load #{name} — #{file_error_cause(ex)}")
        false
    end

    private def do_load
        dialog = Dialogs::FileBrowser.new("Load file...", "*.embrace") do |name|
            protect_unsaved_changes("load '#{name}'") do
                load_document(name)
                request_rebuild
            end
        end
        dialog.focus_list = true # browsing: the arrows belong to the list
        add_dialog(dialog)
    end

    # Import an xlsx table into `shape`'s persistency as a new Shape. Returns true on
    # success; on failure returns false leaving the document and context stack untouched.
    def import_document(shape : ShapeState, filename : String, tablename : String) : Bool
        # Import on a DUP of the shape's context: on success the new Shape is built on it, so it owns
        # its own position and the source Shape's does not move when the import opens a commit (on a
        # failure the transaction puts the data and the dup's position back, and the dup is dropped).
        shape.persistency.with_context(shape.context.dup) do
            table_lid = shape.persistency.import(filename, tablename)
            new_shape = ShapeState.new("Shape", shape.persistency, shape.persistency.context, table_lid)
            # ShapeState.new above reads the still-pushed context — THAT is what must
            # precede the pop; the array append itself reads nothing.
            @shapes << new_shape
            n = shape.persistency.get_record_lids(table_lid).size
            set_statusbar_info("Imported \"#{tablename}\" (#{n} records) from #{filename}")
            true
        end
    rescue ex
        set_statusbar_warning("Couldn't import #{filename} — #{file_error_cause(ex)}; nothing was added")
        false
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

    # Build a new table from clipboard TSV and open a Shape on it, on the branch of the
    # Shape it was invoked from - like import_document: on a dup of that Shape's context,
    # which the new Shape is built on, so the source Shape's position does not move.
    #
    # Never on the persistency's base context: that is the position as of the last load,
    # never moved after it, so once a Shape had committed it named a closed commit and the
    # write forked a new branch nobody asked for. Every Shape carries its own position,
    # so a new table is a Shape act (Shape > Edit), and "New Shape" is always there.
    def paste_clipboard_as_new_table(shape : ShapeState) : Bool
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
        @persistency.with_context(shape.context.dup) do
            table_lid = @persistency.import_rows(cells, "", Array.new(width, ""))
            new_shape = ShapeState.new("Shape", @persistency, @persistency.context, table_lid)
            # ShapeState.new above reads the still-pushed context — THAT is what must
            # precede the pop; the array append itself reads nothing.
            @shapes << new_shape
            name = @persistency.display_name(table_lid) # "" stores unnamed; display it as such
            set_statusbar_info("Pasted as new table \"#{name}\" (#{cells.size} records) — fields are unnamed; " \
                               "if row 1 holds column names, right-click it and \"Take field names from record\"")
            true
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
    private def add_dialog(dialog : Dialogs::Hosted)
        existing = @dialogs.find { |d| d.id == dialog.id && d.open? }
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
