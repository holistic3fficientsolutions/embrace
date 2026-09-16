require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# Double-clicking a file in the browser must accept the dialog and close it.
#
# The defect this guards: the browser's MatrixAdapter is rebuilt on every frame, and the first
# click asks for exactly such a rebuild — so the activation state, which lives on the adapter, was
# gone before the second click arrived. crymbleui's DirBrowser documents that the host must carry
# last_click_file across frames and wire on_accept; embrace did neither, so every click read as a
# first click and the dialog never closed by itself.
#
# NO TIMING IS MODELLED ANY MORE. This file used to refresh a clock stamp on the live adapter just
# before the second click, because one headless frame of this app costs ~1.1s (measured; a full
# settle_rendering costs ~6.1s) against what was then a 500ms window — so no arrangement of real
# clicks could land inside it. The library removed that window: activation is a two-step
# gesture, and the second click acts whenever it comes. The stamp, and the modelling it required,
# are gone with it; what the host can still get wrong is asserted for real.
class BrowserTestApp < EmbraceApp
  def open_dialog(dialog : Dialogs::Base) : Nil
    add_dialog(dialog)
  end
end

describe "file browser double-click" do
  it "accepts and closes the dialog, across the rebuild the first click triggers" do
    dir = File.tempname("dirbrowser_spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "double.embrace"), "x")
    begin
      accepted : String? = nil
      previous = Dir.current
      Dir.cd(dir)
      dialog = Dialogs::DirBrowser.new("Load file...", "*.embrace") { |path| accepted = path }
      Dir.cd(previous)

      app = BrowserTestApp.new
      app.open_dialog(dialog)
      renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
      renderer.settle_rendering(app)

      index = dialog.items.index { |(name, _, _, _)| name == "double.embrace" }
      index.should_not be_nil, "the fixture file is not listed: #{dialog.items.map(&.[0])}"
      row_id = "dirbrowser_item_#{index}"
      app.find(row_id).should_not be_nil, "no clickable row widget #{row_id}"

      app.find(row_id).not_nil!.as(CrymbleUI::Button).trigger_click

      # The host must have taken the click state off the adapter and onto the dialog, which is the
      # only thing that outlives the rebuild the click just asked for.
      dialog.last_click_file.should eq("double.embrace"),
        "the first click was not recorded on the dialog, so the second cannot pair with it"

      renderer.render_frame(app) # the rebuild: a NEW adapter, which must be re-seeded from above

      matrix = app.find("#{dialog.id}_files").not_nil!.as(CrymbleUI::VirtualMatrix)
      adapter = matrix.adapter.not_nil!.as(CrymbleUI::Widgets::DirBrowser::MatrixAdapter)
      adapter.last_click_file.should eq("double.embrace"),
        "the rebuilt adapter starts blank — the host did not re-seed it from the dialog"

      app.find(row_id).not_nil!.as(CrymbleUI::Button).trigger_click

      accepted.should_not be_nil, "double-click did not accept the dialog"
      accepted.not_nil!.should end_with("double.embrace")
      dialog.open.should be_false, "the dialog stayed open after accepting"
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
