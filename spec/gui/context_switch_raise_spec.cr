require "./support/embrace_ui"

# An action the data refuses leaves the context stack as it found it. Associating fields under a classification field
# that is a reference is refused - after the dialog had switched to its Shape's context; the switch must be taken
# back on the refusal too, or every later read answers from that Shape's commit.

private WITH_REFERENCE = <<-EOT
    Cities
    City
    Graz
    Linz

    People
    Name | Home_City | Nick
    Al | Graz | al
    Bo | Linz | bo
    EOT

describe "an Associate the data refuses" do
    it "is reported, and leaves the context stack as it was" do
        ui = EmbraceUI.new(Fixtures.app(WITH_REFERENCE, open: "People")[0])
        shape = ui.shape("People")
        ui.right_click ui.configurator_table(shape, "People")
        ui.context_menu :associate_fields
        dialog = ui.app.@dialogs.compact_map(&.as?(Dialogs::DisAssociateFields)).first
        p = ui.app.persistency
        fields = p.get_field_lids(dialog.table_lid).to_h { |f| {p.display_name(f), f} }
        dialog.mux_field_lid = fields["Home"] # a reference: refused as the classification field
        dialog.value_field_lid = fields["Name"]
        dialog.field_selected = dialog.field_lids.map { |f| f == fields["Nick"] } # the field to associate
        ui.app.request_rebuild
        ui.ui.settle
        depth = p.contexts.size
        ui.expect_reported("Cannot associate, classification field cannot be reference field") do
            ui.click("#{dialog.id}_associate")
        end
        p.contexts.size.should eq(depth)
    end
end
