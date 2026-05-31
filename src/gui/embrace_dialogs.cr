# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# Dialog builder methods for EmbraceApp
# Extracted from embrace.cr for maintainability

class EmbraceApp < CrymbleUI::App
    private def build_dialog(dialog : Dialogs::Base) : Nil
        case dialog
        when Dialogs::ImportantInformer
            build_informer_dialog(dialog)
        when Dialogs::Decider
            build_decider_dialog(dialog)
        when Dialogs::Creator
            build_creator_dialog(dialog)
        when Dialogs::Renamer
            build_renamer_dialog(dialog)
        when Dialogs::AddField
            build_addfield_dialog(dialog)
        when Dialogs::ImportTable
            build_import_table_dialog(dialog)
        when Dialogs::FactorOut
            build_factor_out_dialog(dialog)
        when Dialogs::DirBrowser
            build_dirbrowser_dialog(dialog)
        when Dialogs::DisAssociateFields
            build_disassociate_dialog(dialog)
        end
    end

    private def build_informer_dialog(dialog : Dialogs::ImportantInformer) : Nil
        wp = window_panel(dialog.title, x: 250.0, y: 200.0, width: 500.0, height: 200.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            register_shortcut("Enter") { dialog.accept; request_rebuild }
            vstack(spacing: 10.0, padding: 10.0) do
                text(dialog.content)
                button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
            end
        end
        wp.title_bar_color = CrymbleUI::Theme.current["panel.title_bar_warning"]
        wp.background_color = CrymbleUI::Theme.current["panel.background_warning"]
    end

    private def build_decider_dialog(dialog : Dialogs::Decider) : Nil
        wp = window_panel(dialog.title, x: 250.0, y: 200.0, width: 500.0, height: 120.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            register_shortcut("Enter") { dialog.accept; request_rebuild }
            hstack(spacing: 10.0, padding: 10.0) do
                button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
                button("Cancel", id: "#{dialog.id}_cancel") { dialog.close; request_rebuild }
            end
        end
        wp.title_bar_color = CrymbleUI::Theme.current["panel.title_bar_warning"]
        wp.background_color = CrymbleUI::Theme.current["panel.background_warning"]
    end

    private def build_creator_dialog(dialog : Dialogs::Creator) : Nil
        window_panel(dialog.title, x: 250.0, y: 200.0, width: 400.0, height: 150.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            vstack(spacing: 10.0, padding: 10.0) do
                hstack(spacing: 5.0) do
                    text("Name:")
                    ti = text_input(dialog.name, id: "#{dialog.id}_name", width: 250.0,
                        on_event: ->(val : String, ev : CrymbleUI::TextInputEvent) {
                            dialog.name = val if ev.change?
                            if ev.submit?
                                dialog.accept; request_rebuild
                            elsif ev.cancel?
                                dialog.close; request_rebuild
                            end
                            nil
                        })
                    ti.request_focus
                end
                hstack(spacing: 10.0) do
                    button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
                    button("Cancel", id: "#{dialog.id}_cancel") { dialog.close; request_rebuild }
                end
            end
        end
    end

    private def build_renamer_dialog(dialog : Dialogs::Renamer) : Nil
        window_panel(dialog.title, x: 250.0, y: 200.0, width: 400.0, height: 150.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            vstack(spacing: 10.0, padding: 10.0) do
                hstack(spacing: 5.0) do
                    text("Old name: #{dialog.name_old}")
                end
                hstack(spacing: 5.0) do
                    text("New name:")
                    ti = text_input(dialog.name_new, id: "#{dialog.id}_name", width: 250.0,
                        on_event: ->(val : String, ev : CrymbleUI::TextInputEvent) {
                            dialog.name_new = val if ev.change?
                            if ev.submit?
                                dialog.accept; request_rebuild
                            elsif ev.cancel?
                                dialog.close; request_rebuild
                            end
                            nil
                        })
                    ti.request_focus
                end
                hstack(spacing: 10.0) do
                    button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
                    button("Cancel", id: "#{dialog.id}_cancel") { dialog.close; request_rebuild }
                end
            end
        end
    end

    private def build_addfield_dialog(dialog : Dialogs::AddField) : Nil
        window_panel(dialog.title, x: 250.0, y: 200.0, width: 450.0, height: 250.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            vstack(spacing: 10.0, padding: 10.0) do
                hstack(spacing: 5.0) do
                    text("Field name:")
                    ti = text_input(dialog.name, id: "#{dialog.id}_name", width: 250.0,
                        on_event: ->(val : String, ev : CrymbleUI::TextInputEvent) {
                            dialog.name = val if ev.change?
                            if ev.submit?
                                dialog.accept; request_rebuild
                            elsif ev.cancel?
                                dialog.close; request_rebuild
                            end
                            nil
                        })
                    ti.request_focus
                end

                if !dialog.suppress_reference
                    # Reference table selection
                    dialog.persistency.contexts.push(dialog.context)
                    table = dialog.persistency.get_table(MetaFieldLIDs::TableLastTable)
                    table.sort! { |x, y| x[2].as(String) <=> y[2].as(String) }
                    table_names = ["(no reference)"] + table.map(&.[2].as(String))
                    table_lids = [nil.as(Persistency::TableLID?)] + table.map(&.[0].as(Persistency::TableLID?))
                    ref_table_idx = table_lids.index(dialog.ref_table_lid) || 0

                    hstack(spacing: 5.0) do
                        text("References table:")
                        combo_box(items: table_names, selected: ref_table_idx, width: 200.0, id: "#{dialog.id}_reftable") do |idx|
                            dialog.ref_table_lid = table_lids[idx]
                            if rtl = dialog.ref_table_lid
                                field_lids = dialog.persistency.get_field_lids(rtl)
                                dialog.ref_field_lid = field_lids.first? ? field_lids.first : nil
                            else
                                dialog.ref_field_lid = nil
                            end
                            request_rebuild
                        end
                    end

                    if rtl = dialog.ref_table_lid
                        field_lids = dialog.persistency.get_field_lids(rtl)
                        field_names = field_lids.map { |fl| dialog.persistency.get_value(MetaFieldLIDs::Names, fl).as(String) }
                        field_idx = dialog.ref_field_lid ? (field_lids.index(dialog.ref_field_lid) || 0) : 0

                        hstack(spacing: 5.0) do
                            text("References field:")
                            combo_box(items: field_names, selected: field_idx, width: 200.0, id: "#{dialog.id}_reffield") do |idx|
                                dialog.ref_field_lid = field_lids[idx]
                                request_rebuild
                            end
                        end
                    end
                    dialog.persistency.contexts.pop
                end

                hstack(spacing: 10.0) do
                    button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
                    button("Cancel", id: "#{dialog.id}_cancel") { dialog.close; request_rebuild }
                end
            end
        end
    end

    private def build_import_table_dialog(dialog : Dialogs::ImportTable) : Nil
        window_panel(dialog.title, x: 250.0, y: 200.0, width: 450.0, height: 200.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            vstack(spacing: 10.0, padding: 10.0) do
                hstack(spacing: 5.0) do
                    text("Filename:")
                    ti = text_input(dialog.filename, id: "#{dialog.id}_file", width: 300.0,
                        on_event: ->(val : String, ev : CrymbleUI::TextInputEvent) {
                            dialog.filename = val if ev.change?
                            if ev.submit?
                                dialog.accept; request_rebuild
                            elsif ev.cancel?
                                dialog.close; request_rebuild
                            end
                            nil
                        })
                    ti.request_focus
                end
                hstack(spacing: 5.0) do
                    text("Table name:")
                    text_input(dialog.tablename, id: "#{dialog.id}_table", width: 250.0,
                        on_event: ->(val : String, ev : CrymbleUI::TextInputEvent) {
                            dialog.tablename = val if ev.change?
                            if ev.submit?
                                dialog.accept; request_rebuild
                            elsif ev.cancel?
                                dialog.close; request_rebuild
                            end
                            nil
                        })
                end
                hstack(spacing: 10.0) do
                    button("Browse...", id: "#{dialog.id}_browse") do
                        browser = Dialogs::DirBrowser.new("Select file", dialog.wildcard) do |path|
                            dialog.filename = path
                            request_rebuild
                        end
                        add_dialog(browser)
                    end
                    button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
                    button("Cancel", id: "#{dialog.id}_cancel") { dialog.close; request_rebuild }
                end
            end
        end
    end

    private def build_factor_out_dialog(dialog : Dialogs::FactorOut) : Nil
        window_panel(dialog.title, x: 250.0, y: 200.0, width: 450.0, height: 250.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            register_shortcut("Enter") { dialog.accept; request_rebuild }
            vstack(spacing: 10.0, padding: 10.0) do
                dialog.persistency.contexts.push(dialog.context)

                table = dialog.persistency.get_table(MetaFieldLIDs::TableLastTable)
                table.sort! { |x, y| x[2].as(String) <=> y[2].as(String) }
                table_names = table.map(&.[2].as(String))
                table_lids = table.map(&.[0].as(Persistency::TableLID))
                target_idx = dialog.target_table_lid ? (table_lids.index(dialog.target_table_lid) || 0) : 0

                hstack(spacing: 5.0) do
                    text("Target table:")
                    combo_box(items: table_names, selected: target_idx, width: 200.0, id: "#{dialog.id}_table") do |idx|
                        dialog.target_table_lid = table_lids[idx]
                        field_lids = dialog.persistency.get_field_lids(table_lids[idx])
                        dialog.target_field_lid = field_lids.first? ? field_lids.first : nil
                        request_rebuild
                    end
                end

                if ttl = dialog.target_table_lid
                    field_lids = dialog.persistency.get_field_lids(ttl)
                    field_names = field_lids.map { |fl| dialog.persistency.get_value(MetaFieldLIDs::Names, fl).as(String) }
                    field_idx = dialog.target_field_lid ? (field_lids.index(dialog.target_field_lid) || 0) : 0

                    hstack(spacing: 5.0) do
                        text("Target field:")
                        combo_box(items: field_names, selected: field_idx, width: 200.0, id: "#{dialog.id}_field") do |idx|
                            dialog.target_field_lid = field_lids[idx]
                            request_rebuild
                        end
                    end
                end

                dialog.persistency.contexts.pop

                hstack(spacing: 10.0) do
                    button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
                    button("Cancel", id: "#{dialog.id}_cancel") { dialog.close; request_rebuild }
                end
            end
        end
    end

    private def build_disassociate_dialog(dialog : Dialogs::DisAssociateFields) : Nil
        window_panel(dialog.title, x: 200.0, y: 150.0, width: 580.0, height: 400.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            vstack(spacing: 10.0, padding: 10.0) do
                add_field_proc = ->(target : Symbol) {
                    table_name = dialog.configurator.persistency.get_value(MetaFieldLIDs::Names, dialog.table_lid).as(String)
                    add_dlg = Dialogs::AddField.new("Add new field to '#{table_name}'",
                        dialog.configurator.persistency, dialog.context, suppress_reference: true) do |name, ref_field_lid|
                        new_lid = dialog.configurator.persistency.add_field(dialog.table_lid, name, ref_field_lid)
                        dialog.configurator.toggle_select(dialog.configurator.tree[new_lid])
                        if target == :mux
                            dialog.mux_field_lid = new_lid
                        else
                            dialog.value_field_lid = new_lid
                        end
                        dialog.refresh_fields
                    end
                    add_dialog(add_dlg)
                    nil
                }

                rows = Array(Array(CrymbleUI::Widget)).new
                lbl1 = CrymbleUI::Text.new("Classification field:")
                cb1 = CrymbleUI::ComboBox.new(items: dialog.picker_names, selected: dialog.mux_index,
                    width: 200.0, id: "#{dialog.id}_mux") do |idx, _|
                    dialog.select_mux(idx)
                    request_rebuild
                end
                btn1 = CrymbleUI::Button.new("Add field...", id: "#{dialog.id}_add_mux") { add_field_proc.call(:mux) }
                rows << [lbl1.as(CrymbleUI::Widget), cb1.as(CrymbleUI::Widget), btn1.as(CrymbleUI::Widget)]
                lbl2 = CrymbleUI::Text.new("Value field:")
                cb2 = CrymbleUI::ComboBox.new(items: dialog.picker_names, selected: dialog.value_index,
                    width: 200.0, id: "#{dialog.id}_value") do |idx, _|
                    dialog.select_value(idx)
                    request_rebuild
                end
                btn2 = CrymbleUI::Button.new("Add field...", id: "#{dialog.id}_add_value") { add_field_proc.call(:value) }
                rows << [lbl2.as(CrymbleUI::Widget), cb2.as(CrymbleUI::Widget), btn2.as(CrymbleUI::Widget)]

                widget(CrymbleUI::RecursiveGrid.new(content: rows, spacing: 5.0))

                text("Select fields to be transformed:")
                vstack(spacing: 2.0) do
                    dialog.field_lids.each_with_index do |lid, i|
                        disabled = (dialog.mux_field_lid == lid) || (dialog.value_field_lid == lid)
                        state = dialog.field_selected[i] ? CrymbleUI::CheckState::Checked : CrymbleUI::CheckState::Unchecked
                        cb = checkbox(dialog.field_names[i], state: state, id: "#{dialog.id}_cb_#{i}") {
                            dialog.field_selected[i] = !dialog.field_selected[i]
                            request_rebuild
                        }
                        cb.enabled = !disabled
                    end
                end

                hstack(spacing: 10.0) do
                    b_ass = button("Associate fields!", id: "#{dialog.id}_associate") {
                        dialog.associate!
                        request_rebuild
                    }
                    b_ass.enabled = dialog.can_associate?

                    b_diss = button("Dissociate fields!", id: "#{dialog.id}_dissociate") {
                        dialog.dissociate!
                        request_rebuild
                    }
                    b_diss.enabled = dialog.can_dissociate?

                    button("Done", id: "#{dialog.id}_done") { dialog.close; request_rebuild }
                end
            end
        end
    end

    private def build_dirbrowser_dialog(dialog : Dialogs::DirBrowser) : Nil
        popup_bg = CrymbleUI::Theme.current.popup_background
        window_panel(dialog.title, x: 100.0, y: 80.0, width: 700.0, height: 500.0, id: dialog.id) do
            on_closed { dialog.close; request_rebuild }
            register_shortcut("Escape") { dialog.close; request_rebuild }
            vstack(spacing: 5.0, padding: 10.0) do
                hstack(spacing: 1.0) do
                    dialog.path.parts.each_with_index do |part, i|
                        button(part, padding: 2.0, id: "#{dialog.id}_path_#{i}") do
                            dialog.navigate_to_part(i + 1)
                            request_rebuild
                        end
                        text("/") if i < dialog.path.parts.size - 1
                    end
                end

                drives = dialog.drives
                if !drives.empty?
                    hstack(spacing: 1.0) do
                        drives.each_with_index do |drv, i|
                            button(drv, padding: 2.0, id: "#{dialog.id}_drv_#{i}") do
                                dialog.path = Path[drv]
                                dialog.update
                                request_rebuild
                            end
                        end
                    end
                end

                adapter = CrymbleUI::Widgets::DirBrowser::MatrixAdapter.new
                adapter.items = dialog.items
                adapter.sort_column = dialog.sort_column
                adapter.sort_ascending = dialog.sort_ascending
                adapter.selected_filename = dialog.filename
                adapter.on_navigate = ->(dirname : String) {
                    dialog.navigate(dirname)
                    request_rebuild
                    nil
                }
                adapter.on_select_file = ->(name : String) {
                    dialog.select_file(name)
                    request_rebuild
                    nil
                }
                adapter.on_sort = ->(col : Int32) {
                    dialog.update(col)
                    request_rebuild
                    nil
                }
                expanded do
                    vm = widget(CrymbleUI::VirtualMatrix.new(
                        adapter: adapter,
                        id: "#{dialog.id}_files",
                    ))
                    vm.as(CrymbleUI::VirtualMatrix).show_rulers = false
                end

                separator

                hstack(spacing: 5.0) do
                    text("Filename:")
                    text_input(dialog.filename, id: "#{dialog.id}_filename", width: 400.0,
                        on_event: ->(val : String, ev : CrymbleUI::TextInputEvent) {
                            dialog.filename = val if ev.change?
                            if ev.submit?
                                dialog.accept; request_rebuild
                            elsif ev.cancel?
                                dialog.close; request_rebuild
                            end
                            nil
                        })
                end
                hstack(spacing: 10.0) do
                    button("Ok", id: "#{dialog.id}_ok") { dialog.accept; request_rebuild }
                    button("Cancel", id: "#{dialog.id}_cancel") { dialog.close; request_rebuild }
                end
            end
        end
    end
end
