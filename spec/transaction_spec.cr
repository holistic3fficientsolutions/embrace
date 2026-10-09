require "spec"
require "./spec_helper"
require "../src/persistency"
require "../src/debug-helper"

include Persistency

# A transaction that raises leaves the data and the active context's commit position as they were - and moves every
# version counter FORWARD: a cache that refreshed inside the failed transaction must never see the same number again
# for different contents.

private def document : {Persistency::Default, FieldLID, RecordLID}
    p = Persistency::Default.new
    t = p.add_table("T")
    f = p.add_field(t, "A")
    r = p.add_record(t)
    p.set_value(f, r, "one")
    {p, f, r}
end

private def refuse(p : Persistency::Default, &) : Nil
    p.transaction do
        yield
        raise ConditionsNotMet.new("refused")
    end
rescue ConditionsNotMet
end

describe "Persistency#transaction, on a raise" do
    it "rolls the data back and moves the version past every version seen inside" do
        p, f, r = document
        seen = [] of Int32
        refuse(p) do
            p.set_value(f, r, "two"); seen << p.version
            p.set_value(f, r, "three"); seen << p.version
        end
        p.get_value(f, r).should eq("one")
        p.version.should be > seen.max # not back to before, and not onto a number seen inside
    end

    it "moves meta_version past every value seen inside" do
        p, _, _ = document
        t = p.get_table(MetaFieldLIDs::TableLastTable).first[0].as(TableLID)
        seen = [] of Int32
        refuse(p) do
            p.add_field(t, "B"); seen << p.meta_version
            p.add_field(t, "C"); seen << p.meta_version
        end
        p.get_field_lids(t).size.should eq(1)
        p.meta_version.should be > seen.max
    end

    it "keeps a nested inner rollback's versions moving forward under an outer success" do
        p, f, r = document
        inner = 0
        p.transaction do
            refuse(p) { p.set_value(f, r, "inner"); inner = p.version }
            p.set_value(f, r, "outer")
        end
        p.get_value(f, r).should eq("outer")
        p.version.should be > inner
    end

    it "restores the active context's commit position - and raises the context's version" do
        p, f, r = document
        ctx = p.context
        old = ctx.current_commit
        p.close_and_add_commit # `old` is closed now: a write positioned there opens a commit
        ahead = ctx.current_commit
        ctx.current_commit = old
        ctx.metadata_commit = ahead # the meta position differs, as a diff Shape's
        before = {ctx.root_commit, ctx.current_commit, ctx.metadata_root_commit, ctx.metadata_commit}
        seen = 0
        refuse(p) { p.set_value(f, r, "x"); seen = ctx.version } # opens a commit from `old`, then is refused
        {ctx.root_commit, ctx.current_commit, ctx.metadata_root_commit, ctx.metadata_commit}.should eq(before)
        ctx.version.should be > seen # forward past the version seen inside, never back
        p.set_value(f, r, "y") # control: the write that was refused does open a commit
        ctx.current_commit.should_not eq(old)
    end
end
