require "./support/embrace_ui"

# Load, Save as and Import's Browse, as a user meets them through the File menu - only what is embrace's own: which
# dialog each opens (the wildcard, where the keyboard starts), what happens to the document (the unsaved-changes
# question, the overwrite question), and how a refusal reads in the status bar. The dialog itself - listing, sorting,
# the two-click gestures, New folder, the path buttons - is crymbleui's (spec/widgets/file_dialog_spec.cr there).
# Every act goes through the GUI: the dialog is reached by its id prefix, as each call site names it.

private ROWS = "People\nName | Age\nAnn | 1\n"

# A folder under temp/ (gitignored), where the dialogs start: the path the dialog walks to reach it.
private def fixture_folder(& : String ->) : Nil
    dir = "temp/spec_fixtures/dialog-#{Random::Secure.hex(4)}"
    Dir.mkdir_p(File.join(dir, "sub"))
    File.write(File.join(dir, "a.embrace"), "one")
    yield dir
ensure
    FileUtils.rm_rf(dir) if dir
end

describe "the file dialogs, from the File menu" do
    it "Load asks before replacing a document with unsaved changes, and replaces it once confirmed" do
        Fixtures.document_file("loaded", "Loaded\nWhat\nit\n") do |path|
            ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
            shape = ui.app.shapes.first
            ui.type_into_cell(shape, 1, "Name", "Bea") # unsaved
            ui.menu(:file_load)
            load = ui.ui.only("dirbrowser_").id.not_nil!
            ui.dialog(:load) { |d| d.open_file(path) }
            ui.ui.present?("confirm").should be_true # asked first
            ui.app.shapes.first.should be(shape)     # nothing replaced yet
            ui.ui.click("confirm_ok")
            ui.status.should contain("Loaded")
            ui.app.shapes.first.should_not be(shape)
            ui.ui.present?(load).should be_false # the dialog is gone
        end
    end

    it "Load opens with the keyboard on the list" do
        ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
        ui.menu(:file_load)
        load = ui.ui.only("dirbrowser_").id.not_nil!
        ui.ui.focused_id.should eq("#{load}_files")
        ui.ui.press("Escape")
        ui.ui.present?(load).should be_false
    end

    it "Save as writes a typed name with .embrace, and asks before overwriting" do
        fixture_folder do |dir|
            ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
            ui.menu(:file_save_as)
            ui.dialog(:save_as) do |d|
                d.open_file(dir) # into the folder: two clicks on each part
                d.fill(:filename, "fresh")
                d.click(:ok)
            end
            File.exists?(File.join(dir, "fresh.embrace")).should be_true
            ui.menu(:file_save_as)
            ui.dialog(:save_as) do |d|
                d.open_file(dir) # into the folder: two clicks on each part
                d.fill(:filename, "a") # a.embrace is on disk, "one"
                d.click(:ok)
            end
            ui.ui.present?("confirm").should be_true
            File.read(File.join(dir, "a.embrace")).should eq("one")
            ui.ui.click("confirm_ok")
            File.read(File.join(dir, "a.embrace")).should_not eq("one")
        end
    end

    it "Import's Browse fills the import dialog's file with the path picked, and closes" do
        fixture_folder do |dir|
            File.write(File.join(dir, "book.xlsx"), "not really")
            ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
            ui.shape_menu(ui.app.shapes.first, :import_xlsx)
            import_id = ui.ui.only("importtable_").id.not_nil!
            ui.ui.click("#{import_id}_browse")
            browse = ui.ui.only("dirbrowser_").id.not_nil!
            ui.ui.select_file("#{browse}_files", "temp") # a first click: a rebuild - the browser keeps the keyboard
            ui.ui.focused_id.not_nil!.should start_with(browse)
            ui.ui.select_file("#{browse}_files", "temp") # the second: into temp/
            ui.ui.open_file("#{browse}_files", File.join(dir.lchop("temp/"), "book.xlsx"))
            # Both sides in / form: the dialog shows the native absolute path (\ on Windows), while dir was
            # written with / and File.join adds the platform's separator - a mixed string matching neither.
            Path[ui.ui.text("#{import_id}_file")].to_posix.to_s.should end_with(Path[dir, "book.xlsx"].to_posix.to_s)
            ui.ui.present?(browse).should be_false
            ui.ui.present?(import_id).should be_true
        end
    end

    it "reports a folder that vanished in embrace's words, and no longer offers it" do
        fixture_folder do |dir|
            ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
            ui.menu(:file_load)
            ui.dialog(:load) do |d|
                d.open_file(dir) # into the folder: two clicks on each part
                files = ui.ui.focused_id.not_nil!
                ui.ui.select_file(files, "sub") # the first click
                FileUtils.rm_rf(File.join(dir, "sub"))
                ui.ui.expect_reported("Cannot open folder 'sub'") { ui.ui.select_file(files, "sub") }
                ui.status.should contain("Cannot open folder 'sub'")
                expect_raises(ArgumentError, /no "sub"/) { ui.ui.select_file(files, "sub") }
            end
        end
    end

    it "reports a path button to a folder that vanished in embrace's words" do
        fixture_folder do |dir|
            Dir.mkdir_p(File.join(dir, "sub", "deep"))
            ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
            ui.menu(:file_load)
            ui.dialog(:load) do |d|
                d.open_file(File.join(dir, "sub", "deep"))
                FileUtils.rm_rf(File.join(dir, "sub"))
                sub = Path[Dir.current, dir, "sub"].parts.size - 1 # the path button naming "sub"
                load = ui.ui.only("dirbrowser_").id
                ui.ui.expect_reported("Cannot open folder 'sub'") { ui.ui.click("#{load}_path_#{sub}") }
            end
            ui.status.should contain("Cannot open folder 'sub'")
        end
    end

    it "reports a folder it cannot create in embrace's words" do
        fixture_folder do |dir|
            ui = EmbraceUI.new(Fixtures.app(ROWS)[0])
            ui.menu(:file_save_as)
            ui.dialog(:save_as) do |d|
                d.open_file(dir) # into the folder: two clicks on each part
                d.fill(:filename, "a.embrace") # a file has the name
                ui.ui.expect_reported("Cannot create folder 'a.embrace'") { d.click(:new_folder) }
            end
            ui.status.should contain("Cannot create folder 'a.embrace'")
        end
    end
end
