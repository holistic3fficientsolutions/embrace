# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../virtualtable"

# Logical widget ids: handles a test acts on (crymble-ui's Testing::Driver, docs/TESTING.md there),
# never shown to the user and never derived from user-visible text.
module GUI::Ids
    # The key of a configurator node - a table, a field or a pseudo field of a Shape - and so of the
    # fieldlist column it renders: its EDGE path up to the Shape's root table, edges joined by ".".
    # A field's edge is its FieldLID, a pseudo field's its name (Rank, ShowAll); a reference hop
    # contributes the reference field and the target table's end of it, both FieldLIDs - the same
    # path VirtualTable keys a column's stable user id by. The root table itself is "root".
    #
    # Chosen because it survives what a user does: renames (it holds no names), commits, rebuilds,
    # deselecting and reselecting the column, and siblings coming and going. One field reached
    # through two references is two nodes with two keys. O(depth).
    def self.path_key(node : Table::VirtualTable::Tree) : String
        edges = [] of String
        current = node
        while (edge = current.edge_to_parent) && (parent = current.parent)
            edges << edge.to_s
            current = parent
        end
        edges.empty? ? "root" : edges.reverse!.join('.')
    end
end
