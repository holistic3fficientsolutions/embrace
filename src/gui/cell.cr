# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../referencecell"
require "../persistency"

# Cell renderer for CrymbleUI
# In the declarative (retained-mode) model, cells are built as CrymbleUI widgets
# rather than being painted immediately each frame.

module CellHelper

extend self

# Convert user input string to typed value
def convert(value : String?) : {Cell?}?
    if value.nil?
        res = nil # input unchanged
    elsif !(res = value.to_i64?).nil?
        res = {res}
    elsif !(res = value.to_f64?).nil?
        res = {res}
    elsif value.strip == "'true"
        res = {true}
    elsif value.strip == "'false"
        res = {false}
    elsif value.strip == "'nil"
        res = {nil}
    else
        res = {value}
    end
    res
end

end # module CellHelper
