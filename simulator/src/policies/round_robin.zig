const std = @import("std");

pub fn shouldPreempt(current_quantum: u32, quantum: u32, ready_len: usize) bool {
    return ready_len > 0 and current_quantum >= quantum;
}

pub fn selectNext(ready_queue: *std.ArrayList(usize)) ?usize {
    if (ready_queue.items.len == 0) return null;
    return ready_queue.orderedRemove(0);
}
