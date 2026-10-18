# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# A panel's place in a cascade - a dialog's, a Shape's: an order number, placed once, when the panel first opens.
# Its asked position is taken from it (a Shape keeps it as its origin, asked again by a fresh tree), so placing anew
# would move the panel; the order number ranks the open panels, and the next one opens one step past the newest.
module Placed
    abstract def id : String

    @slot : Int32? = nil

    def slot : Int32
        @slot || raise "#{id} was never placed"
    end

    def placed? : Bool
        !@slot.nil?
    end

    def place(slot : Int32) : Nil
        raise "#{id} is placed already" if @slot
        @slot = slot
    end
end
