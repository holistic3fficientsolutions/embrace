require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# The file browser, as a user meets it. Each example pins one thing that was wrong or missing.
class UsabilityTestApp < EmbraceApp
  def open_dialog(dialog : Dialogs::Base) : Nil
    add_dialog(dialog)
  end

  def save_as_dialog : Dialogs::DirBrowser
    do_save_as
    @dialogs.last.as(Dialogs::DirBrowser)
  end
end

private def fixture_dir : String
  dir = File.tempname("dirbrowser_ux")
  Dir.mkdir_p(File.join(dir, "sub"))
  File.write(File.join(dir, "a.embrace"), "one")
  File.write(File.join(dir, "b.embrace"), "two")
  File.write(File.join(dir, "note.txt"), "not matching the wildcard")
  dir
end

private def browser_in(dir : String, wildcard = "*.embrace", &block : String -> Nil) : Dialogs::DirBrowser
  previous = Dir.current
  Dir.cd(dir)
  dialog = Dialogs::DirBrowser.new("Load file...", wildcard, &block)
  Dir.cd(previous)
  dialog
end

private def row_id(dialog : Dialogs::DirBrowser, name : String) : String
  index = dialog.items.index { |(n, _, _, _)| n == name }
  raise "#{name} not listed: #{dialog.items.map(&.[0])}" unless index
  "dirbrowser_item_#{index}"
end

describe "file browser usability" do
  it "opens sorted ascending and keeps the direction while browsing" do
    dir = fixture_dir
    begin
      dialog = browser_in(dir) { |_| }
      dialog.sort_ascending.should be_true, "the browser opened sorted descending"
      dialog.navigate("sub")
      dialog.sort_ascending.should be_true, "walking into a directory flipped the sort order"
      dialog.navigate("..")
      dialog.sort_ascending.should be_true, "walking back out flipped it again"
      # A header click is the ONE thing that may flip it.
      dialog.sort_by(0)
      dialog.sort_ascending.should be_false, "clicking the sorted column did not reverse it"
      dialog.sort_by(1)
      dialog.sort_column.should eq(1)
      dialog.sort_ascending.should be_true, "a NEW column must start ascending"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "asks before overwriting an existing file" do
    dir = fixture_dir
    begin
      app = UsabilityTestApp.new
      renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
      dialog = app.save_as_dialog
      dialog.path = Path[dir]
      dialog.update
      renderer.settle_rendering(app)

      dialog.filename = "a.embrace" # already on disk, with content "one"
      dialog.accept
      renderer.settle_rendering(app)

      File.read(File.join(dir, "a.embrace")).should eq("one"),
        "Save As overwrote an existing file without asking"
      app.find("confirm").should_not be_nil, "no confirmation was offered"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "focuses the filename field when it opens" do
    dir = fixture_dir
    begin
      app = UsabilityTestApp.new
      renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
      dialog = browser_in(dir) { |_| }
      app.open_dialog(dialog)
      renderer.settle_rendering(app)

      focused = CrymbleUI::Widget.focus_manager?.try &.focused_widget
      focused.should_not be_nil, "nothing has focus, so typing a name goes nowhere"
      focused.not_nil!.id.should eq("#{dialog.id}_filename")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "can show files outside the wildcard" do
    dir = fixture_dir
    begin
      dialog = browser_in(dir) { |_| }
      dialog.items.map(&.[0]).should_not contain("note.txt")
      dialog.show_all = true
      dialog.update
      dialog.items.map(&.[0]).should contain("note.txt"),
        "a file with the wrong extension stays invisible and unopenable"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "creates a folder without leaving the app" do
    dir = fixture_dir
    begin
      dialog = browser_in(dir) { |_| }
      dialog.create_folder("fresh")
      Dir.exists?(File.join(dir, "fresh")).should be_true, "the folder was not created"
      dialog.items.map(&.[0]).should contain("fresh/"), "the new folder is not listed"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "walks the list with the arrow keys and acts on the row under the cursor with Enter" do
    # Driven the way the RENDERER routes keys, which is the whole point of this example:
    #   arrows  -> focus_manager.dispatch_key (focused widget, then spatial focus navigation)
    #   Enter   -> panel shortcuts FIRST, before the focused widget (sfml_renderer.cr)
    # The first version of this test fired both through shortcut_manager.trigger, so it proved the
    # bindings existed and nothing else. Up/Down never reach a panel shortcut at all — the focused
    # widget eats them — so the list is walked by the MATRIX's own cursor, and Enter must act on
    # the row under THAT, not on a second selection the dialog keeps to itself.
    dir = fixture_dir
    begin
      accepted : String? = nil
      app = UsabilityTestApp.new
      renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
      dialog = browser_in(dir) { |path| accepted = path }
      dialog.focus_list = true # a Load dialog: the keyboard starts on the list
      app.open_dialog(dialog)
      renderer.settle_rendering(app)

      focus = CrymbleUI::Widget.focus_manager
      root = app.root.not_nil!
      panel = app.find(dialog.id).not_nil!
      matrix = app.find("#{dialog.id}_files").not_nil!.as(CrymbleUI::VirtualMatrix)

      focus.focused?(matrix).should be_true,
        "a Load dialog must start with the list focused, or the arrow keys go to the name field"

      # Fixture rows, dirs first: ../ (item 0), sub/ (1), a.embrace (2), b.embrace (3).
      # The cursor starts on the header row, so one Down lands on item 0.
      2.times { focus.dispatch_key(SF::Keyboard::Key::Down, false, false, false, root) }
      matrix.cursor_rc[0].should eq(2), "the arrow keys did not move the list cursor"

      CrymbleUI::Widget.shortcut_manager.trigger("Enter", panel.path_id).should be_true
      dialog.path.to_s.should eq(File.join(dir, "sub")),
        "Enter acted on something other than the row under the cursor"
      accepted.should be_nil, "Enter on a directory must not accept the dialog"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "still accepts a typed name when the list was never touched" do
    dir = fixture_dir
    begin
      accepted : String? = nil
      app = UsabilityTestApp.new
      renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
      dialog = browser_in(dir) { |path| accepted = path }
      app.open_dialog(dialog) # a Save-as style dialog: focus_list stays false
      renderer.settle_rendering(app)
      panel = app.find(dialog.id).not_nil!

      CrymbleUI::Widget.focus_manager.focused_widget.try(&.id).should eq("#{dialog.id}_filename")
      dialog.filename = "typed.embrace"
      CrymbleUI::Widget.shortcut_manager.trigger("Enter", panel.path_id)

      accepted.should_not be_nil, "Enter did not accept the typed name"
      accepted.not_nil!.should end_with("typed.embrace")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "needs a double-click to enter a directory, as it does to take a file" do
    dir = fixture_dir
    begin
      app = UsabilityTestApp.new
      renderer = CrymbleUI::Testing::TestRenderer.new(1200, 800)
      dialog = browser_in(dir) { |_| }
      app.open_dialog(dialog)
      renderer.settle_rendering(app)
      here = dialog.path.to_s

      app.find(row_id(dialog, "sub/")).not_nil!.as(CrymbleUI::Button).trigger_click
      dialog.path.to_s.should eq(here), "a single click walked into the directory"
      dialog.selected_name.should eq("sub/"), "a single click must select the directory"
      renderer.render_frame(app)

      matrix = app.find("#{dialog.id}_files").not_nil!.as(CrymbleUI::VirtualMatrix)
      adapter = matrix.adapter.not_nil!.as(CrymbleUI::Widgets::DirBrowser::MatrixAdapter)
      app.find(row_id(dialog, "sub/")).not_nil!.as(CrymbleUI::Button).trigger_click
      dialog.path.to_s.should eq(File.join(dir, "sub")), "a double-click did not enter the directory"
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
