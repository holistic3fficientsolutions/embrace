require "spec"
require "../src/permutation"

private def move(arr, i, j) # the move the tests below replay - file-private, not a method on every Array
    if i != j
        el = arr[i]
        arr.insert(j, el)
        i += 1 if i > j # if backward move
        arr.delete_at(i)
    end
end

describe Permutation do
    it "simple forward and backward with swap" do
        p = Permutation.new(5)
        p.swap(0, 2)
        p.swap(1, 3)
        p.swap(0, 4)
        p.size.should eq(5)
        arr = %w(one two three four five)
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(five four one two three))
        p.invert!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(one two three four five))
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(three four five two one))
        p.invert!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(one two three four five))
    end
    it "simple forward and backward with move" do
        p = Permutation.new(5)
        p.swap(0, 2)
        p.swap(1, 3)
        p.swap(0, 4)
        p.size.should eq(5)
        arr = %w(one two three four five)
        p.apply_with_move {|x,y| move(arr, x, y)}
        arr.should eq(%w(five four one two three))
        p.invert!
        p.apply_with_move {|x,y| move(arr, x, y)}
        arr.should eq(%w(one two three four five))
        p.apply_with_move {|x,y| move(arr, x, y)}
        arr.should eq(%w(three four five two one))
        p.invert!
        p.apply_with_move {|x,y| move(arr, x, y)}
        arr.should eq(%w(one two three four five))
    end
    it "initialization with old2new list" do
        p = Permutation.new(false, [2, 3, 4, 1, 0])
        p.size.should eq(5)
        arr = %w(one two three four five)
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(five four one two three))
        p.invert!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(one two three four five))
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(three four five two one))
        p.invert!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(one two three four five))
    end
    it "initialization with new2old list" do
        p = Permutation.new(true, [4, 3, 0, 1, 2])
        p.size.should eq(5)
        arr = %w(one two three four five)
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(five four one two three))
        p.invert!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(one two three four five))
    end
    it "identity" do
        p = Permutation.new(false, [2, 3, 4, 1, 0])
        p.size.should eq(5)
        arr = %w(one two three four five)
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(five four one two three))
        p.identity!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(five four one two three))
        p.invert!
        arr.should eq(%w(five four one two three))
    end
    it "random" do
        p = Permutation.new(5)
        p.size.should eq(5)
        arr = %w(one two three four five)
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(one two three four five))
        p.random!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        # we cannot check
        p.invert!
        p.apply_with_swap {|x,y| arr.swap(x, y)}
        arr.should eq(%w(one two three four five))
    end
end
