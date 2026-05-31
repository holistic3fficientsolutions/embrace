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
        name_raw = @persistency.get_value(MetaFieldLIDs::Names, table_lid)
        title = name_raw.is_a?(String) ? name_raw : "Shape"
        shape = ShapeState.new(title, @persistency, context, table_lid)
        @shapes << shape
        request_rebuild
    end

    # === File Operations ===

    private def do_save(name : String)
        begin
            h = File.new(name, "wb")
            h.write(@persistency.save)
            h.close
            @filename = name
            set_statusbar_info("Saved as #{@filename}")
            @last_save_version = @persistency.version
        rescue ex
            set_statusbar_warning("Couldn't save #{@filename}")
        end
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
        table_lid = @persistency.add_table(Constant::Unnamed)
        @persistency.add_field(table_lid, Constant::Unnamed)
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

    private def do_load
        dialog = Dialogs::DirBrowser.new("Load file...", "*.embrace") do |name|
            protect_unsaved_changes("load '#{name}'") do
                begin
                    h = File.new(name, "rb")
                    @persistency = Persistency::Default.new
                    @persistency.load(h.getb_to_end)
                    h.close
                    leaves = @persistency.get_ordered_commit_leaves
                    if leaf = leaves.last?
                        @persistency.context.current_commit = leaf
                    end
                    @last_save_version = @persistency.version
                    @shapes.clear
                    shape_add
                    @filename = name
                    set_statusbar_info("Loaded #{@filename}")
                rescue ex
                    set_statusbar_warning("Couldn't load #{name}")
                end
                request_rebuild
            end
        end
        add_dialog(dialog)
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
