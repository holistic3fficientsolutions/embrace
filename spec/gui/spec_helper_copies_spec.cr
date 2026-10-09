require "spec"
require "file_utils"
require "compiler/crystal/syntax"

# NO HELPER BODY IN TWO SPEC FILES. A helper copied into a second spec is two definitions of one thing that
# drift apart; its one owner is spec/gui/support/: Fixtures - no Driver: building state, and real-input
# clicks (Fixtures.click); EmbraceUI - Driver acts. See doc/modules/07-app.md "Writing a use-case spec".
#
# Compares each def's body as Crystal's own parser prints it: comments and layout drop out, names and every
# literal stay - so two helpers that build different DATA with the same plumbing are not copies (move the
# plumbing to support/ and keep the data in the spec), and an exact copy is.
#
# Limits - what this cannot see:
# - a copy with a renamed local or a reworded message (a near copy);
# - bodies under MIN_LINES lines as printed (one-liners are not helpers worth a support entry);
# - defs inside a `{% for %}` block (templates, e.g. EmbraceUI's zone methods); `{% if %}` branches ARE parsed:
#   their tag lines are dropped first, so a flag block's defs count. An `{% if %}` nested inside a `{% for %}`
#   would be dropped while the for stays, and that file would fail to parse (none does; the error names it).

private MIN_LINES = 3

private class DefCollector < Crystal::Visitor
    getter defs = [] of Crystal::Def

    def visit(node : Crystal::Def) : Bool
        @defs << node
        false
    end

    def visit(node : Crystal::ASTNode) : Bool
        true
    end
end

private record Site, file : String, name : String

# The source with its `{% if/unless/elsif/else %}` tag lines and the `{% end %}` closing them removed, so both
# branches parse as code; a `{% for %}` and its end stay (its body is a template, not code).
private def parseable(source : String) : String
    open = [] of Symbol
    source.lines.map do |line|
        case line.strip
        when /\A\{%-?\s*(if|unless)\b(?:(?!%\}).)*%\}\z/   then open << :if; ""  # a tag alone on its line
        when /\A\{%-?\s*for\b(?:(?!%\}).)*%\}\z/           then open << :for; line
        when /\A\{%-?\s*(elsif\b(?:(?!%\}).)*|else\s*-?)%\}\z/ then ""
        when /\A\{%-?\s*end\s*-?%\}\z/                then open.pop? == :for ? line : ""
        else                                               line
        end
    end.join('\n')
end

# {files read, defs seen, groups of sites sharing one body across two or more files}.
private def copies(dir : String) : {Int32, Int32, Array(Array(Site))}
    files = Dir.glob(File.join(dir, "**", "*.cr")).sort
    by_body = Hash(String, Array(Site)).new { |h, k| h[k] = [] of Site }
    defs = 0
    files.each do |path|
        collector = DefCollector.new
        begin
            Crystal::Parser.parse(parseable(File.read(path))).accept(collector)
        rescue ex : Crystal::SyntaxException
            raise "#{path}: #{ex.message}"
        end
        collector.defs.each do |d|
            defs += 1
            body = d.body.to_s
            by_body[body] << Site.new(Path[path].relative_to(dir).to_s, d.name) if body.lines.size >= MIN_LINES
        end
    end
    {files.size, defs, by_body.values.select { |sites| sites.map(&.file).uniq.size > 1 }}
end

private def report(groups : Array(Array(Site))) : String
    groups.map { |sites| sites.map { |s| "#{s.file}:#{s.name}" }.join(" = ") }.join("\n")
end

# A throwaway tree of spec files, for the check's own cases.
private def with_tree(files : Hash(String, String), &)
    dir = File.tempname("helper_copies")
    Dir.mkdir_p(dir)
    files.each { |name, text| File.write(File.join(dir, name), text) }
    yield dir
ensure
    FileUtils.rm_rf(dir) if dir
end

private HELPER = <<-CR
    private def build(n)
        a = n + 1
        b = a * 2
        b - 3
    end
    CR

describe "spec/gui helper copies" do
    it "defines no helper body in two spec files" do
        files, defs, groups = copies(__DIR__)
        files.should be >= 50 # read the real tree, not an empty glob
        defs.should be >= 197 # 90% of the 219 counted when this landed (59 files, 2026-09-25)
        fail "the same helper body in two spec files - move the plumbing to spec/gui/support/ (Fixtures - no Driver: building state, and real-input clicks (Fixtures.click); EmbraceUI - Driver acts) " \
             "and keep only the data here:\n#{report(groups)}" unless groups.empty?
    end

    it "finds an exact copy in two files" do
        with_tree({"a_spec.cr" => HELPER, "b_spec.cr" => HELPER.gsub("build", "make")}) do |dir|
            _, _, groups = copies(dir)
            report(groups).should eq("a_spec.cr:build = b_spec.cr:make")
        end
    end

    it "does not call helpers that differ only in their data copies" do
        with_tree({"a_spec.cr" => HELPER.gsub("n + 1", %("x" + "1")),
                   "b_spec.cr" => HELPER.gsub("n + 1", %("x" + "2"))}) do |dir|
            _, defs, groups = copies(dir)
            defs.should eq(2)
            groups.should be_empty
        end
    end

    it "parses both branches of a flag block, and leaves a {% for %} template alone" do
        flagged = "{%- if flag?(:x) -%}\n#{HELPER}\n{%- else -%}\nputs 1\n{%- end -%}\n" # trim tags too
        template = "{% for s in %w(a b) %}\n  {% if flag?(:y) %}puts 2{% end %}\n" \
                   "  def {{s.id}}_zone\n    1\n  end\n{% end %}\n" # a one-line if inside the template
        with_tree({"a_spec.cr" => flagged, "b_spec.cr" => HELPER, "c_spec.cr" => template}) do |dir|
            _, defs, groups = copies(dir)
            defs.should eq(2) # the flagged copy and b's; the template's def is not code
            report(groups).should eq("a_spec.cr:build = b_spec.cr:build")
        end
    end
end
