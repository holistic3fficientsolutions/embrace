require "../src/global"
require "../src/table/raw"
require "../src/debug-helper"

# A FRAME EXCEPTION SWALLOWED fails the run. crymble-ui's TestRenderer catches an exception raised inside a frame
# (graceful degradation: reset caches, re-layout) and only counts it, so a spec passes unless its own assertions
# happen to notice the broken frame. This lists every example whose frames swallowed one - and any swallowed
# outside an example - and fails the run AFTER Spec's own summary: a hook cannot fail a single example (raising in
# one aborts the run), and exiting in `after_suite` would come before the summary and hide the real failures. An
# `at_exit` registered there runs next, because handlers run in reverse order and Spec's own is already running.
# Only where crymble-ui's TestRenderer is compiled in - the GUI group.
macro finished
  {% if @top_level.has_constant?("CrymbleUI") && @top_level.constant("CrymbleUI").has_constant?("Testing") &&
          @top_level.constant("CrymbleUI").constant("Testing").has_constant?("TestRenderer") %}
    # A layer painted into a layer nobody owns is a defect in every spec, not a counted fallback
    CrymbleUI::Layer.strict_nesting = true

    private module SwallowCheck
      class_getter offenders = [] of String
      class_property attributed = 0
    end
    Spec.around_each do |example|
      before = CrymbleUI::Testing::TestRenderer.frame_exceptions_swallowed
      begin
        example.run
      ensure # an example that fails is still recorded - and only recorded: raising here would abort the run
        swallowed = CrymbleUI::Testing::TestRenderer.frame_exceptions_swallowed - before
        if swallowed > 0
          SwallowCheck.attributed += swallowed
          at = "#{Path[example.example.file].relative_to(Dir.current)}:#{example.example.line}"
          last = CrymbleUI::Testing::TestRenderer.last_frame_exception_message.to_s.lines.first?
          SwallowCheck.offenders << "crystal spec #{at} # #{example.example.description}: #{swallowed} " \
                                    "(the last: #{last})"
        end
      end
    end
    Spec.after_suite do
      outside = CrymbleUI::Testing::TestRenderer.frame_exceptions_swallowed - SwallowCheck.attributed
      SwallowCheck.offenders << "#{outside} outside any example (a before_all, a file-level fixture)" if outside > 0
      next if SwallowCheck.offenders.empty?
      at_exit do
        STDERR.puts "\nFRAME EXCEPTIONS SWALLOWED:\n  #{SwallowCheck.offenders.join("\n  ")}"
        exit 1
      end
    end
  {% end %}
end
