require "spec"
require "../spec/spec_helper"
require "../src/global"
require "../src/constants"
require "../src/virtualtable"
require "../src/gui/tablefieldpicker"

include Persistency

describe GUI::Widget::TablePicker do
    it "add_table updates names and lid_index to show the new table" do
        p = Persistency::Default.new
        ctx = p.context.clone

        # Start with one existing table
        p.contexts.push(ctx)
        p.add_table("Existing")
        ctx = p.contexts.pop

        picker = GUI::Widget::TablePicker.new(p, ctx, allow_create: true, suppress_empty: true, prefill_table: true)

        # Before: should show "Existing"
        picker.names.should contain("Existing")
        old_count = picker.names.size

        # Add a new table via picker
        picker.add_table("Brand New")

        # After: picker should show "Brand New" in its names
        picker.names.should contain("Brand New")
        picker.names.size.should eq(old_count + 1)

        # The picker's selected table should be the new one
        picker.names[picker.lid_index].should eq("Brand New")
    end

    it "add_table selects the newly created table" do
        p = Persistency::Default.new
        ctx = p.context.clone

        # Start with one existing table
        p.contexts.push(ctx)
        p.add_table("Existing")
        ctx = p.contexts.pop

        picker = GUI::Widget::TablePicker.new(p, ctx, allow_create: true, suppress_empty: true, prefill_table: true)

        # Select existing table first
        picker.select_index(0)
        picker.names[picker.lid_index].should eq("Existing")

        # Add new table
        picker.add_table("Brand New")

        # Picker should now be on the new table, not the old one
        picker.names[picker.lid_index].should eq("Brand New")
        picker.lid.should_not be_nil
    end

    it "displays a blank-named table as (unnamed), never a raw empty string" do
        # T-071 keeps storage truthful (a never-named table stores ""); every display surface — the
        # "Table:" dropdown included — must read through display_name so the blank reads as the
        # "(unnamed)" placeholder, not "" (which the ComboBox shows as a bare "»").
        p = Persistency::Default.new
        ctx = p.context.clone
        p.contexts.push(ctx)
        p.add_table("") # un-named table, stored truthfully as ""
        ctx = p.contexts.pop

        picker = GUI::Widget::TablePicker.new(p, ctx, allow_create: true, suppress_empty: true, prefill_table: true)

        picker.names.should contain(Constant::Unnamed)
        picker.names.should_not contain("")
        picker.names[picker.lid_index].should eq(Constant::Unnamed) # the collapsed dropdown value too
    end
end
