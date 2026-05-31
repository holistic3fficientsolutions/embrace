# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "weak_ref"

# WeakKeyMap is similar to Hash, with one big difference: if the GC sees no more links to a key (_except_ for in this container),
# it can automatically remove the key (and thus prevent a memory leak).
# In general WeakKeyMap should be used for data structures which live long, e.g. throughout the program execution lifetime.
# If the data structure is only alive locally in a method, also a normal Hash can be used.
class WeakKeyMap(K, V)
    private class Key(T)
        @hasher = Crystal::Hasher.new
        def initialize(k : T)
            @k = WeakRef(T).new(k) # using WeakRef(T) because subclassing doesn't work
        end
        def value
            @k.value
        end
        def ==(other : Key(T))
            value == other.value
        end
        def hash(hasher)
            if value = @k.value
                key_hasher = value.hash(Crystal::Hasher.new)
                @hasher = key_hasher
            else
                # this is crucial, since after GC is setting .value to nil, the hashes are different and deletion doesn't work anymore
                key_hasher = @hasher
            end
            key_hasher.hash(hasher)
        end
    end
    include Enumerable({Key(K), V})
    @hash = Hash(Key(K), V).new
    def initialize
        # since...
        # - GC has no hooks for cleaning
        # - Hash iterators are all private, so we cannot store the iterator state here
        # ... we have to use fibers
        # update 5.5.2024: the following lines are no option, since it blows up the number of fibers in a couple of minutes and crashes
        # spawn do
        #     while true
        #         @hash.each do |(key, value)|
        #             @hash.delete(key) if !key.value
        #             Fiber.yield
        #         end
        #         Fiber.yield
        #     end
        # end
    end
    # only the following three methods are sensibly defined
    def []=(key : K, value : V)
        @hash[Key.new(key)] = value
    end
    def []?(key : K) : V|Nil
        @hash[Key.new(key)]?
    end
    def [](key : K) : V
        self[key]?.as(V) # V may or may not include Nil
    end
    # the following methods don't make much sense for this lazily cleaning container class
    private def delete(key : K)
        @hash.delete(Key.new(key))
    end
    private def each
        @hash.each do |(key, value)|
            @hash.delete(key) if !key.value
            yield({key, value})
        end
    end
    # no #size, no #keys nor #values
end
