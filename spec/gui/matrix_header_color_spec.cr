require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui"

include Persistency

# Reuse the demo fixture shape from matrix_adapter_spec.
private def make_demo_persistency : Persistency::Default
  persistency = Persistency::Default.new
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      Cities
      City | Country
      Arizona | USA
      Boston | USA

      Persons
      Person | City_City
      Alan | Boston
  EOT
  persistency
end

private def create_shape(persistency : Persistency::Default) : ShapeState
  context = persistency.context.clone
  ShapeState.new("Shape", persistency, context)
end

# Expected header tint = the shared field-class palette (row=green, col=blue,
# per-level saturation via GUI::FieldClassColors) — the exact helper the field
# list uses, so the perspective matches it. This guards that cell_paint applies
# that palette to header cells (regression: it used a flat grey ruler_label).
private def expected_header_bg(is_row : Bool, level : Int32) : CrymbleUI::Color
  GUI::FieldClassColors.header_bg(is_row, level)
end

private def background_of(widget : CrymbleUI::Widget) : CrymbleUI::Color?
  case widget
  when CrymbleUI::TextInput then widget.background_color
  when CrymbleUI::ComboBox  then widget.background_color
  else                           nil
  end
end

# Regression guard: after the CrymbleUI port the Perspective (VirtualMatrix)
# painted every header cell in one neutral grey (ruler_label), losing the
# field-list colours a user reported missing. Header cells must again adopt the
# fieldlist class palette so the perspective reads as colourfully as the field
# list.
describe SimpleMatrixAdapter do
  it "paints matrix header cells with the fieldlist class palette" do
    persistency = make_demo_persistency
    shape = create_shape(persistency)
    adapter = shape.matrix_adapter.not_nil!
    rows, cols = adapter.get_scrollorder
    header_count = 0
    rows.each do |r|
      cols.each do |c|
        info = adapter.cell_get_header_info({r, c})
        next unless info
        is_row, level = info
        widget = adapter.cell_paint(r, c)
        background_of(widget).should eq(expected_header_bg(is_row, level))
        header_count += 1
      end
    end
    header_count.should be > 0
  end

  # Per-level cue on even levels: v1's +0.20 saturation, plus a brightness pop so
  # it reads on a dark base (saturation alone barely moves a dark colour). Odd
  # levels stay at base. Tested on a fixed dark green so it's theme-independent.
  it "boosts even levels (more saturated AND brighter), leaves odd at base" do
    base = CrymbleUI::Color.new(30_u8, 64_u8, 32_u8) # a dark, low-value green (like dark fieldlist.row_bg)
    GUI::FieldClassColors.shift_color(base, 1).should eq(base) # odd: unchanged
    even = GUI::FieldClassColors.shift_color(base, 0)
    even.to_hsv[:s].should be > base.to_hsv[:s]           # more saturated (v1's cue)
    even.to_hsv[:v].should be > base.to_hsv[:v]           # and brighter (reads on a dark base)
    even.to_hsv[:h].should be_close(base.to_hsv[:h], 2.0) # hue unchanged (degrees)
  end
end
