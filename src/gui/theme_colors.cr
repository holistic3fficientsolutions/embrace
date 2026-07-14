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

  def self.register! : Nil
    root = JSON.parse(PALETTE_JSON)
    register_variant(:dark, root["dark"])
    register_variant(:light, root["light"])
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
