const wl = @import("wayland").client.wl;

pub fn SafeIterator(comptime T: type, comptime field: @TypeOf(.enum_literal)) type {
    return struct {
        const Self = @This();

        head: *const wl.list.Link,
        next_link: *wl.list.Link,

        pub fn next(it: *Self) ?*T {
            const current = it.next_link;
            if (current == it.head) return null;

            it.next_link = current.next orelse return null;

            return @fieldParentPtr(@tagName(field), current);
        }
    };
}

pub fn safeIterator(
    comptime T: type,
    comptime field: @TypeOf(.enum_literal),
    head: *wl.list.Head(T, field),
) SafeIterator(T, field) {
    return .{
        .head = &head.link,
        .next_link = head.link.next.?,
    };
}
