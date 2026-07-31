require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/debug-helper"
require "../../src/constants"
require "crexcel"
require "xlsx-parser"
require "crymble-ui/testing/test_renderer"

include Persistency

# T-072 — file lifecycle atomicity. A failed load, save, or import must leave BOTH the on-disk
# file and the in-memory document exactly as they were. Each test pins a symptom that is RED
# against the pre-fix behavior (traced in the plan review):
#   T1  failed load must not split-brain (empty @persistency + old @filename) — the next save
#       would otherwise overwrite the good file with the empty document.
#   T2  failed save (serialization) must not truncate-in-place — the classic File.new("wb")-before-
#       -save bug leaves a 0-byte file where the user's data was.
#   T3  failed import must roll back fully (no half table) and not leak a context frame.

# Persistency can't be subclassed-to-fail (JSON::Serializable root class), so we intercept the
# app's serialize step instead. A toggled failure is what hits the truncate-in-place symptom — an
# unwritable path can't, since File.new raises BEFORE truncation and never distinguishes the bug.
class TestApp < EmbraceApp
  property fail_serialize = false

  private def serialize_document : Bytes
    raise "injected serialization failure" if @fail_serialize
    @persistency.save
  end
end

private def populate(persistency, table = "Sales") : Hash(String, FieldLID | TableLID | RecordLID)
  hash = Hash(String, FieldLID | TableLID | RecordLID).new
  help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
  help << <<-EOT
      #{table}
      Region | Amount
      north | 10
      south | 20
  EOT
  hash
end

private def make_app : TestApp
  app = TestApp.new
  app.shapes.clear
  hash = populate(app.persistency)
  app.shapes << ShapeState.new("Sales", app.persistency, app.persistency.context.clone, hash["Sales"].as(TableLID))
  # Settle once so the global scheduler exists (statusbar messages schedule a countdown timer on it).
  CrymbleUI::Testing::TestRenderer.new(400, 300).settle_rendering(app)
  app
end

private def read_bytes(path : String) : Bytes
  File.open(path, "rb", &.getb_to_end)
end

private def ctrl_key(code : SF::Keyboard::Key) : SF::Event::KeyPressedEvent
  e = SF::Event::KeyPressedEvent.new
  e.control = true; e.system = false; e.alt = false; e.shift = false
  e.code = code
  e
end

# Fire a real shortcut through a freshly-wired ShortcutManager (the menubar DSL registers its
# items into it on build_tree) — the renderer's actual key-routing step.
private def fire_shortcut(app : EmbraceApp, code : SF::Keyboard::Key) : Bool
  CrymbleUI::Testing::TestRenderer.new(1200, 800).settle_rendering(app)
  sm = CrymbleUI::ShortcutManager.new
  CrymbleUI::Widget.shortcut_manager = sm
  app.build_tree
  panel = app.root.try(&.find_topmost_panel)
  sm.handle_key_event(ctrl_key(code), panel)
end

# All tables' LIDs are the record LIDs of the TableLastTable pseudo-table.
private def table_count(persistency, context) : Int32
  persistency.contexts.push(context)
  n = persistency.get_record_lids(MetaFieldLIDs::TableLastTable).size
  persistency.contexts.pop
  n
end

private def numeric_header_xlsx : String # numeric header cell -> add_field(v.as(String)) raises (deterministic)
  file = File.tempname(".xlsx")
  wb = Crexcel::Workbook.new(file)
  ws = wb.add_worksheet("t")
  ws.write_row(0, [1, 2])
  ws.write_row(1, [3, 4])
  wb.close
  file
end

private def valid_xlsx : String
  file = File.tempname(".xlsx")
  wb = Crexcel::Workbook.new(file)
  ws = wb.add_worksheet("t")
  ws.write_row(0, ["Region", "Amount"])
  ws.write_row(1, ["north", 10])
  wb.close
  file
end

# This file injects serialization/IO failures on purpose and asserts the RECOVERY, so embrace's
# "file op error: ..." diagnostic fires by design. Silenced here only, so a genuine file-op failure
# in another spec still announces itself.
Spec.before_each { CrymbleUI::Widget.enable_warnings = false }
Spec.after_each { CrymbleUI::Widget.enable_warnings = true }

describe "T-072 file lifecycle atomicity" do
  it "T1: a failed load leaves the document intact, so a later save keeps the good file" do
    app = make_app
    good = File.tempname(".embrace")
    app.save_document(good).should be_true

    corrupt = File.tempname(".embrace")
    File.write(corrupt, Bytes[0xFF, 0xFF, 0xFF, 0xFF])
    # precondition: the corrupt bytes really fail to parse (fixture validity)
    expect_raises(ConditionsNotMet) { Persistency::Default.new.load(read_bytes(corrupt)) }

    before = app.persistency
    app.load_document(corrupt).should be_false
    app.persistency.same?(before).should be_true # RED pre-fix: do_load swaps @persistency before parsing
    app.filename.should eq(good)                  # RED pre-fix: consistent-but-empty split-brain

    # the kill chain: a save after the failed load must NOT destroy the good file
    app.save_document(good).should be_true
    fresh = TestApp.new
    fresh.load_document(good).should be_true # good still loads => it still holds the real document

    File.delete?(good)
    File.delete?(corrupt)
  end

  it "T2: a failed save (serialization) leaves the previous on-disk version byte-identical" do
    app = make_app
    good = File.tempname(".embrace")
    app.save_document(good).should be_true
    good_bytes = read_bytes(good)
    lsv = app.last_save_version

    app.fail_serialize = true # serialization now raises
    app.save_document(good).should be_false

    read_bytes(good).should eq(good_bytes)                       # RED pre-fix: File.new("wb") truncated it
    File.exists?("#{good}.tmp.#{Process.pid}").should be_false   # atomic-save leaves no temp residue
    app.last_save_version.should eq(lsv)                         # unchanged on failure

    File.delete?(good)
  end

  it "T3: a failed import rolls back fully and does not leak a context frame" do
    app = make_app
    shape = app.shapes.first
    bad = numeric_header_xlsx
    # precondition on a throwaway persistency (a raw import would mutate the app's under Step A)
    expect_raises(Exception) { Persistency::Default.new.import(bad, "Bad") }

    tc_before = table_count(app.persistency, shape.context)
    depth_before = app.persistency.contexts.size
    top_before = app.persistency.contexts.top
    cc_before = shape.context.current_commit

    app.import_document(shape, bad, "Bad").should be_false

    table_count(app.persistency, shape.context).should eq(tc_before)   # RED pre-fix: half-table committed
    app.persistency.contexts.size.should eq(depth_before)              # RED pre-fix: leaked pushed frame
    app.persistency.contexts.top.same?(top_before).should be_true      # stack top restored, not the dup
    shape.context.current_commit.should eq(cc_before)

    File.delete?(bad)
  end

  it "T3-success: a valid import adds the table and does not leak or double-pop a context frame" do
    app = make_app
    shape = app.shapes.first
    good = valid_xlsx
    depth_before = app.persistency.contexts.size

    app.import_document(shape, good, "Imported").should be_true
    app.persistency.contexts.size.should eq(depth_before) # guards the ensure+inline double-pop
    app.shapes.size.should eq(2)

    File.delete?(good)
  end

  it "T4: after a failed load, the real Ctrl+S shortcut keeps the good file (kill chain, end-to-end)" do
    app = make_app
    tables_before = table_count(app.persistency, app.shapes.first.context)
    good = File.tempname(".embrace")
    app.save_document(good).should be_true

    corrupt = File.tempname(".embrace")
    File.write(corrupt, Bytes[0xFF, 0xFF, 0xFF, 0xFF])
    app.load_document(corrupt).should be_false
    app.filename.should eq(good) # the ^S target is still the good file — the kill chain is live in the UI

    fire_shortcut(app, SF::Keyboard::Key::S).should be_true # menu "Save file" ^S

    # the good file must still be the REAL document, not the empty split-brain the old bug wrote
    reloaded = TestApp.new
    reloaded.load_document(good).should be_true
    table_count(reloaded.persistency, reloaded.shapes.first.context).should eq(tables_before)

    File.delete?(good)
    File.delete?(corrupt)
  end

  it "load rejects zlib-wrapped bad JSON and a truncated file, leaving the document intact" do
    app = make_app
    before = app.persistency

    io = IO::Memory.new
    zw = Compress::Zlib::Writer.new(io); zw << "{ not json"; zw.close
    bad_json = File.tempname(".embrace"); File.write(bad_json, io.to_slice)
    app.load_document(bad_json).should be_false           # fails at from_json (past zlib)
    app.persistency.same?(before).should be_true

    good = File.tempname(".embrace"); app.save_document(good).should be_true
    full = read_bytes(good)
    truncated = File.tempname(".embrace"); File.write(truncated, full[0, full.size // 2])
    app.load_document(truncated).should be_false          # fails mid-zlib-stream
    app.persistency.same?(before).should be_true

    {bad_json, good, truncated}.each { |f| File.delete?(f) }
  end

  it "a save whose parent path is a regular file fails cleanly, leaving other files + no temp behind" do
    app = make_app
    good = File.tempname(".embrace")
    app.save_document(good).should be_true
    good_bytes = read_bytes(good)

    barrier = File.tempname(".notdir"); File.write(barrier, "x") # a FILE where a directory is expected
    bad_target = File.join(barrier, "sub.embrace")               # parent is a file -> ENOTDIR everywhere (incl. Windows/root CI)
    app.save_document(bad_target).should be_false

    read_bytes(good).should eq(good_bytes) # an unrelated prior file is untouched
    File.exists?("#{bad_target}.tmp.#{Process.pid}").should be_false

    File.delete?(good)
    File.delete?(barrier)
  end

  it "an import of a header-only sheet is rejected before any mutation (precondition path)" do
    app = make_app
    shape = app.shapes.first
    file = File.tempname(".xlsx")
    wb = Crexcel::Workbook.new(file); wb.add_worksheet("t").write_row(0, ["A", "B"]); wb.close # 1 row only

    tc = table_count(app.persistency, shape.context)
    depth = app.persistency.contexts.size
    app.import_document(shape, file, "HeaderOnly").should be_false
    table_count(app.persistency, shape.context).should eq(tc)   # nothing added (raised before add_table)
    app.persistency.contexts.size.should eq(depth)

    File.delete?(file)
  end
end
