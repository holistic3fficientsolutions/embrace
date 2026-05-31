# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# some of those types are used inside pivot.cr, virtualtable.cr or persistency.cr
# (despite the files being very generic)

# for virtualtable.cr
# this is important in VT to highlight cells (all cells in a record instance) that are not existant (and hence not editable directly)
struct NilRecordStruct # there is no record; vs. Nil (which corresponds to undefined _cells_)
    def <=>(other : NilRecordStruct)
        0
    end
end
NilRecord = NilRecordStruct.new # usually this is being used (comparable to usage of `nil`)

# for pivot.cr
struct NilDeadAreaStruct
    def <=>(other : NilDeadAreaStruct)
        0
    end
end
NilDeadArea = NilDeadAreaStruct.new # usually this is being used (comparable to usage of `nil`)

# usually used for tristate together with Bool, e.g. for tristate checkbox states
struct SomeStruct
    def <=>(other : SomeStruct)
        0
    end
end
Some = SomeStruct.new

# interestingly enough, the interface here doesn't need the #value method;
# this is only needed when something needs to be printed to the screen (e.g. ReferenceCell), not for the algorithms in between
module Interface::Referenceable
    abstract def rank : Int32
    abstract def showall : Bool
    abstract def constrain(constraints : Hash(Int32,Int32))
    abstract def each_defined_fulfilling
    abstract def each_defined_fulfilling(& : Interface::Referenceable ->)
    abstract def each_defined_breaking
    abstract def each_defined_breaking(& : Interface::Referenceable ->)
    def ==(other : Referenceable) # needed since struct doesn't work (in class two "identical" instances are treated as not equal)
        @rank == other.rank
    end
    def <=>(other : Referenceable)
        mycmp(@rank, other.rank)
    end
end

# this is not used by the table classes (which is good)
require "./referencecell" # has to be below Referenceable definition
alias BaseCell = String|Int64|Float64|Bool|Nil|NilRecordStruct|NilDeadAreaStruct
alias Cell = BaseCell|ReferenceCell(BaseCell) # should be used for input cells
alias FieldlistCell = Int64|Bool|String|Nil

# beware of wrong type recursion
