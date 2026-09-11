require "json"
require "crymble-ui"

# App-owned theme color tokens.
#
# crymbleui's theme JSON stays generic; embrace names + values its OWN tokens
# (constraint.*, fieldlist.*, vhtree.*, statusbar.info/warning, panel.*_warning,
# cell.empty) and registers them into the library's
# themes via `CrymbleUI::Theme.register_colors`. So the values live here, in
# embrace, not in the lib — and `Theme.current["constraint.ok"]` resolves exactly
# as before. Registered once at load (below), before any widget reads a color.
module GUI::AppTheme
  # resources/theme-colors.json — { "dark": {token: "#hex", ...}, "light": {...} }
  PALETTE_JSON = {{ read_file("#{__DIR__}/../../resources/theme-colors.json") }}

  # How strongly the Field list paints its drop target. Deliberately ABOVE the library's generic
  # `brightness.drag_opacity` (0.4): that value assumes a neutral background, while this panel's
  # sections are saturated (green Rows, blue Columns, brown Aggregates) and washed the signal out
  # to 0.31 effective — the "merely slightly lighter" field report of 2026-09-04. Lives here with
  # the palette rather than in fieldlist.cr, because it is a theme decision, not widget logic.
  # Set EAGERLY by `register!` below, from the same parse as the colours — not a class-var
  # initializer. Those initialise lazily through `crystal/once`, which is a second parse of the
  # same document and, on Crystal 1.21, a lazy-init site: crystal-lang/crystal#17212 (fixed in
  # 1.22) crashes when a constant initialises on a thread that has no scheduler.
  class_getter fieldlist_drag_opacity : Float64 = 0.0

  def self.register! : Nil
    root = JSON.parse(PALETTE_JSON)
    register_variant(:dark, root["dark"])
    register_variant(:light, root["light"])
    @@fieldlist_drag_opacity = root["constants"]["fieldlist.drag_opacity"].as_f
  end

  private def self.register_variant(variant : Symbol, node : JSON::Any) : Nil
    colors = Hash(String, CrymbleUI::Color).new
    node.as_h.each { |key, hex| colors[key] = CrymbleUI::Color.from_hex(hex.as_s) }
    CrymbleUI::Theme.register_colors(variant, colors)
  end
end

# Register at load — crymbleui's own themes are already built by the require above,
# and this runs before any Theme color is read (app startup or spec).
GUI::AppTheme.register!
