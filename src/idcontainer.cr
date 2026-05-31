# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

class IDContainer(T)
    @hash = Hash(T,{Int32,Int32}).new # T=>{ID,generation}
    @generation = 0
    @next_id = 0
    def initialize
    end
    protected def initialize(other : self)
        @hash = other.@hash.clone
        @generation = other.@generation
        @next_id = other.@next_id
    end
    def age : Nil
        @hash.reject! {|k,v| v[1] < @generation}
        @generation += 1
    end
    def get_id(key : T) : Int32
        if value = @hash[key]?
            value = {value[0], @generation}
        else
            value = {@next_id, @generation}
            @next_id += 1
        end
        @hash[key] = value
        value[0]
    end
    def clone
        IDContainer(T).new(self)
    end
end
