# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# TSV codec for clipboard interchange.
#
# Tab-separated rather than comma-separated because that is what spreadsheets put
# on the clipboard: pasting TSV into Calc or Excel lands in cells directly, with
# no separator dialog and no locale ambiguity (a German locale uses `;` for CSV
# and `,` as the decimal mark — tab has neither problem).
#
# Quoting follows the same convention those applications emit and accept: a field
# is quoted iff it contains TAB, LF, CR or a double quote, and an inner quote is
# doubled. Without it, a cell value holding a tab silently becomes two fields and
# one holding a newline becomes two rows — and free-text cells hold both.
#
# The codec is policy-free: it does not pad ragged rows and does not interpret
# values. Padding and type conversion belong to the caller, because the two
# importers legitimately disagree about what a blank means.
#
# Hand-rolled rather than Crystal's stdlib CSV with `separator: '\t'`, because a
# clipboard payload is foreign input and must never raise: the stdlib parser
# rejects a bare quote mid-field (`5" pipe`) with MalformedCSVError, and does not
# treat a lone CR as a row break, which Excel-for-Mac payloads rely on. Both are
# tolerated here deliberately, and both are pinned in the specs.
module TSV
    extend self

    # Characters that would otherwise be read as structure, plus the quote itself.
    private def needs_quoting?(field : String) : Bool
        field.each_char.any? { |ch| ch == '\t' || ch == '\n' || ch == '\r' || ch == '"' }
    end

    # Rows are joined with LF and the LAST row is NOT terminated. Both matter: the
    # decoder swallows a trailing break, so a round trip cannot detect either choice
    # — only a hand-written expectation or a real spreadsheet can.
    def encode(rows : Array(Array(String))) : String
        String.build do |io|
            rows.each_with_index do |row, row_index|
                io << '\n' if row_index > 0
                row.each_with_index do |field, field_index|
                    io << '\t' if field_index > 0
                    if needs_quoting?(field)
                        io << '"'
                        field.each_char do |ch|
                            io << '"' if ch == '"' # doubled, so the decoder can tell it apart from a terminator
                            io << ch
                        end
                        io << '"'
                    else
                        io << field
                    end
                end
            end
        end
    end

    # ONE character pass. It cannot pre-split on newlines and then on tabs: a quoted
    # field may contain either, which is precisely the payload that would otherwise
    # be torn into extra rows or fields.
    def decode(text : String) : Array(Array(String))
        rows = [] of Array(String)
        return rows if text.empty?

        row = [] of String
        field = String::Builder.new
        in_quotes = false
        at_field_start = true # a quote OPENS a field only here; elsewhere it is a literal

        reader = Char::Reader.new(text)
        while reader.has_next?
            ch = reader.current_char

            if in_quotes
                if ch == '"'
                    if reader.peek_next_char == '"'
                        field << '"'      # an escaped quote
                        reader.next_char  # consume the second one
                    else
                        in_quotes = false # closing quote; anything after it appends to this field
                    end
                else
                    field << ch # TAB / LF / CR survive verbatim in here — the whole point of quoting
                end
            else
                case ch
                when '"'
                    if at_field_start
                        in_quotes = true
                    else
                        field << ch # a bare quote mid-field is a literal (5" pipe) — we never emit it, foreign payloads do
                    end
                when '\t'
                    row << field.to_s
                    field = String::Builder.new
                    at_field_start = true
                when '\n', '\r'
                    row << field.to_s
                    field = String::Builder.new
                    rows << row
                    row = [] of String
                    at_field_start = true
                    reader.next_char if ch == '\r' && reader.peek_next_char == '\n' # CRLF is ONE break
                else
                    field << ch
                end
            end

            at_field_start = false unless at_field_start && (ch == '\t' || ch == '\n' || ch == '\r')
            reader.next_char
        end

        # The trailing field always closes a row — including an unterminated quote,
        # which simply ends at EOF rather than looping.
        row << field.to_s
        rows << row

        # A trailing row break produced an empty final row; swallow exactly that one.
        # A blank line MID-payload is a real row and must survive.
        rows.pop if rows.size > 1 && rows.last.size == 1 && rows.last.first.empty?
        rows
    end
end
