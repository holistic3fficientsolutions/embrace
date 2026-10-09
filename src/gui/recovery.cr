# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# An error that ends embrace keeps the user's unsaved work: the main loop runs inside Recovery.guarded, which, on any
# exception, has the app write a recovery copy (EmbraceApp#write_recovery_copy) and lets the SAME exception out - the
# crash report and the exit status stay what they were. Stateless: nothing is read back at the next start; the user
# opens the copy with File > Load. Not covered: a crash that raises no exception (a native fault, a kill).
module Recovery
    # Where the copies go; nil where the platform names no place (Windows without LOCALAPPDATA).
    class_property dir : String? = default_dir
    # Where the outcome is said - the app's window may be what failed, so not there.
    class_property report : IO = STDERR

    # What a nil `dir` means, said where the platform rule is.
    NO_DIR = {% if flag?(:win32) %} "no recovery folder: LOCALAPPDATA is not set" {% else %} "no recovery folder" {% end %}

    def self.default_dir : String?
        {% if flag?(:win32) %}
            ENV["LOCALAPPDATA"]?.try { |base| File.join(base, "embrace", "recovery") }
        {% else %}
            base = ENV["XDG_DATA_HOME"]?
            base = File.join(Path.home.to_s, ".local", "share") unless base && Path[base].absolute? # the XDG rule
            File.join(base, "embrace", "recovery")
        {% end %}
    end

    # Says `message` on `report`, or nowhere: a failing report (stderr closed, a broken pipe) has nowhere left to go,
    # and the crash must stay the crash.
    def self.say(message : String) : Nil
        report.puts message
    rescue
    end

    def self.guarded(app : EmbraceApp, &)
        yield
    rescue ex
        app.write_recovery_copy
        raise ex # the same object: its backtrace is kept, not re-taken here
    end
end
