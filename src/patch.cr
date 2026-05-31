# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "json"
require "./constants"

struct StaticArray(T, N)
    include JSON::Serializable
end

# see https://github.com/crystal-lang/crystal/pull/8893#issuecomment-2646330810
# make Hash more restrictive
class Hash(K, V)
    # def []?(key) # we are less restrictive for #[]?
    #     check_key(key)
    #     previous_def # directly from Hash
    # end
    def [](key)
        check_key(key)
        previous_def # directly from Hash
    end
    def has_key?(key) : Bool
        check_key(key)
        previous_def # directly from Hash
    end
    def includes?(obj) : Bool
        check_keyvalue(obj)
        super # indirectly from Enumerable
    end
    private def check_key(key : K)
    end
    private def check_keyvalue(keyvalue : {K,V})
    end
end

module Enumerable(T)
    def select_with_index(& : T, Int32 -> Bool) : Array(T) # adapted from https://github.com/crystal-lang/crystal/blob/a6fcb1029/src/enumerable.cr#L920
        ary = [] of T
        each_with_index {|e,i| ary << e if yield(e,i)}
        ary
    end
end

# 20240612: base from GPT4, but needed rework to compile
class Object
    def replace(other)
        {% for ivar in @type.instance_vars %}
            @{{ivar.id}} = other.@{{ivar.id}}
        {% end %}
    end
end

class Array(T)
    def self.mix(arrays)
        stride = arrays.size
        s = arrays.map(&.size).max
        res = typeof(arrays[0]).new
        s.times do |i|
            stride.times do |j|
                res << arrays[j][i] if arrays[j].size > i
            end
        end
        res
    end
    def <=>(other : Array(T)) # allow comparison of union typed Arrays by using mycmp
        {% if T.union? %}
            min_size = Math.min(size, other.size)
            0.upto(min_size - 1) do |i|
                n = mycmp(@buffer[i], other.to_unsafe[i])
                return n if n != 0
            end
            size <=> other.size
        {% else %}
            min_size = Math.min(size, other.size)
            0.upto(min_size - 1) do |i|
                n = @buffer[i] <=> other.to_unsafe[i]
                return n if n != 0
            end
            size <=> other.size
        {% end %}
    end
    # make a big string, columns with proper sizes and right justified
    # works on rectangular 2-dim arrays of Strings
    def to_s2
        sep = " | "
        res = self.transpose
        colwidths = res.map {|col| col.map {|el| el.to_s.size}.max }
        sep = "-" * (colwidths.sum + sep.size*(colwidths.size-1))
        res = res.map_with_index {|col,i| col.map {|el| el.to_s.rjust(colwidths[i])} }
        res = res.transpose
        sep+"\n" + res.map {|row| row.join(" | ")}.join("\n") + "\n"+sep
    end
    def disambiguate # for T=String
        a = map(&.sub(/__.*/,""))
        hist = Hash(String,Int32).new
        a.each do |el|
            hist[el] ||= 0
            hist[el] += 1
        end
        hist.select! {|_,v| v>1}
        a = a.reverse.map do |el|
            c = hist[el]?
            if c
                hist[el] -= 1
                "#{el}__#{c}"
            else
                el
            end
        end .reverse
    end
    def disambiguate! # for T=String
        a = disambiguate
        map_with_index! {|_,i| a[i]}
    end
end

# define default constructors (i.e. w/o arguments)
struct Int32
    def self.new : self
        self.new(0)
    end
end
struct Int64
    def self.new : self
        self.new(0)
    end
end

# statically build k-dim Array types, e.g.
# Array.maketype(Int32, 3) # -> Array(Array(Array(Int32)))
class Array(T)
    macro maketype(type, dim)
        {% for i in (1..dim) %}
            Array(
        {% end %}
            {{ type }}
        {% for i in (1..dim) %}
            )
        {% end %}
    end
end

struct Bool
    def self.new : self
        false
    end
    def <=>(other : Bool)
        if self == other
            0
        elsif self
            1
        else
            -1
        end
    end
end

struct Nil
    def self.new : self
        nil
    end
    def <=>(other : Nil)
        0
    end
end

# defines a total order, also for different types and union (compile time) types
def mycmp(x : T, y : U) : Int32 forall T, U
    res = nil
    {% for name in T.union_types %} # union_types also works if T isn't a union -> e.g. [Int32] array literal
        if !res && x.is_a?({{name}})
            if y.is_a?({{name}})
                res = x <=> y
            else
                res = (x.class.name <=> y.class.name)
            end
        end
    {% end %}
    assert(!(res.nil?))
    res
end

module Iterator(T)
    def last
        cur = old = first
        while !cur.is_a?(Iterator::Stop)
            old = cur
            cur = self.next
        end
        old
    end
end

ERROR_CODEFILE = "generated-errorcodes.txt" # only used for release builds
{% if flag?(:release) %}
    {% if flag?(:win32) %}
        {% system("cmd.exe /c echo file, line > #{ERROR_CODEFILE}") %}
    {% else %}
        {% system("echo code, file, line > #{ERROR_CODEFILE}") %}
    {% end%}
{% end %}
macro assert(invariant, f=__FILE__, l=__LINE__)
    {% if flag?(:release) %}
        # the only way to have "static" compile time variables:
        {% counter = read_file(ERROR_CODEFILE).lines.size %}
        {% if flag?(:win32) %}
            {% system("cmd.exe /c echo #{counter}, #{f}, #{l} >> #{ERROR_CODEFILE}") %}
        {% else %}
            {% system("echo #{counter}, #{f}, #{l} >> #{ERROR_CODEFILE}") %}
        {% end%}
        # see https://forum.crystal-lang.org/t/run-time-assertions-and-type-reductions/4694
        # needs to be a macro, method doesn't do compile time type reductions
        # compile time "if" is necessary...
        {% if invariant %}
            if {{invariant}} # see https://github.com/crystal-lang/crystal/issues/13209
            else
                raise("error code # {{counter}} @ build version #{Constant::BuildVersion}")
            end
        {% else %}
            raise("error code # {{counter}} @ build version #{Constant::BuildVersion}")
        {% end %}
    {% else %}
        {% if invariant %}
            if {{invariant}} # see https://github.com/crystal-lang/crystal/issues/13209
            else
                raise("runtime_assert @" + {{f}} + ":{{l}}")
            end
        {% else %}
            raise("runtime_assert @" + {{f}} + ":{{l}}")
        {% end %}
    {% end %}
end

# see https://forum.crystal-lang.org/t/generic-compile-time-assertions/4690
# use {% debug %} at end of macro for outputting substitution
macro static_assert(invariant)
    \{% raise("static_assert") if !{{invariant}} %}
end

# example:
# static_assert(T.union_types.includes?(Bool))

# e.g. pseudo_enum MyEnum, 0i64, 1, [A, B, C]
macro pseudo_enum(name, init, step, values)
    {% for v, i in values %}
        {{name}}::{{v}} = {{init}} + {{i}}*{{step}}
    {% end %}
end
# {% debug %}

class Hash(K,V)
    def sort(&block : {K,V},{K,V} -> Int32) # e.g. to be used `h=h.sort{...}`
        to_a.sort do |x,y|
            block.call(x, y)
        end.to_h
    end
end

struct Set(T)
    def sort(&block : T,T -> Int32) # e.g. to be used `s=s.sort{...}`
        to_a.sort do |x,y|
            block.call(x, y)
        end.to_set
    end
end


struct Slice(T)
    def self.from_hexstring(hex : String) : Bytes # counterpart to Slice(T)#hexstring
        raise ArgumentError.new("Hex string must have even length") unless hex.size.even?
        Bytes.new(hex.size // 2) do |i|
            hex_byte = hex[2 * i, 2]
            hex_byte.to_u8(16)
        end
    end
end
