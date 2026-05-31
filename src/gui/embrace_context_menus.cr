# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# Context menu and VHTree drag-drop handlers for EmbraceApp
# Extracted from embrace.cr for maintainability

class EmbraceApp < CrymbleUI::App
    def handle_escape : Bool
        if @context_menu
            dismiss_context_menu
            return true
        end
        super
    end

    private def dismiss_context_menu
        @context_menu = nil
        if popup = @context_menu_popup
            find_window.try &.remove_overlay(popup)
            @context_menu_popup = nil
        end
        request_rebuild
    end

    private def find_window : CrymbleUI::Window?
        root = @root
        root.is_a?(CrymbleUI::Window) ? root : nil
    end

    private def make_vhtree_right_click_handler(shape : ShapeState, node : Interface::GUI::VHTreeAdapter) : Proc(CrymbleUI::Vec2, Nil)
        captured_shape = shape
        captured_node = node
        ->(pos : CrymbleUI::Vec2) {
            if captured_node.is_a?(SimpleVHTreeAdapter)
                adapter = captured_node.as(SimpleVHTreeAdapter)
                display = adapter.get_display_texts[1]? || "?"
                if adapter.is_table? && (tlid = adapter.table_lid)
                    show_table_context_menu(captured_shape, adapter, tlid, display, pos)
                elsif !adapter.is_pseudo_field? && (flid = adapter.field_lid) && (tlid = adapter.table_lid)
                    show_field_context_menu(captured_shape, adapter, flid, tlid, display, pos)
                end
            end
            nil
        }
    end

    # === Context Menu Helpers ===

    private def show_table_context_menu(shape : ShapeState, node : Interface::GUI::VHTreeAdapter?, table_lid : TableLID, table_name : String, pos : CrymbleUI::Vec2 = CrymbleUI::Vec2.new(300.0, 300.0)) : Nil
        items = [
            {"Rename table '#{table_name}'...", nil.as(String?), true, ->() {
                dialog = Dialogs::Renamer.new("Rename table", table_name) do |name|
                    shape.persistency.contexts.push(shape.context)
                    shape.persistency.set_value(MetaFieldLIDs::Names, table_lid, name)
                    shape.context = shape.persistency.contexts.pop
                    shape.update(true)
                    request_rebuild
                end
                add_dialog(dialog)
            }},
            {"Delete table '#{table_name}'", nil.as(String?), true, ->() {
                @pending_confirm = {"Are you sure to delete table '#{table_name}'?", ->() {
                    shape.persistency.contexts.push(shape.context)
                    shape.persistency.remove_table(table_lid)
                    shape.context = shape.persistency.contexts.pop
                    shape.update(true)
                    request_rebuild
                }}
                request_rebuild
            }},
            {"Associate / dissociate fields...", nil.as(String?), true, ->() {
                if configurator = shape.configurator_ref
                    dialog = Dialogs::DisAssociateFields.new("Associate / Dissociate fields", configurator, shape.context, table_lid)
                    add_dialog(dialog)
                end
            }},
        ]
        @context_menu = {pos.x, pos.y, "Table context menu", items}
        request_rebuild
    end

    private def show_field_context_menu(shape : ShapeState, node : Interface::GUI::VHTreeAdapter, field_lid : FieldLID, table_lid : TableLID, field_name : String, pos : CrymbleUI::Vec2 = CrymbleUI::Vec2.new(300.0, 300.0)) : Nil
        is_reference = !shape.persistency.get_outward_reference(field_lid).nil?
        items = [
            {"Rename field '#{field_name}'...", nil.as(String?), true, ->() {
                dialog = Dialogs::Renamer.new("Rename field", field_name) do |name|
                    shape.persistency.contexts.push(shape.context)
                    shape.persistency.set_value(MetaFieldLIDs::Names, field_lid, name)
                    shape.context = shape.persistency.contexts.pop
                    shape.update(true)
                    request_rebuild
                end
                add_dialog(dialog)
            }},
            {"Delete field '#{field_name}'", nil.as(String?), true, ->() {
                @pending_confirm = {"Are you sure to delete field '#{field_name}'?", ->() {
                    shape.persistency.contexts.push(shape.context)
                    tlid = shape.persistency.get_table_lid(field_lid).not_nil!
                    shape.persistency.remove_field(tlid, field_lid)
                    shape.context = shape.persistency.contexts.pop
                    shape.update(true)
                    request_rebuild
                }}
                request_rebuild
            }},
            {"Factor out reference / link...", nil.as(String?), !is_reference, ->() {
                dialog = Dialogs::FactorOut.new("Factoring out / linking '#{field_name}'", shape.persistency, shape.context, field_lid) do |target_table_lid, target_field_lid|
                    tlid = shape.persistency.get_table_lid(field_lid).not_nil!
                    ambiguous = shape.persistency.factor_out_reference(tlid, field_lid, target_table_lid, target_field_lid)
                    if ambiguous
                        set_statusbar_info("Attention: referenced cells not always unique")
                    end
                    shape.update(true)
                    request_rebuild
                end
                add_dialog(dialog)
            }},
            {"Factor in reference / unlink", nil.as(String?), is_reference, ->() {
                shape.persistency.contexts.push(shape.context)
                tlid = shape.persistency.get_table_lid(field_lid).not_nil!
                shape.persistency.factor_in_reference(tlid, field_lid)
                shape.context = shape.persistency.contexts.pop
                shape.update(true)
                request_rebuild
            }},
        ]
        @context_menu = {pos.x, pos.y, "Field context menu", items}
        request_rebuild
    end

    private def show_cell_context_menu(shape : ShapeState, pos : CrymbleUI::Vec2) : Nil
        adapter = shape.matrix_adapter
        return unless adapter
        vm = adapter.virtual_matrix
        return unless vm
        rc = vm.point_to_cell(pos) || vm.cursor_rc
        has_content = adapter.cell_has_content?(rc[0], rc[1])
        items = Array({String, String?, Bool, Proc(Nil)}).new

        items << {"Set to undefined/empty", "Ctrl+U", true, ->() {
            adapter.cell_set_undefined({rc[0], rc[1]})
            shape.update(true)
            request_rebuild
        }}
        items << {"Set to true", nil.as(String?), true, ->() {
            adapter.cell_assign({rc[0], rc[1]}, true)
            shape.update(true)
            request_rebuild
        }}
        items << {"Cut cell", "Ctrl+X", has_content, ->() {
            @cut_cell = {shape.id, rc[0], rc[1]}
        }}
        items << {"Paste cell", "Ctrl+V", !@cut_cell.nil?, ->() {
            if c = @cut_cell
                adapter.cell_move({c[1], c[2]}, {rc[0], rc[1]})
                @cut_cell = nil
                shape.update(true)
                request_rebuild
            end
        }}
        items << {"Insert record(s)", "Ins", true, ->() {
            adapter.cell_insert({rc[0], rc[1]})
            shape.update(true)
            request_rebuild
        }}
        items << {"Delete record(s)", "Del", true, ->() {
            adapter.cell_delete({rc[0], rc[1]})
            shape.update(true)
            request_rebuild
        }}
        items << {"Take field names from record", nil.as(String?), true, ->() {
            adapter.cell_transform_to_name({rc[0], rc[1]})
            shape.update(true)
            request_rebuild
        }}

        @context_menu = {pos.x, pos.y, "Cell context menu", items}
        request_rebuild
    end

    # === VHTree Drag-and-Drop ===

    private def handle_vhtree_drop(shape : ShapeState, data : CrymbleUI::DragData, to_node : Interface::GUI::VHTreeAdapter, pos : CrymbleUI::Vec2 = CrymbleUI::Vec2.new(300.0, 300.0)) : Nil
        return unless data.is_a?(VHTreeDragData)
        from_adapter = data.adapter
        to_adapter = to_node.as(SimpleVHTreeAdapter)
        move = to_adapter.calc_move_info(from_adapter)
        return unless move

        if move[0] == :internal
            items = [
                {"Move field", nil.as(String?), true, ->() {
                    execute_vhtree_move(shape, from_adapter, {:internal_move} + move[1..])
                }},
                {"Merge fields", nil.as(String?), true, ->() {
                    execute_vhtree_move(shape, from_adapter, {:internal_merge} + move[1..])
                }},
            ]
            @context_menu = {pos.x, pos.y, "Move or Merge", items}
            @context_menu_fresh = true
            request_rebuild
        else
            execute_vhtree_move(shape, from_adapter, move)
        end
    end

    private def execute_vhtree_move(shape : ShapeState, from_adapter : SimpleVHTreeAdapter, move : {Symbol, TableLID, FieldLID, TableLID, FieldLID, Table::VirtualTable::Tree}) : Nil
        persistency = shape.persistency
        persistency.contexts.push(shape.context)
        begin
            case move[0]
            when :internal_move
                persistency.move_field(move[1], move[2], move[4])
            when :internal_merge
                persistency.merge_fields(move[1], move[2], move[4])
            when :inwards
                field_lid = persistency.move_field_inwards(move[1], move[2], move[3], move[4])
                if persistency.get_field(move[4]).empty?
                    persistency.remove_field(move[3], move[4])
                else
                    move_field_name = persistency.get_value(MetaFieldLIDs::Names, move[4]).as(String)
                    set_statusbar_info("Original field '#{move_field_name}' has unused values - not deleting it")
                end
            when :outwards
                field_lid = persistency.move_field_outwards(move[1], move[2], move[3], move[4])
            end
        ensure
            shape.context = persistency.contexts.pop
        end
        shape.update(true)
        request_rebuild
    end
end
