const std = @import("std");
const assert = std.debug.assert;

pub fn BTreeType(comptime TableType: type) type {
    // same style as the `TableMemoryType`
    const Key = TableType.Key;
    const Value = TableType.Value;
    const key_from_value = TableType.key_from_value;
    // size based calculation
    const leaf_size = 32768;
    //const inner_size = 16384;
    const inner_size = 8192;
    //const inner_size = 4096;
    const PtrType = u32;
    const order = leaf_size / @sizeOf(Value);
    const inner_order = inner_size / (@sizeOf(Key) + @sizeOf(PtrType));
    const hint_size = 128; // 8 CL
    const hint_count = hint_size / @sizeOf(Key);

    return struct {
        const Self = @This();
        pub const LowerBoundResult = union(enum) {
            exact_match: PtrType,
            greater: PtrType,
        };

        const Inner = struct {
            //const hint_count = 16;
            count: u16 = 0,
            // padding
            padding: [62]u8 = [_]u8{0} ** 62,
            hints: [hint_count]Key,
            keys: [inner_order]Key,
            children: [inner_order]PtrType, // make this u32 ~ 17TB
            //
            fn init() Inner {
                return .{
                    .count = 0,
                    .hints = undefined,
                    .keys = undefined,
                    .children = undefined,
                };
            }

            fn make_hint(self: *Inner) void {
                const dist = self.count / (hint_count + 1);
                for (0..hint_count) |i| {
                    self.hints[i] = self.keys[dist * (i + 1)];
                }
            }

            fn search_hints(self: *const Inner, key: Key) struct { usize, usize } {
                const dist: u16 = self.count / (hint_count + 1);

                var pos: u16 = 0;
                for (self.hints) |hint| {
                    pos += @intFromBool((hint < key));
                }

                var pos2: u16 = pos;
                for (self.hints) |hint| {
                    pos2 += @intFromBool((hint == key));
                }

                // Calculate lower_out and upper_out based on positions found
                const lower_out = pos * dist;
                var upper_out = self.count;
                if (pos2 < hint_count) {
                    upper_out = ((pos2 + 1) * dist) + 1;
                }
                return .{ lower_out, upper_out };
            }

            fn update_hint(self: *Inner, slot_id: usize) void {
                const dist = self.count / (hint_count + 1);

                var begin: usize = 0;

                if ((self.count > hint_count * 2 + 1) and ((self.count - 1) / (hint_count + 1) == dist) and ((slot_id / dist) > 1)) {
                    begin = (slot_id / dist) - 1;
                }

                var i = begin;
                while (i < hint_count) : (i += 1) {
                    const idx = dist * (i + 1);
                    self.hints[i] = self.keys[idx];
                }

                i = 0;
                while (i < hint_count) : (i += 1) {
                    const idx = dist * (i + 1);
                    assert(self.hints[i] == self.keys[idx]);
                }
            }

            pub fn is_full(self: *const Inner) bool {
                return (self.count == inner_order - 1); // because of +1 of child
            }

            fn linear_counting_search(keys: []const Key, search_key: Key) usize {
                var count: usize = 0;
                for (keys) |*key| {
                    count += @intFromBool(key.* < search_key);
                }
                return count;
            }

            fn lower_bound(self: *const Inner, search_key: Key) LowerBoundResult {
                const hints = self.search_hints(search_key);
                const low: usize = hints.@"0";
                const high: usize = hints.@"1";
                assert(low < high);
                assert(high <= self.count);

                //const S = struct {
                //    fn lower_key(context: void, lhs: Key, rhs: Key) bool {
                //        _ = context;
                //        return lhs < rhs;
                //    }
                //};
                //const pos = (std.sort.lowerBound(Key, search_key, self.keys[low..high], {}, S.lower_key)) + low; // offset with low offset
                const pos = linear_counting_search(self.keys[low..high], search_key) + low; // offset with low offset

                if (pos == self.count) {
                    return .{ .greater = self.count };
                }

                switch (std.math.order(self.keys[pos], search_key)) {
                    .lt => {
                        unreachable;
                    },
                    .eq => {
                        return .{ .exact_match = @as(PtrType, @intCast(pos)) };
                    },
                    .gt => {
                        return .{ .greater = @as(PtrType, @intCast(pos)) };
                    },
                }
            }

            // returns the seperator
            fn split(self: *Inner, new_inner: *Inner) Key {
                assert(self.count >= 2);
                new_inner.count = self.count - (self.count / 2);
                self.count = self.count - new_inner.count - 1;
                const sep = self.keys[self.count];
                std.mem.copyBackwards(Key, new_inner.keys[0..], self.keys[self.count + 1 ..]); // not inclusive
                std.mem.copyBackwards(PtrType, new_inner.children[0..], self.children[self.count + 1 ..]); // not inclusive
                self.make_hint();
                new_inner.make_hint();
                return sep;
            }

            fn find_child(self: *const Inner, key: Key) PtrType {
                const result = self.lower_bound(key);
                switch (result) {
                    .exact_match, .greater => |pos| {
                        return self.children[pos];
                    },
                }
            }

            fn insert_slot(self: *Inner, pos: PtrType, key: Key, child: PtrType) void {
                assert(pos <= self.count);
                defer {
                    // should be smaller than count because of the children (+1)
                    assert(self.count < inner_order);
                }
                std.mem.copyBackwards(Key, self.keys[pos + 1 .. self.count + 1], self.keys[pos..self.count]);
                std.mem.copyBackwards(PtrType, self.children[pos + 1 .. self.count + 2], self.children[pos .. self.count + 1]); // +1 since one child more than keys
                self.keys[pos] = key;
                self.children[pos] = child;
                self.count += 1;
                std.mem.swap(PtrType, &self.children[pos], &self.children[pos + 1]); // corrects the logic from above by swapping the children
                self.update_hint(pos);
            }

            fn insert(self: *Inner, key: Key, child: PtrType) void {
                // assert not full
                const result = self.lower_bound(key);
                switch (result) {
                    .exact_match => {
                        @panic("duplicate key in inner");
                    },
                    .greater => |pos| {
                        self.insert_slot(pos, key, child);
                    },
                }
            }
        };

        const Leaf = struct {
            count: u16 = 0,
            sorted: bool = false,
            next_leaf: ?PtrType, // leaf pointer
            values: [order]Value,

            fn init() Leaf {
                return .{
                    .count = 0,
                    .sorted = false,
                    .values = undefined,
                    .next_leaf = null,
                };
            }

            fn insert_slot(self: *Leaf, pos: usize, value: *const Value) void {
                assert(pos < order);
                assert(pos <= self.count);

                std.mem.copyBackwards(Value, self.values[pos + 1 .. self.count + 1], self.values[pos..self.count]);
                self.values[pos] = value.*;
                self.count += 1;
            }

            fn sort_values_by_key_in_ascending_order(_: void, a: Value, b: Value) bool {
                return key_from_value(&a) < key_from_value(&b);
            }

            fn sort_and_deduplicate(self: *Leaf) void {
                assert(!self.sorted);
                std.mem.sort(Value, self.values[0..self.count], {}, Leaf.sort_values_by_key_in_ascending_order);
                // dedup
                const source_count = self.count;
                var source_index: usize = 0;
                var target_index: usize = 0;

                while (source_index < source_count) {
                    const value = self.values[source_index];
                    self.values[target_index] = value;

                    // Determine if the next value is the same as the current one.
                    const is_next_duplicate = source_index + 1 < source_count and
                        key_from_value(&self.values[source_index]) == key_from_value(&self.values[source_index + 1]);

                    // Move source_index forward, only increment target_index if no duplicate was found.
                    source_index += 1;
                    if (!is_next_duplicate) {
                        target_index += 1;
                    }
                }
                self.count = @as(u16, @intCast(target_index));
                self.sorted = true;
            }

            fn is_full(self: *Leaf) bool {
                const full = (self.count == order - 1);
                if (!full) return false;

                if (!self.sorted) {
                    self.sort_and_deduplicate();
                }
                return (self.count == order - 1);
            }

            fn insert(self: *Leaf, value: *const Value) void {
                self.values[self.count] = value.*;
                self.count += 1;
                self.sorted = false;
            }

            // returns the seperator links the leafs
            fn split(self: *Leaf, new_leaf: *Leaf, new_leaf_id: PtrType) Key {
                assert(self.count >= 2);
                new_leaf.next_leaf = self.next_leaf;
                self.next_leaf = new_leaf_id;
                new_leaf.count = self.count - (self.count / 2);
                self.count = self.count - new_leaf.count;
                const sep = key_from_value(&self.values[self.count - 1]);
                std.mem.copyBackwards(Value, new_leaf.values[0..], self.values[self.count..]);
                return sep;
            }

            fn lookup(self: *Leaf, value: Value) ?*const Value {
                if (!self.sorted) {
                    self.sort_and_deduplicate();
                }
                const result = self.lower_bound(key_from_value(&value));
                switch (result) {
                    .exact_match => |pos| {
                        return &self.values[pos];
                    },
                    .greater => {
                        return null;
                    },
                }
            }

            fn lower_bound(self: *const Leaf, search_key: Key) LowerBoundResult {
                var low: usize = 0;
                var high: usize = self.count;

                while (low < high) {
                    const mid = low + ((high - low) / 2);
                    const mid_key = key_from_value(&self.values[mid]);

                    switch (std.math.order(mid_key, search_key)) {
                        .lt => {
                            low = mid + 1;
                        },
                        .eq => {
                            return .{ .exact_match = @as(PtrType, @intCast(mid)) };
                        },
                        .gt => {
                            high = mid;
                        },
                    }
                }

                return .{ .greater = @as(PtrType, @intCast(low)) };
            }
        };

        height: u32 = 0,

        root: PtrType,
        free_list_inner: PtrType = 0,
        free_list_leaf: PtrType = 0,

        max_height: usize = 0,
        inners: []align(64) Inner,
        leafs: []align(64) Leaf,

        pub fn init(allocator: std.mem.Allocator, value_count_limit: usize) !Self {
            const min_order = @min(order, inner_order);
            const keys_min_leaf = (min_order - 1) / 2;
            const total_leaf_nodes = std.math.ceil(@as(f64, @floatFromInt(value_count_limit)) / keys_min_leaf);

            var total_nodes = total_leaf_nodes;
            var level_nodes = total_leaf_nodes;
            var height: u32 = 1;

            while (level_nodes > 1) {
                level_nodes = std.math.ceil(level_nodes / keys_min_leaf);
                total_nodes += level_nodes;
                height += 1;
            }

            const max_leaf_nodes: usize = @as(usize, @intFromFloat(total_leaf_nodes));
            const max_inner_nodes: usize = @as(usize, @intFromFloat(total_nodes)) - max_leaf_nodes;
            const max_height: usize = height;

            // Initialize your B-tree here
            //const t = try allocator.alignedAlloc(u64, 64, max_inner_nodes);
            const inners = try allocator.alignedAlloc(Inner, 64, max_inner_nodes);
            const leafs = try allocator.alignedAlloc(Leaf, 64, max_leaf_nodes);
            for (leafs) |*leaf| {
                leaf.* = Leaf.init();
            }
            for (inners) |*inner| {
                inner.* = Inner.init();
            }
            return Self{
                .inners = inners,
                .leafs = leafs,
                .root = 0,
                .free_list_leaf = 1,
                .max_height = max_height,
            };
        }

        fn make_root(self: *Self, sep: Key, left: PtrType, right: PtrType) void {
            const new_root_id = self.free_list_inner;
            var new_root = &self.inners[new_root_id];
            self.free_list_inner += 1;
            self.root = new_root_id;
            self.height += 1;
            new_root.count = 1;
            new_root.keys[0] = sep;
            new_root.children[0] = left;
            new_root.children[1] = right;
        }

        // TODO: refactor logic
        pub fn put(self: *Self, value: *const Value) void {
            outer: for (0..self.max_height) |_| {
                var maybe_parent: ?PtrType = null;
                var current_node = self.root;
                var current_height = self.height;
                const key = key_from_value(value);

                while (current_height > 0) {
                    var inner = &self.inners[current_node];
                    if (inner.is_full()) {
                        const new_inner_id = self.allocate_inner();
                        const new_inner = &self.inners[new_inner_id];
                        const sep = inner.split(new_inner);
                        assert(new_inner.count > 1); // TODO: fix this
                        assert(inner.count > 1);
                        if (maybe_parent) |parent| {
                            self.inners[parent].insert(sep, new_inner_id);
                        } else {
                            self.make_root(sep, current_node, new_inner_id);
                        }
                        continue :outer;
                    }
                    maybe_parent = current_node;
                    current_node = self.inners[current_node].find_child(key);
                    current_height -= 1;
                }
                // take leaf
                var leaf = &self.leafs[current_node];
                if (leaf.is_full()) {
                    const new_leaf_id = self.allocate_leaf();
                    const new_leaf = &self.leafs[new_leaf_id];
                    const sep = leaf.split(new_leaf, new_leaf_id);
                    if (maybe_parent) |parent| {
                        self.inners[parent].insert(sep, new_leaf_id);
                    } else {
                        self.make_root(sep, current_node, new_leaf_id);
                    }
                    continue;
                }
                // TODO: refactor
                leaf.insert(value);
                return;
            }
            unreachable;
        }

        fn allocate_inner(self: *Self) PtrType {
            assert(self.free_list_inner < self.inners.len);
            const new_inner_id = self.free_list_inner;
            self.free_list_inner += 1;
            const inner = &self.inners[new_inner_id];
            inner.* = Inner.init();
            return new_inner_id;
        }

        fn allocate_leaf(self: *Self) PtrType {
            assert(self.free_list_leaf < self.leafs.len);
            const new_leaf_id = self.free_list_leaf;
            self.free_list_leaf += 1;
            const leaf = &self.leafs[new_leaf_id];
            leaf.* = Leaf.init();
            return new_leaf_id;
        }

        pub fn get(self: *Self, value: *const Value) ?*const Value {
            var maybe_parent: ?PtrType = null;
            var current_node = self.root;
            var current_height = self.height;
            const key = key_from_value(value);

            while (current_height > 0) {
                maybe_parent = current_node;
                current_node = self.inners[current_node].find_child(key);
                current_height -= 1;
            }
            var leaf = &self.leafs[current_node];
            return leaf.lookup(value.*);
        }

        pub fn reset(self: *Self) void {
            std.debug.print("reset tree height {} \n", .{self.height});
            self.height = 0;
            self.root = 0;
            self.free_list_inner = 0;
            self.free_list_leaf = 0;
            // should create new root at index 0
            const new_root = self.allocate_leaf();
            assert(self.root == new_root);
            assert(self.free_list_leaf == 1);
        }

        pub fn copy_in_order(self: *const Self, target: []Value) usize {
            // TODO: try to optimize this with batching. we can get the batches from the last inner leaves
            // find the left most node
            var maybe_next_leaf_id: ?PtrType = self.get_left_most_leaf();
            // follow all links until the end
            var offset: usize = 0;
            while (maybe_next_leaf_id) |next_leaf_id| {
                const leaf = &self.leafs[next_leaf_id];
                if (!leaf.sorted) {
                    leaf.sort_and_deduplicate();
                }
                // copy into the output
                std.mem.copyForwards(Value, target[offset .. offset + leaf.count], leaf.values[0..leaf.count]);
                offset += leaf.count;
                maybe_next_leaf_id = leaf.next_leaf;
            }
            return offset;
        }

        fn get_left_most_leaf(self: *const Self) PtrType {
            var maybe_parent: ?usize = null;
            var current_node = self.root;
            var current_height = self.height;

            while (current_height > 0) {
                maybe_parent = current_node;
                current_node = self.inners[current_node].children[0];
                current_height -= 1;
            }
            return current_node;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.inners);
            allocator.free(self.leafs);
        }
    };
}
