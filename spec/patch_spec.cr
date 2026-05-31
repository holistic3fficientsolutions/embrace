require "spec"
require "../src/patch"

describe Array do
    it "works" do
        a = %w(eins zwei drei)
        a.disambiguate!
        a.should eq %w(eins zwei drei)
        a = %w(eins zwei eins)
        a.disambiguate!
        a.should eq %w(eins__1 zwei eins__2)
        a = %w(eins__12 zwei eins)
        a.disambiguate!
        a.should eq %w(eins__1 zwei eins__2)
    end
end

describe Object do
    it "works" do
        a = ["foo", "bar", 42, 43]
        mycmp(a[0], a[1]).should eq(1) # "foo" > "bar"
        mycmp(a[2], a[3]).should eq(-1) # 42 < 43
        mycmp(a[0], a[2]).should eq(1) # "String" > "Int32"
        mycmp("foo", 42).should eq(1) # "String" > "Int32"
        [43, 42, "one", "two", "three", nil, false].sort {|x,y| mycmp(x,y)}.should eq([false, 42, 43, nil, "one", "three", "two"])
        # p a[0] <=> a[1] # doesn't compile
    end
end

describe Bool do
    it "works" do
        (false<=>false).should eq(0<=>0)
        (false<=>true).should eq(0<=>1)
        (true<=>false).should eq(1<=>0)
        (true<=>true).should eq(1<=>1)
    end
end

describe Nil do
    it "works" do
        (nil<=>nil).should eq(0)
    end
end

pseudo_enum MyEnum, -1i64, -1, [A, B, C]
describe Nil do
    it "works" do
        MyEnum::A.should eq (-1i64)
        MyEnum::B.should eq (-2i64)
        MyEnum::C.should eq (-3i64)
    end
end

class TestRef
    def initialize(@rank : Int32)
    end
    def <=>(other : TestRef)
        mycmp(rank, other.rank)
    end
    property rank : Int32? # gets read (a) from widget or (b) when somebody calls VT#[]=
end
describe TestRef do
    it "works" do
        a = [TestRef.new(2), TestRef.new(1), TestRef.new(3)]
        a.sort {|x,y| mycmp(x,y)}.map(&.rank).should eq([1,2,3]) # sorted by #rank
    end
end

describe Hash do
    it "works" do
        h = {1=>"eins",2=>"zwei",3=>"drei"}
        h.sort {|x,y| y[1]<=>x[1]}.should eq({2=>"zwei",1=>"eins",3=>"drei"})
    end
end

describe Set do
    it "works" do
        s = Set{8,5,3,4,1}
        s.sort {|x,y| y<=>x}.should eq(Set{8,5,4,3,1})
    end
end
