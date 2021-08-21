const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const config = @import("../config.zig");

const Cluster = @import("cluster.zig").Cluster;
const Network = @import("network.zig").Network;
const StateMachine = @import("state_machine.zig").StateMachine;

const MessagePool = @import("../message_pool.zig").MessagePool;
const Message = MessagePool.Message;

const RingBuffer = @import("../ring_buffer.zig").RingBuffer;

const log = std.log.scoped(.state_checker);

const RequestQueue = RingBuffer(u128, config.message_bus_messages_max - 1);
const Transitioned = std.bit_set.IntegerBitSet(config.replicas_max);
const StateTransitions = std.AutoHashMap(u128, Transitioned);

pub const StateChecker = struct {
    /// Indexed by client index used by Cluster
    client_requests: [config.clients_max]RequestQueue =
        [_]RequestQueue{.{}} ** config.clients_max,

    /// Indexed by replica index
    state_machine_states: [config.replicas_max]u128,

    history: StateTransitions,

    /// The highest cannonical state reached by the cluster
    state: u128,
    /// The number of times the cannonical state has been advanced.
    transitions: u64 = 0,

    pub fn init(allocator: *mem.Allocator, cluster: *Cluster) !StateChecker {
        const state = cluster.state_machines[0].state;
        log.debug("initial state={}", .{state});

        var state_machine_states: [config.replicas_max]u128 = undefined;
        for (cluster.state_machines) |state_machine, i| {
            assert(state_machine.state == state);
            state_machine_states[i] = state_machine.state;
        }

        return StateChecker{
            .state_machine_states = state_machine_states,
            .history = StateTransitions.init(allocator),
            .state = state,
        };
    }

    pub fn deinit(state_checker: *StateChecker) void {
        state_checker.history.deinit();
    }

    pub fn check_state(state_checker: *StateChecker, replica: u8) void {
        const cluster = @fieldParentPtr(Cluster, "state_checker", state_checker);

        const a = state_checker.state_machine_states[replica];
        const b = cluster.state_machines[replica].state;

        if (b == a) return;
        state_checker.state_machine_states[replica] = b;

        log.debug("replica {} changed state={x}..{x}", .{ replica, a, b });

        // If some other replica has already reached this state
        if (state_checker.history.getPtr(b)) |transitioned| {
            log.debug("replica {} new state={} found in history", .{ replica, b });

            if (transitioned.isSet(replica)) {
                @panic("replica transitioned to the same state a second time");
            }

            transitioned.set(replica);

            log.notice(
                "replica={} state={x}..{x} transitions={}",
                .{ replica, a, b, state_checker.transitions },
            );

            // Remove from history if all replicas have reached this state.
            const transitions = transitioned.count();
            if (transitions == cluster.options.replica_count) {
                log.debug("all replicas have reached state={}", .{b});
            }
            assert(transitions <= cluster.options.replica_count);

            return;
        }

        // As soon as we use an inflight client request to arrive at a valid state we want to pop().
        // Otherwise, if we used the client.request_queue directly, we would allow multiple uses.

        // The replica has transitioned to a state b that is not yet in the history.
        // Check if this is a vaild next state based on the currently inflight messages
        // from clients.
        for (state_checker.client_requests) |*queue| {
            if (queue.peek_ptr()) |input| {
                if (b == StateMachine.hash(state_checker.state, std.mem.asBytes(input))) {
                    state_checker.state = b;
                    state_checker.transitions += 1;
                    log.notice(
                        "replica={} state={x}..{x} transitions={} advanced",
                        .{ replica, a, b, state_checker.transitions },
                    );

                    var transitioned = Transitioned.initEmpty();
                    transitioned.set(replica);

                    state_checker.history.putNoClobber(b, transitioned) catch @panic("Test OOM");

                    // TODO We must hook into all places in Replica where state may change.
                    // Otherwise, if state changes successively, e.g. because of an asynchronous
                    // I/O callback, then we may miss a transition and our client_requests queue
                    // will get out of sync, resulting in a spurious "invalid state" panic.
                    _ = queue.pop();
                    return;
                }
            }
        }

        @panic("replica transitioned to an invalid state");
    }
};
