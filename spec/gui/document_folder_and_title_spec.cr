require "./support/embrace_ui"

# Where the document is, as the user meets it: a file dialog starts in the folder of the file last picked in one
# (Load, Save as, Import's Browse) - before any pick, in the folder embrace was started in - and the window title
# names the document, with a "*" while it has changes not saved yet.

private ROWS = "People\nName | Age\nAnn | 1\n"

# A folder under temp/ (gitignored), holding one document.
private def document_folder(& : String ->) : Nil
    dir = "temp/spec_fixtures/folder-#{Random::Secure.hex(4)}"
    Dir.mkdir_p(dir)
    persistency = ::Persistency::Default.new
    Fixtures.read_tables(persistency, ROWS)
    File.write(File.join(dir, "kept.embrace"), persistency.save)
    yield dir
ensure
    FileUtils.rm_rf(dir) if dir
end

private def title(ui : EmbraceUI) : String
    ui.app.root.as(CrymbleUI::Window).title
end

describe "a file dialog's folder" do
    it "Load starts in the folder Save as last wrote to" do
        document_folder do |dir|
            ui = EmbraceUI.start
            ui.menu(:file_save_as)
            ui.dialog(:save_as) { |d| d.open_file(dir); d.fill(:filename, "fresh"); d.click(:ok) }
            ui.menu(:file_load)
            ui.dialog(:load) { |d| d.open_file("kept.embrace") } # by its name alone: the dialog is in dir
            ui.status.should contain("Loaded")
        end
    end

    it "Save as starts in the folder of the document loaded" do
        document_folder do |dir|
            ui = EmbraceUI.start
            ui.menu(:file_load)
            ui.dialog(:load) { |d| d.open_file(File.join(dir, "kept.embrace")) }
            ui.menu(:file_save_as)
            ui.dialog(:save_as) { |d| d.fill(:filename, "copy"); d.click(:ok) }
            File.exists?(File.join(dir, "copy.embrace")).should be_true
        end
    end

    it "Import's Browse starts in the folder of the document loaded, and Load in the one Browse picked from" do
        document_folder do |dir|
            Dir.mkdir_p(File.join(dir, "books"))
            File.write(File.join(dir, "books", "book.xlsx"), "not really")
            ui = EmbraceUI.start
            ui.menu(:file_load)
            ui.dialog(:load) { |d| d.open_file(File.join(dir, "kept.embrace")) }
            ui.shape_menu(ui.app.shapes.first, :import_xlsx)
            import_id = ui.ui.only("importtable_").id.not_nil!
            ui.ui.click("#{import_id}_browse")
            browse = ui.ui.only("dirbrowser_").id.not_nil!
            ui.ui.open_file("#{browse}_files", "books/book.xlsx") # from dir
            Path[ui.ui.text("#{import_id}_file")].to_posix.to_s.should end_with(Path[dir, "books", "book.xlsx"].to_posix.to_s)
            ui.ui.click("#{import_id}_cancel")
            ui.menu(:file_load)
            load = ui.ui.only("dirbrowser_").id.not_nil!
            ui.ui.select_file("#{load}_files", "..") # books/ has no document: up one, back in dir
            ui.ui.select_file("#{load}_files", "..")
            ui.ui.open_file("#{load}_files", "kept.embrace")
            ui.status.should contain("Loaded")
        end
    end
end

describe "the window title" do
    it "names no document before one is saved or loaded, and the document after" do
        document_folder do |dir|
            ui = EmbraceUI.start
            title(ui).should eq("untitled - H3O Embrace®") # as embrace starts: nothing to save
            ui.menu(:file_load)
            ui.dialog(:load) { |d| d.open_file(File.join(dir, "kept.embrace")) }
            title(ui).should eq("kept.embrace - H3O Embrace®")
            ui.menu(:file_save_as)
            ui.dialog(:save_as) { |d| d.fill(:filename, "renamed"); d.click(:ok) }
            title(ui).should eq("renamed.embrace - H3O Embrace®")
        end
    end

    it "marks a document never saved that has data with a *" do
        title(EmbraceUI.tables(ROWS)).should eq("*untitled - H3O Embrace®")
    end

    it "marks changes not saved yet with a *, until the save" do
        document_folder do |dir|
            ui = EmbraceUI.start
            ui.menu(:file_load)
            ui.dialog(:load) { |d| d.open_file(File.join(dir, "kept.embrace")) }
            shape = ui.app.shapes.first
            ui.type_into_cell(shape, 1, "Name", "Bea")
            title(ui).should eq("*kept.embrace - H3O Embrace®")
            ui.menu(:file_save)
            title(ui).should eq("kept.embrace - H3O Embrace®")
        end
    end
end
