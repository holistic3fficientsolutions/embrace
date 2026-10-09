require "spec"
require "../src/tsv"

# TSV codec for clipboard interchange.
#
# Quoting rule: a field is quoted iff it contains TAB, LF, CR or a double quote;
# an inner quote is escaped by doubling. That is what a spreadsheet emits and
# accepts, so a quoted payload survives a trip through Calc unchanged.
#
# The decoder is a SINGLE character pass with an in_quotes flag. It cannot
# pre-split on newlines and then on tabs, because a quoted field may contain
# either — which is exactly the case that silently corrupts a copied cell.
describe TSV do
    describe ".encode" do
        it "joins fields with TAB and rows with LF, and does not terminate the last row" do
            TSV.encode([["a", "b"], ["c", "d"]]).should eq("a\tb\nc\td")
        end

        it "leaves a field with no special characters unquoted" do
            TSV.encode([["plain", "42"]]).should eq("plain\t42")
        end

        it "quotes a field containing a TAB — otherwise it would become two fields" do
            TSV.encode([["a\tb"]]).should eq(%("a\tb"))
        end

        it "quotes a field containing a newline — otherwise it would become two rows" do
            TSV.encode([["a\nb"]]).should eq(%("a\nb"))
        end

        it "quotes a field containing a CR" do
            TSV.encode([["a\rb"]]).should eq(%("a\rb"))
        end

        it "quotes a field containing a quote, and doubles the inner quote" do
            TSV.encode([[%(say "hi")]]).should eq(%("say ""hi"""))
        end
    end

    describe ".decode" do
        it "splits on TAB and LF" do
            TSV.decode("a\tb\nc\td").should eq([["a", "b"], ["c", "d"]])
        end

        it "returns no rows at all for empty input" do
            # Empty text is the ONLY input that yields no rows; every other path
            # appends at least one. That is what lets the paste path get away with a
            # single emptiness check on the text itself.
            TSV.decode("").should eq([] of Array(String))
        end

        it "swallows a TRAILING row break — no phantom final row" do
            # A spreadsheet ends its copy with a line break; a naive split would
            # yield a spurious empty record.
            TSV.decode("a\nb\n").should eq([["a"], ["b"]])
        end

        it "keeps a blank line MID-payload as a real row of one empty field" do
            # Decides whether the statusbar says 2 records or 3.
            TSV.decode("a\n\nb").should eq([["a"], [""], ["b"]])
        end

        it "treats CRLF as ONE row break" do
            TSV.decode("a\r\nb").should eq([["a"], ["b"]])
        end

        it "treats a LONE CR outside quotes as a row break (Excel-for-Mac payloads)" do
            TSV.decode("a\rb").should eq([["a"], ["b"]])
        end

        it "preserves a TAB inside a quoted field" do
            TSV.decode(%("a\tb")).should eq([["a\tb"]])
        end

        it "preserves a NEWLINE inside a quoted field" do
            TSV.decode(%("a\nb")).should eq([["a\nb"]])
        end

        it "preserves a CRLF inside a quoted field, while CRLF outside still breaks the row" do
            TSV.decode(%("a\r\nb"\tx\r\ny)).should eq([["a\r\nb", "x"], ["y"]])
        end

        it "unescapes a doubled inner quote" do
            TSV.decode(%("say ""hi""")).should eq([[%(say "hi")]])
        end

        it "treats a bare quote inside an UNQUOTED field as a literal" do
            # We never emit this; a foreign payload does (5" pipe).
            TSV.decode(%(5" pipe)).should eq([[%(5" pipe)]])
        end

        it "appends characters that follow a closing quote to the same field" do
            # Lenient: foreign payloads produce this, we never emit it.
            TSV.decode(%("a"b)).should eq([["ab"]])
        end

        it "closes an unterminated quote at EOF rather than looping" do
            TSV.decode(%("abc)).should eq([["abc"]])
        end

        it "keeps ragged rows ragged — padding is the caller's policy, not the codec's" do
            TSV.decode("a\tb\tc\nd").should eq([["a", "b", "c"], ["d"]])
        end
    end

    # One spreadsheet cell on the clipboard, as the value it stands for. Mutation: drop the round trip
    # (take the decoded field) - the tolerant decoder's readings of foreign text come back as values.
    describe ".single_field" do
        it "reads one cell encoded as the encoder writes it, a trailing line break allowed" do
            TSV.single_field(%("a\nb")).should eq("a\nb")
            TSV.single_field(%("a\nb"\n)).should eq("a\nb")
            TSV.single_field(%("a\nb"\r\n)).should eq("a\nb")
            TSV.single_field(%("say ""hi""")).should eq(%(say "hi"))
            TSV.single_field("plain").should eq("plain")
            TSV.single_field("\n").should eq("") # an empty cell, terminated
        end

        it "reads nothing from text the encoder would not write for one cell" do
            TSV.single_field("").should be_nil        # no cell at all
            TSV.single_field(%("")).should be_nil      # encode writes an empty value unquoted
            TSV.single_field("a\tb").should be_nil     # two cells
            TSV.single_field("a\nb").should be_nil     # two rows
            TSV.single_field(%("Hi" she said)).should be_nil
            TSV.single_field(%("hello")).should be_nil # quotes encode would not add
            TSV.single_field(%(5" pipe)).should be_nil
        end
    end

    describe "round trip" do
        it "survives a payload holding every special character at once" do
            rows = [[%(tab\there), %(nl\nhere), %(quote"here), "plain"], ["", "x", "y", "z"]]
            TSV.decode(TSV.encode(rows)).should eq(rows)
        end
    end
end
