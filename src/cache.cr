# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

class Cache(K, V)
    @store = {} of K => Tuple(UInt64, V) # (deadline, value)
    @age = 0_u64
    @default_ttl : UInt64
    @compute : K -> V
    def initialize(@default_ttl : UInt64, &@compute : K -> V)
        @store.compare_by_identity
    end
    def clear : Nil
        @store.clear
    end
    def age! : UInt64
        @age += 1
        @store.reject! { |_, (deadline, _)| @age >= deadline } # cleanup expired entries
        @age
    end
    def fetch(key : K, ttl : UInt64 = @default_ttl) : V
        if cached = @store[key]?
            _, value = cached
            @store[key] = {@age + ttl, value} # refresh deadline
            return value
        end
        value = @compute.call(key)
        @store[key] = {@age + ttl, value} # store deadline instead of timestamp
        value
    end
end
