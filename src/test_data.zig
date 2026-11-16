pub fn repeat(comptime pattern: []const u8, comptime count: usize) [pattern.len * count]u8 {
    @setEvalBranchQuota(10_000);
    var bytes: [pattern.len * count]u8 = undefined;
    for (0..count) |i| {
        @memcpy(bytes[i * pattern.len ..][0..pattern.len], pattern);
    }
    return bytes;
}
