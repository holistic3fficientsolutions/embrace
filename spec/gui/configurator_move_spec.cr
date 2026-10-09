require "spec"
require "../../spec/spec_helper"
require "../../src/gui/embrace"
require "../../src/constants"
require "./support/embrace_ui"

include Persistency

# Moving fields in the configurator, driven the way a user does it: drag a field's row onto another row.
# Onto a field of the same table the drop asks "Move or Merge"; onto a table reached through a reference it
# moves the field across that reference - outwards (to the referenced table) or inwards (back).

private DOC = <<-EOT
    Cities
    City | Country
    Rome | Italy
    Oslo | Norway

    People
    Name | Nick | Home_City
    Al | al | Rome
    Bo |  | Oslo
    EOT

private def open_people : {EmbraceUI, ShapeState, Fixtures::Lids}
  app, lids = Fixtures.app(DOC, open: "People")
  ui = EmbraceUI.new(app)
  {ui, ui.shape("People"), lids}
end

# Every table's fields in order, with their values in record order, read as the Shape sees them.
private def tables(ui : EmbraceUI, shape : ShapeState, lids) : Hash(String, Array({String, Array(String)}))
  p = ui.app.persistency
  p.with_context(shape.context) do
    %w(People Cities).to_h do |table|
      lid = lids[table].as(TableLID)
      records = p.get_record_lids(lid)
      fields = p.get_field_lids(lid).map do |f|
        {p.display_name(f), records.map { |r| p.get_value(f, r).to_s }}
      end
      {table, fields}
    end
  end
end

describe "configurator field moves" do
  it "moves a field within its table: dropped onto a sibling, 'Move field' puts it there" do
    ui, shape, lids = open_people
    tables(ui, shape, lids)["People"].map(&.[0]).should eq ["Name", "Nick", "Home"]
    ui.drag ui.configurator_drag(shape, "People", "Name"), onto: ui.configurator_drop(shape, "People", "Nick")
    ui.context_menu(:move_field)
    tables(ui, shape, lids)["People"].map(&.[0]).should eq ["Nick", "Name", "Home"]
  end

  it "merges a field into a sibling: 'Merge fields' fills its gaps and removes the dragged one" do
    app, lids = Fixtures.app("T\nA | B\nx | \n | y\n", open: "T")
    ui = EmbraceUI.new(app)
    shape = ui.shape("T")
    ui.drag ui.configurator_drag(shape, "T", "A"), onto: ui.configurator_drop(shape, "T", "B")
    ui.context_menu(:merge_fields)
    p = app.persistency
    t = lids["T"].as(TableLID)
    p.with_context(shape.context) do
      p.get_field_lids(t).map { |f| {p.display_name(f), p.get_record_lids(t).map { |r| p.get_value(f, r).to_s }} }
    end.should eq [{"B", ["x", "y"]}]
  end

  it "refuses a merge whose values conflict, says why, and changes nothing" do
    ui, shape, lids = open_people
    before = tables(ui, shape, lids)
    ui.drag ui.configurator_drag(shape, "People", "Name"), onto: ui.configurator_drop(shape, "People", "Nick")
    ui.expect_reported("Cannot merge, e.g. values 'Al' and 'al' are different") { ui.context_menu(:merge_fields) }
    ui.status.should contain "Cannot merge, e.g. values 'Al' and 'al' are different"
    tables(ui, shape, lids).should eq before
  end

  it "refuses to merge a reference field with a plain one" do
    ui, shape, lids = open_people
    before = tables(ui, shape, lids)
    ui.drag ui.configurator_drag(shape, "People", "Home"), onto: ui.configurator_drop(shape, "People", "Nick")
    ui.expect_reported("Cannot merge, fields have different types") { ui.context_menu(:merge_fields) }
    tables(ui, shape, lids).should eq before
  end

  it "moves a field outwards across a reference: each record's value lands on the record it refers to" do
    ui, shape, lids = open_people
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    ui.configurator_selected?(shape, "People", "Nick").should be_true # visible before the move
    ui.drag ui.configurator_drag(shape, "People", "Nick"), onto: ui.configurator_drop(shape, "People", "Home", "Cities")
    after = tables(ui, shape, lids)
    after["People"].map(&.[0]).should eq ["Name", "Home"]
    after["Cities"].should contain({"Nick", ["al", ""]}) # Al lives in Rome, Bo in Oslo
    ui.configurator_selected?(shape, "People", "Home", "Cities", "Nick").should be_true # and visible where it lands
  end

  it "does not reveal a moved field that was hidden" do
    ui, shape, lids = open_people
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    ui.select_field(shape, "People", "Nick") # hide it
    ui.configurator_selected?(shape, "People", "Nick").should be_false
    ui.drag ui.configurator_drag(shape, "People", "Nick"), onto: ui.configurator_drop(shape, "People", "Home", "Cities")
    ui.configurator_selected?(shape, "People", "Home", "Cities", "Nick").should be_false
  end

  it "moves a field inwards across a reference: each record takes the value of the record it refers to" do
    ui, shape, lids = open_people
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    ui.configurator_selected?(shape, "People", "Home", "Cities", "Country").should be_false
    ui.drag ui.configurator_drag(shape, "People", "Home", "Cities", "Country"), onto: ui.configurator_drop(shape, "People")
    after = tables(ui, shape, lids)
    after["People"].should contain({"Country", ["Italy", "Norway"]})
    after["Cities"].map(&.[0]).should eq ["City"] # every value was used, so the field left Cities
    ui.configurator_selected?(shape, "People", "Country").should be_false # hidden before, hidden after
  end

  it "reveals a field moved inwards that was visible" do
    ui, shape, lids = open_people
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    ui.select_field(shape, "People", "Home", "Cities", "Country")
    ui.configurator_selected?(shape, "People", "Home", "Cities", "Country").should be_true
    ui.drag ui.configurator_drag(shape, "People", "Home", "Cities", "Country"), onto: ui.configurator_drop(shape, "People")
    ui.configurator_selected?(shape, "People", "Country").should be_true
  end

  it "keeps a field moved inwards where some of its values are still unused, and says so" do
    app, lids = Fixtures.app(<<-EOT, open: "People")
        Cities
        City | Country
        Rome | Italy
        Oslo | Norway
        Lima | Peru

        People
        Name | Home_City
        Al | Rome
        Bo | Oslo
        EOT
    ui = EmbraceUI.new(app)
    shape = ui.shape("People")
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    ui.drag ui.configurator_drag(shape, "People", "Home", "Cities", "Country"), onto: ui.configurator_drop(shape, "People")
    after = tables(ui, shape, lids)
    after["People"].should contain({"Country", ["Italy", "Norway"]})
    after["Cities"].should contain({"Country", ["", "", "Peru"]}) # the moved values left; Lima's Peru, unreferenced, stays
    ui.status.should contain "Original field 'Country' has unused values - not deleting it"
  end

  it "moves a field backwards within its table: dropped onto an earlier sibling, it goes before it" do
    ui, shape, lids = open_people
    ui.drag ui.configurator_drag(shape, "People", "Home"), onto: ui.configurator_drop(shape, "People", "Name")
    ui.context_menu(:move_field)
    tables(ui, shape, lids)["People"].map(&.[0]).should eq ["Home", "Name", "Nick"]
  end

  it "refuses an outward move that would give a record two values, says why, and changes nothing" do
    app, lids = Fixtures.app(<<-EOT, open: "People")
        Cities
        City
        Rome

        People
        Name | Nick | Home_City
        Al | al | Rome
        Cy | cy | Rome
        EOT
    ui = EmbraceUI.new(app)
    shape = ui.shape("People")
    ui.expand(shape, "People", "Home")
    ui.expand(shape, "People", "Home", "Cities")
    p = app.persistency
    fields = -> { p.with_context(shape.context) { %w(People Cities).map { |t| p.get_field_lids(lids[t].as(TableLID)).map { |f| p.display_name(f) } } } }
    before = fields.call
    ui.expect_reported(/field 'Nick' cannot have several values at once, e.g. at 'Rome'/) do
      ui.drag ui.configurator_drag(shape, "People", "Nick"), onto: ui.configurator_drop(shape, "People", "Home", "Cities")
    end
    fields.call.should eq before
    # The refused drop ended the drag: the next one starts (it raised "a drag is in progress" before).
    ui.drag ui.configurator_drag(shape, "People", "Name"), onto: ui.configurator_drop(shape, "People", "Nick")
    ui.context_menu(:move_field)
    fields.call[0].should eq ["Nick", "Name", "Home"]
  end
end
