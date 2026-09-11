require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/gui/fieldlist"
require "../../lib/crymble-ui/src/testing/test_font"

# The cut-content marker, over the backgrounds THIS APP paints.
#
# CrymbleUI cannot check this on its own, which is why it lives here: its specs can only reach
# `Theme.current`, while the colours below are embrace's — two registered by our own palette,
# one a hardcoded constant in no theme at all, and the header colours computed at render time
# by shift_color. A library-side spec would certify the marker against tokens a user never sees.
#
# What is asserted is the WIRING, not the arithmetic. Asserting
# `bg.contrasting_neutral(f).contrast_ratio(bg) >= f` would be a tautology — that function
# returns a colour clearing `f` by construction, so it passes no matter what the widget did
# with it. So instead: build the cell embrace builds, render it, find the band it emitted, and
# require that band to be the one derived from the colour the cell PAINTS. A cell deriving from
# a theme token instead emits a different colour and fails here.
private def marker_floor : Float64
  CrymbleUI::PrimitiveBuilder::CLIPPED_MARKER_MIN_RATIO
end

# Long enough to overflow the narrow cell below.
CELL_LONG = "dddddddddddddddddddddddd"
CELL_BOX  = CrymbleUI::Rect.new(0.0, 0.0, 60.0, 20.0)

# The band a cell with this background actually emits, or nil if it emitted none.
#
# Located by GEOMETRY, not by eliminating known colours. The band is always a neutral, so
# elimination would drop it whenever it collided with the theme's text colour — in the dark
# theme a backdrop of luminance ~0.107 derives to exactly #D4D4D4 — and report "no marker" for
# a colour coincidence. It would equally adopt any future fill (a focus ring, a hover tint) as
# "the band". The band's rect is known, so match on that.
private def rendered_band(backdrop : CrymbleUI::Color) : CrymbleUI::Color?
  cell = CrymbleUI::TextInput.new(value: CELL_LONG, width: CELL_BOX.width,
    mode: CrymbleUI::TextInputMode::QuickEntry, background_color: backdrop)
  prims = cell.to_primitives(CELL_BOX)
  band_w = CrymbleUI::PrimitiveBuilder::CLIPPED_MARKER_WIDTH * CrymbleUI::FontSizing.zoom_factor
  # The bar sits on the CELL's inner edge — just inside the border — not on the text box,
  # which is additionally inset by the padding. A bar placed there floated a few pixels short
  # of the edge its horizontal twin sits on, which read as a gap rather than as a marker.
  right_edge = CELL_BOX.width - CrymbleUI::TextInput::BORDER_WIDTH
  prims.select(&.is_a?(CrymbleUI::FillRect))
    .map(&.as(CrymbleUI::FillRect))
    .find { |f| (f.bounds.x + f.bounds.width - right_edge).abs < 0.5 && f.bounds.width <= band_w + 0.5 }
    .try(&.color)
end

private def assert_marker_derived_from_paint(backdrop : CrymbleUI::Color, what : String)
  band = rendered_band(backdrop)
  band.should_not be_nil, "#{what}: the cell emitted no cut marker at all"
  actual = band.not_nil!
  actual.should eq(backdrop.contrasting_neutral(marker_floor)),
    "#{what}: marker #{actual} was not derived from the painted #{backdrop}"
  actual.contrast_ratio(backdrop).should be >= marker_floor
end

describe "the cut-content marker over embrace's own cell backgrounds" do
  # core's spec_helper installs NO font, so Widget.measure_text reports width 0 here and
  # nothing can ever overflow — an instrument that cannot contain the phenomenon would report
  # its absence, and every example below would pass by measuring nothing. Install the headless
  # font for this file only, and put back whatever was there: the font is a global, and other
  # core specs are entitled to the zero-width measurement they were written against.
  original_font = CrymbleUI::Widget.font
  before_each { CrymbleUI::Widget.font = CrymbleUI::Testing::TestFont.new }
  after_each { CrymbleUI::Widget.font = original_font } # nil-capable: restores "no font"

  it "measures a width at all (without this, every example below is vacuous)" do
    CrymbleUI::Widget.measure_text(CELL_LONG, 14.0).width.should be > 0.0
  end

  {% for theme in ["dark", "light"] %}
    context "in the {{theme.id}} theme" do
      before_each { CrymbleUI::Theme.set({{theme.id.symbolize}}) }
      after_each { CrymbleUI::Theme.set(:light) } # crymbleui's own default (theme.cr)

      it "is derived from a diff-highlighted cell's own colour" do
        # A hardcoded constant, in no theme at all — invisible to any library-side spec.
        assert_marker_derived_from_paint(
          SimpleMatrixAdapter::DIFF_HIGHLIGHT_COLOR, "diff cell")
      end

      it "is derived from the empty-cell and constraint colours" do
        %w[cell.empty constraint.ok constraint.nok].each do |key|
          assert_marker_derived_from_paint(CrymbleUI::Theme.current[key], key)
        end
      end

      it "is derived from every matrix header level's colour" do
        # shift_color returns its input UNLESS the level is even, so level 0 — the commonest
        # header on screen — is a shifted colour, not the base. Sweeping levels covers both
        # branches instead of assuming which one a user meets.
        (0..3).each do |level|
          [true, false].each do |is_row|
            assert_marker_derived_from_paint(
              GUI::FieldClassColors.header_bg(is_row, level), "header row=#{is_row} lvl=#{level}")
          end
        end
      end

      it "is derived from the field-class backgrounds" do
        %w[fieldlist.agg_bg fieldlist.col_bg fieldlist.row_bg fieldlist.free_bg].each do |key|
          assert_marker_derived_from_paint(CrymbleUI::Theme.current[key], key)
        end
      end
    end
  {% end %}

  it "would notice a marker derived from the wrong backdrop" do
    # Validates the instrument: the assertions above must be ABLE to fail. Deriving from the
    # theme's default input background instead of the cell's own colour is exactly the bug
    # this file exists to catch, and it yields a different band than a diff cell's.
    diff = SimpleMatrixAdapter::DIFF_HIGHLIGHT_COLOR
    wrong = CrymbleUI::Theme.current.input_background.contrasting_neutral(marker_floor)
    rendered_band(diff).should_not eq(wrong)
  end
end
