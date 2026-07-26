require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"

include Persistency

# The diff precompute must resolve a matrix column to its field STRUCTURALLY (via the column's
# flat id -> VirtualTable#column_identity), never by comparing display names. Field names are not
# unique in embrace -- identity is the LID, names are labels (see CREDO: structural identity).
# Name matching had two concrete failure modes, each pinned by one spec below:
#   1. Two fields sharing a name -> both columns resolved to the FIRST same-named field, so an
#      edit in that field marked BOTH columns changed (false positive on the twin column).
#   2. A user field literally named "Rank" -> it hijacked the rank-column detection (last name
#      match wins), the row walk then read garbage ranks and skipped every row -> empty diff
#      (false negative: the real edit vanished).

private alias LidHash = Hash(String, FieldLID | TableLID | RecordLID)

# Build a one-table persistency, let the block arrange names inside the first commit, then close
# it and open a fresh commit for the pending edits. Returns the shape + the reader's LID hash
# (keyed by the ORIGINAL names, recorded before any rename).
private def make_shape(text : String, & : Persistency::Default, LidHash ->) : {ShapeState, LidHash}
  persistency = Persistency::Default.new
  hash = LidHash.new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << text
  yield persistency, hash
  persistency.close_and_add_commit
  persistency.close_and_add_commit # open commit for the pending edits
  {ShapeState.new("T", persistency, persistency.context.clone, hash["T"].as(TableLID)), hash}
end

describe "diff column identity is structural (no name matching)" do
  it "attributes an edit to exactly its own column when two fields share a name" do
    shape, hash = make_shape(<<-EOT) do |persistency, hash|
        T
        Region | Amount | Price
        north | 10 | 100
        south | 20 | 200
    EOT
      # Rename Price -> "Amount": two distinct fields, one display name.
      persistency.set_value(MetaFieldLIDs::Names, hash["Price"].as(FieldLID), "Amount")
    end
    persistency = shape.persistency
    amount_lid = hash["Amount"].as(FieldLID)
    edited_record = persistency.get_field(amount_lid).find { |_, v| v == 10i64 }.not_nil![0]
    persistency.set_value(amount_lid, edited_record, 999i64)

    diff = shape.spawn_diff_shape.not_nil!
    # Exactly ONE cell changed: the edited field's own column. Name matching resolved the
    # renamed twin column to the same FieldLID and marked it changed too (2 cells).
    diff.diff_changed_records.not_nil!.should eq(Set{edited_record})
    diff.diff_changed_cells.not_nil!.size.should eq(1)
  end

  it "still finds the edit when a user field is named \"Rank\"" do
    shape, hash = make_shape(<<-EOT) do |persistency, hash|
        T
        Grade | Amount
        7 | 10
        9 | 20
    EOT
      # A user field whose NAME collides with the rank pseudo-column's label.
      persistency.set_value(MetaFieldLIDs::Names, hash["Grade"].as(FieldLID), "Rank")
    end
    persistency = shape.persistency
    amount_lid = hash["Amount"].as(FieldLID)
    edited_record = persistency.get_field(amount_lid).find { |_, v| v == 10i64 }.not_nil![0]
    persistency.set_value(amount_lid, edited_record, 999i64)

    diff = shape.spawn_diff_shape.not_nil!
    # Name matching let the user column hijack rank detection: the walk then read the field's
    # VALUES (7, 9) as rank indices, skipped every row, and the diff came back empty.
    diff.diff_changed_records.not_nil!.should eq(Set{edited_record})
    diff.diff_changed_cells.not_nil!.size.should eq(1)
  end
end
