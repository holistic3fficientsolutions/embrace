require "spec"

# A context switch survives a raise: no `contexts.push(` in src/ - Persistency#with_context, whose ensure pops, is the
# one switch. A bare push / pop pair leaves the stack one frame deeper when anything between them raises, and every
# later read then answers from the wrong commit. (Scope: the `contexts.push(` form; a bare pop that clears the stack,
# as EmbraceApp's start does, is no pair and is not looked at.) An exception, if one is ever needed, is named in
# ALLOWED by file and method, and must be hit exactly once.
private ROOT    = File.expand_path("..", __DIR__)
private ALLOWED = Set({String, String}).new

describe "context switches in src/" do
    it "go through Persistency#with_context" do
        files = Dir.glob(File.join(ROOT, "src/**/*.cr")).sort
        files.size.should be > 0 # a guard that finds nothing proves nothing
        offenders = [] of String
        allowed_hits = Hash({String, String}, Int32).new(0)
        files.each do |full|
            path = full.lchop(ROOT + "/")
            method = ""
            File.read_lines(full).each_with_index do |line, i|
                if m = line.match(/^\s*(?:private |protected )?def (\S+?)[\s(:]/) || line.match(/^\s*(?:private |protected )?def (\S+)$/)
                    method = m[1]
                end
                next unless line.includes?("contexts.push(") && !line.lstrip.starts_with?("#")
                if ALLOWED.includes?({path, method})
                    allowed_hits[{path, method}] += 1
                else
                    offenders << "#{path}:#{i + 1}: #{line.strip}"
                end
            end
        end
        offenders.should eq([] of String)
        ALLOWED.each { |site| allowed_hits[site].should eq(1) } # an exception that no longer exists goes too
    end
end
