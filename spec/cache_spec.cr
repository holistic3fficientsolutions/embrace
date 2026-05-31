require "spec"
require "../src/cache"

describe Cache do
    it "works" do
        cache = Cache(String, Int32).new(10_u64) do |key|
            key.to_i*2
        end
        cache.fetch("21").should eq(42)
    end
end
