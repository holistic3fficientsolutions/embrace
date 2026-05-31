# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# both sets need to have a 1:1 mapping, i.e. all keys _and_ all values need to be unique
class BidirHash(K, V)
    getter :fwd, :bwd
    def initialize
        @fwd = Hash(K,V).new
        @bwd = Hash(V,K).new
    end
    def initialize(hash : Hash(K,V))
        @fwd = Hash(K,V).new
        @bwd = Hash(V,K).new
        hash.each do |k,v|
            self[k] = v
        end
    end
    def size : Int32
        @fwd.size
    end
    def [](k : K) : V # the forward direction
        @fwd[k]
    end
    def []?(k : K) : V|Nil
        @fwd[k]?
    end
    def []=(k : K, v : V)
        @fwd[k] = v
        @bwd[v] = k
        assert(@fwd.size == @bwd.size)
        v
    end
    def has_key?(k : K) : Bool
        @fwd.has_key?(k)
    end
    def has_value?(v : V) : Bool
        @bwd.has_key?(v)
    end
    def delete(k : K) : V|Nil
        if has_key?(k)
            v = @fwd.delete(k).not_nil!
            @bwd.delete(v)
        else
            nil
        end
    end
    def bwd(v : V) : K
        @bwd[v]
    end
    def bwd?(v : V) : K|Nil
        @bwd[v]?
    end
    def clear : Nil
        @fwd.clear
        @bwd.clear
    end
end
