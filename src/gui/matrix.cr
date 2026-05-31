# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../patch"
require "../cache"
require "crymble-ui"

# Matrix adapter interface and helpers
# The widget implementation is in shape.cr as part of the CrymbleUI build tree.

# everything in {row,column}
module Interface::GUI::MatrixAdapter(T)
    abstract def version : Int32
    abstract def start_frame : Nil
    abstract def get_scrollorder : {Array(Int32), Array(Int32)} # rows, cols
    abstract def cell_get_name(index : {Int32, Int32}) : String
    abstract def cell_get_header_info(index : {Int32, Int32}) : {Bool, Int32}?
    abstract def cell_get_bounding_box(index : {Int32, Int32}) : { {Int32, Int32}, {Int32, Int32} }
    abstract def cell_read(index : {Int32, Int32}) : T
    abstract def cell_assign(index : {Int32, Int32}, value : T) : {Int32, Int32}
    abstract def cell_insert(index : {Int32, Int32}) : {Int32, Int32}
    abstract def cell_delete(index : {Int32, Int32}) : Nil
    abstract def cell_transform_to_name(index : {Int32, Int32}) : Nil
    abstract def cell_has_content(index : {Int32, Int32}) : Bool
    abstract def cell_move(from : {Int32, Int32}, to : {Int32, Int32}) : {Int32, Int32}
    def size : {Int32, Int32} # {row, col}
        get_scrollorder.map { |el| el.size }
    end
end
