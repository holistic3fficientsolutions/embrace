require "./support/embrace_ui"

# Typing into an empty pivot intersection makes a record there with the value - the cell a user typed into, whichever
# of the aggregate columns it is. Reported: with two aggregates, a reference first, typing into the second dropped
# the value without a word (the new record's write landed on the reference column, was refused, and the refusal
# was swallowed). A write the data refuses says why.

private MAILS = <<-EOT
    staff
    Person
    Alice
    Bob
    Carol

    bosses
    Boss
    b1
    b2
    b3

    Mails
    receiver_Person | sender_Boss | public_Boss | feedback
    Alice | b1 | b1 |
    Bob | b2 | b2 |
    Carol | b3 | b3 |
    EOT

# The reported layout: every sender x every receiver (both referenced tables show all their records), Rank below
# them, the aggregates public (a reference) then feedback.
private def senders_by_receivers : {EmbraceUI, ShapeState}
    ui = EmbraceUI.tables(MAILS, open: "Mails")
    shape = ui.shape("Mails")
    {"receiver" => "staff", "sender" => "bosses"}.each do |field, table|
        ui.expand(shape, "Mails", field)
        ui.expand(shape, "Mails", field, table)
        ui.select_field(shape, "Mails", field, table, "(Show all records?)")
    end
    Fixtures.open_fieldlist(ui.app, ui.renderer)
    ui.drag ui.fieldlist_field(shape, "Mails", "sender"), onto: ui.rows_zone(shape)
    ui.drag ui.fieldlist_field(shape, "Mails", "receiver"), onto: ui.rows_zone(shape)
    ui.drag ui.fieldlist_field(shape, "Mails", "Rank"), onto: ui.new_rows_level(shape)
    ui.fieldlist_section(shape, "Mails", "public").should eq({:aggregates, 1})   # precondition
    ui.fieldlist_section(shape, "Mails", "feedback").should eq({:aggregates, 1}) # precondition
    {ui, shape}
end

describe "typing into an empty pivot intersection" do
    it "makes a record there with the value, in the column typed into - the second aggregate behind a reference" do
        ui, shape = senders_by_receivers
        ui.pivot_text(shape, ["b1", "Bob"], field: "feedback").should eq("") # precondition: no record there
        ui.type_into_pivot_cell(shape, ["b1", "Bob"], "feedback", "x")
        ui.pivot_text(shape, ["b1", "Bob", "4"], field: "feedback").should eq("x")
        ui.renderer.exceptions_caught.should eq 0
    end

    # Guard (green before): the first aggregate.
    it "makes a record there with the value, in the first aggregate" do
        ui, shape = senders_by_receivers
        ui.drag ui.fieldlist_field(shape, "Mails", "public"), onto: ui.unused_zone(shape)
        ui.type_into_pivot_cell(shape, ["b1", "Bob"], "feedback", "x")
        ui.pivot_text(shape, ["b1", "Bob", "4"], field: "feedback").should eq("x")
    end

    it "says why when the data refuses the value: text typed into a reference column" do
        ui, shape = senders_by_receivers
        ui.type_into_pivot_cell(shape, ["b1", "Bob"], "public", "x")
        ui.status.should contain("Can only assign Reference to Reference") # in the status bar, as other refusals are
        ui.pivot_text(shape, ["b1", "Bob"], field: "feedback").should eq("") # nothing made
    end
end
