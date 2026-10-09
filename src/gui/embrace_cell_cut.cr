# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# Moving a cell with Ctrl+X / Ctrl+V (and the cell context menu's Cut / Paste cell): the ONE owner of the
# pending cut. A cut marks a grid position, so it holds only while nothing that could move cells has changed
# since: live_cut! compares the Shape's stamp (ShapeState#cut_stamp) and ends a stale cut. Every use goes
# through it - the marker restored at each build, and the paste, which can run in the same input batch as a
# non-structural write, before that write's rebuild (such a rebuild does not hold the input back).
# Besides a change of the data or of the Shape's perspective, the cut ends on the paste, on the first thing
# typed or pasted into another cell (its editor, or a reference cell's list), on Escape when nothing else
# takes it, and when its Shape closes.

class EmbraceApp < CrymbleUI::App
    # The Shape and the (top-left) cell a pending cut marks, and what its grid showed then.
    private record PendingCut, shape_id : String, cell : {Int32, Int32}, stamp : ShapeState::CutStamp

    NOTHING_TO_PASTE = "Nothing to paste - a cell cut with Ctrl+X ends on paste, Escape, typing into another " \
                       "cell, or any change of the data or the Shape's perspective"

    @cut : PendingCut? = nil

    # Cut the cell at `rc` of the Shape's grid (a sub-cell of a merge names its top-left) and mark it.
    private def arm_cut(shape : ShapeState, rc : {Int32, Int32}) : Nil
        stamp = shape.cut_stamp || return
        vm = grid_of(shape) || return
        cancel_cut
        cell = vm.get_top_left_cell(rc)
        @cut = PendingCut.new(shape.id, cell, stamp)
        vm.drag_source_cell = cell
        vm.mark_drag_overlay_dirty
    end

    # The cut cell, if the pending cut is this Shape's and still holds; a cut its Shape has outlived (the
    # stamp moved) is ended on the way - which is why this is a bang method, reads included.
    private def live_cut!(shape : ShapeState) : {Int32, Int32}?
        cut = @cut || return nil
        return nil unless cut.shape_id == shape.id
        return cut.cell if shape.cut_stamp.try(&.unchanged_from?(cut.stamp))
        cancel_cut
        nil
    end

    # Move the cut cell onto `rc`, as a drop does - the paste ends the cut; or say in the status bar why
    # nothing moves. A cut in another Shape is named - if it still holds there.
    private def paste_cut(shape : ShapeState, rc : {Int32, Int32}) : Nil
        if (cut = @cut) && cut.shape_id != shape.id && (owner = cut_shape) && live_cut!(owner)
            return set_statusbar_warning("The cut cell is in \"#{owner.display_title}\" - paste it there")
        end
        from = live_cut!(shape) || return set_statusbar_warning(NOTHING_TO_PASTE)
        adapter = shape.matrix_adapter.not_nil! # live_cut! found a grid
        cell_op(shape) { adapter.cell_move(from[0], from[1], rc[0], rc[1]) }
        cancel_cut
    end

    # End the pending cut, its marker taken off the grid directly - no rebuild: this runs while a cell is
    # being edited (the first keystroke), and a rebuild there would commit the edit mid-word.
    private def cancel_cut : Nil
        vm = cut_shape.try { |s| grid_of(s) }
        @cut = nil
        if vm
            vm.drag_source_cell = nil
            vm.mark_drag_overlay_dirty
        end
    end

    # Something was typed or pasted into a cell of this Shape: that ends a cut of another cell.
    private def cell_edit_started(shape : ShapeState, cell : {Int32, Int32}) : Nil
        cut = @cut || return
        cancel_cut unless cut.shape_id == shape.id && cut.cell == cell
    end

    # Close the Shape - its cut ends first, while the Shape still finds its grid. (A cut that outlived its
    # Shape would do no harm - cut_shape finds only open Shapes, and the stamp holds the old pivot - but it
    # would hold that pivot's data until the next cut.)
    private def close_shape(shape : ShapeState) : Nil
        cancel_cut if @cut.try(&.shape_id) == shape.id
        shape.close
        @shapes.reject! { |s| !s.open }
        request_rebuild
    end

    # Drop every Shape (a new or loaded document) - and with them any cut, for the same reason.
    private def clear_shapes : Nil
        cancel_cut
        @shapes.clear
    end

    # The open Shape the pending cut belongs to.
    private def cut_shape : ShapeState?
        cut = @cut || return nil
        @shapes.find(&.id.==(cut.shape_id))
    end

    private def grid_of(shape : ShapeState) : CrymbleUI::VirtualMatrix?
        shape.matrix_adapter.try(&.virtual_matrix)
    end
end
