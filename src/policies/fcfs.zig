const std = @import("std");

pub fn selectNext(ready_queue: *std.ArrayList(usize)) ?usize {
    if (ready_queue.items.len == 0) return null;
    return ready_queue.orderedRemove(0);
}
