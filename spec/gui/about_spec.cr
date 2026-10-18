require "./support/embrace_ui"

# About names what this build of Embrace is made of. In the desktop build that is CSFML, SFML and the
# font crymble-ui embeds - written out here as the visitor reads them, so the lines stay pinned
# whoever produces them (the web build names its own backend; crymble-ui answers per build).
describe "About" do
    it "lists CrymbleUI, then its desktop backend and font, then the shards" do
        ui = EmbraceUI.start
        ui.menu(:help_about)
        lines = ui.panel("about").find_all(&.is_a?(CrymbleUI::Text)).map(&.as(CrymbleUI::Text).text)
        using = lines[lines.index!("Using:") + 1..]
        backend = ["CSFML (version #{SF::VERSION}, Zlib license)", "SFML (version #{SF::SFML_VERSION}, Zlib license)"] +
                  CrymbleUI::EmbeddedFont::ATTRIBUTION
        using.first.should start_with("CrymbleUI (version")
        using[1, backend.size].should eq backend
        using[1 + backend.size].should start_with("crexcel (version")
    end
end
