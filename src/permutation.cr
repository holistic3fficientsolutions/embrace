# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

class Permutation
    @index_normal = 0
    # @perm[0] is like Hash "newplace => oldplace"
    # @perm[1] is like Hash "oldplace => newplace"
    # they are always complimentary
    def initialize(size : Int32)
        @perm = {Array(Int32).new(size, 0), Array(Int32).new(size, 0)}
        identity!
    end
    def initialize(is_new2old : Bool, order : Array(Int32))
        order_reversed = Array(Int32).new(order.size, 0)
        order.each_with_index {|el,i| order_reversed[el] = i}
        @perm = {order, order_reversed}
        @index_normal = (is_new2old ? 0 : 1)
    end
    def size : Int32
        @perm[0].size
    end
    def identity! : Nil
        size.times do |i|
            @perm[0][i] = i
            @perm[1][i] = i
        end
    end
    def random! : Nil
        (1...size).reverse_each do |i|
            swap(i, Random.rand(i))
        end
    end
    def invert! : Nil
        @index_normal ^= 1
    end
    def swap(i : Int32, j : Int32) : Nil
        @perm[@index_normal].swap(i, j)
        @perm[@index_normal^1].swap(next_swap(i), next_swap(j))
    end
    def apply_with_swap(&) : self
        i = j = k = 0
        visited = Array(Bool).new(size, false)
        (0...size).reverse_each do |i|
            j = i
            visited[j] = true
            k = next_swap(j)
            while !visited[k]
                visited[k] = true
                yield(j, k) if j!=k # the user defined swap
                j = k
                k = next_swap(j)
            end
        end
        self
    end
    def apply_with_move(&) : self # attention: user logic needs to implement "move_before" semantics!
        apply_with_swap do |i,j|
            if i != j
                i, j = {i,j}.minmax
                yield(i, j) # mve forward...
                yield(j, i) # ... and backward move
                # BTW: "move_before" is complete for our use case, even if it cannot move to the end...
                # ... since "swap" always comes with a second move, which moves the end forward
                # (thus effectivly allowing the first move to move to the end)
            end
        end
        self
    end
    private def next_swap(i : Int32) : Int32
        @perm[@index_normal][i]
    end
end
