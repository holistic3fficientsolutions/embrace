require "spec"
require "file_utils"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crymble-ui/testing/test_renderer"

include Persistency

# An error that ends the app keeps the user's unsaved work: a recovery copy of the open document is written - checked
# to parse back, atomically, under a name that never overwrites another copy - and the error comes out unchanged, as
# the crash it is. Nothing is read back later: the user opens the copy with File > Load.

private class RecoveryApp < EmbraceApp
    property junk = false

    private def serialize_document : Bytes
        @junk ? "not a document".to_slice : @persistency.save
    end
end

# An app holding a table it has not saved (populated after construction: the unsaved-changes test sees it).
private def unsaved_app : RecoveryApp
    app = RecoveryApp.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, hash) << <<-EOT
        Sales
        Region | Amount
        north | 10
    EOT
    CrymbleUI::Testing::TestRenderer.new(400, 300).settle_rendering(app) # the scheduler a status line needs
    app
end

# A report that cannot be written: stderr closed, a broken pipe.
private class UnwritableIO < IO
    def read(slice : Bytes) : Int32
        0
    end

    def write(slice : Bytes) : Nil
        raise IO::Error.new("broken pipe")
    end
end

private def copies(dir : String) : Array(String)
    Dir.exists?(dir) ? Dir.children(dir).select(&.ends_with?(".embrace")).sort : [] of String
end

describe Recovery do
    around_each do |example|
        dir = File.tempname("recovery_spec")
        before = {Recovery.dir, Recovery.report}
        Recovery.dir = File.join(dir, "recovery")
        Recovery.report = IO::Memory.new
        example.run
    ensure
        Recovery.dir, Recovery.report = before if before
        FileUtils.rm_rf(dir) if dir
    end

    it "keeps unsaved work in a copy that loads, and lets the error out unchanged" do
        app = unsaved_app
        boom = RuntimeError.new("boom")
        came_out = expect_raises(RuntimeError) { Recovery.guarded(app) { raise boom } }
        came_out.should be(boom) # the same exception: the crash report and the exit status stay as they were
        names = copies(Recovery.dir.not_nil!)
        names.size.should eq(1)
        names.first.should match(/\Auntitled \d{4}-\d\d-\d\d \d\d-\d\d-\d\d\.embrace\z/)
        copy = File.join(Recovery.dir.not_nil!, names.first)
        File.open(copy, "rb", &.getb_to_end).should eq(app.persistency.save) # the work, all of it
        EmbraceApp.new.load_document(copy).should be_true
        Recovery.report.to_s.should eq("Unsaved work kept in #{File.expand_path(File.join(Recovery.dir.not_nil!, names.first))}\n")
    end

    it "writes nothing when nothing is unsaved" do
        app = unsaved_app
        dir = File.dirname(Recovery.dir.not_nil!)
        Dir.mkdir_p(dir)
        app.save_document(File.join(dir, "saved.embrace")).should be_true
        expect_raises(Exception, "boom") { Recovery.guarded(app) { raise "boom" } }
        copies(Recovery.dir.not_nil!).should be_empty
        Recovery.report.to_s.should be_empty
    end

    it "lets the error out unchanged when not even the report can be written" do
        app = unsaved_app
        Recovery.report = UnwritableIO.new
        boom = RuntimeError.new("boom")
        expect_raises(RuntimeError) { Recovery.guarded(app) { raise boom } }.should be(boom)
        copies(Recovery.dir.not_nil!).size.should eq(1) # kept, though nothing could say so
    end

    it "says why when the platform names no folder" do
        app = unsaved_app
        Recovery.dir = nil
        expect_raises(Exception, "boom") { Recovery.guarded(app) { raise "boom" } }
        Recovery.report.to_s.should eq("Unsaved work not kept: #{Recovery::NO_DIR}\n")
    end

    it "names the copy after the open document and leaves the document itself alone" do
        app = unsaved_app
        dir = File.dirname(Recovery.dir.not_nil!)
        Dir.mkdir_p(dir)
        original = File.join(dir, "x.embrace")
        app.save_document(original).should be_true
        saved = File.read(original)
        TableReader(Persistency::Default, Persistency::Cell).new(app.persistency, Hash(String, FieldLID | TableLID | RecordLID).new) << "More\nWhat\nit\n"
        expect_raises(Exception, "boom") { Recovery.guarded(app) { raise "boom" } }
        copies(Recovery.dir.not_nil!).first.should start_with("x ")
        File.read(original).should eq(saved)
    end

    it "says where the copy is as an absolute path, whatever the folder was given as" do
        app = unsaved_app
        relative = File.join("temp", "spec_fixtures", "recovery-#{Random::Secure.hex(4)}")
        Recovery.dir = relative
        path = app.write_recovery_copy.not_nil!
        Path[path].absolute?.should be_true
        Recovery.report.to_s.should eq("Unsaved work kept in #{path}\n")
    ensure
        FileUtils.rm_rf(relative) if relative
    end

    it "never overwrites a copy: a name taken gets a number" do
        app = unsaved_app
        now = Time.local(2026, 10, 3, 9, 15, 0)
        first = app.write_recovery_copy(now).not_nil!
        second = app.write_recovery_copy(now).not_nil!
        File.basename(first).should eq("untitled 2026-10-03 09-15-00.embrace")
        File.basename(second).should eq("untitled 2026-10-03 09-15-00 2.embrace")
    end

    it "adds no error of its own when the folder cannot be made" do
        app = unsaved_app
        dir = File.dirname(Recovery.dir.not_nil!)
        Dir.mkdir_p(dir)
        File.write(Recovery.dir.not_nil!, "a file where the folder would go")
        boom = RuntimeError.new("boom")
        expect_raises(RuntimeError) { Recovery.guarded(app) { raise boom } }.should be(boom)
        Recovery.report.to_s.should start_with("Unsaved work not kept: ")
    end

    it "writes nothing when the document would not parse back" do
        app = unsaved_app
        app.junk = true
        expect_raises(Exception, "boom") { Recovery.guarded(app) { raise "boom" } }
        copies(Recovery.dir.not_nil!).should be_empty
        Recovery.report.to_s.should start_with("Unsaved work not kept: ")
    end

    {% unless flag?(:win32) %}
        it "goes under XDG_DATA_HOME when that is absolute, and under ~/.local/share otherwise" do
            before = ENV["XDG_DATA_HOME"]?
            ENV["XDG_DATA_HOME"] = "/data/home"
            Recovery.default_dir.should eq("/data/home/embrace/recovery")
            ENV["XDG_DATA_HOME"] = "relative/dir" # the XDG rule: a relative path is ignored
            Recovery.default_dir.should eq(File.join(Path.home.to_s, ".local", "share", "embrace", "recovery"))
        ensure
            ENV["XDG_DATA_HOME"] = before
        end
    {% end %}
end
