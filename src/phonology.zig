const std = @import("std");

// Simplified phonology helpers to support allomorphy examples from slides
// Plural -s allomorphy: [s] after heuristically voiceless segment, [z] otherwise.
// We do not implement -ɪz (e.g., after sibilants) because slides focus on [s]/[z].
pub fn isHeuristicallyVoiceless(last: u8) bool {
    // Crude but effective for slides: most obstruents represented in ASCII
    return switch (std.ascii.toLower(last)) {
        'p', 't', 'k', 'f', 's', 'h', 'c', 'x' => true,
        else => false,
    };
}

pub fn pluralSuffixFor(stem: []const u8) []const u8 {
    if (stem.len == 0) return "s";
    const last = stem[stem.len - 1];
    return if (isHeuristicallyVoiceless(last)) "s" else "z";
}

test "plural allomorph heuristic" {
    try std.testing.expectEqualStrings("s", pluralSuffixFor("cat"));
    try std.testing.expectEqualStrings("z", pluralSuffixFor("dog"));
    try std.testing.expectEqualStrings("z", pluralSuffixFor("roll"));
    try std.testing.expectEqualStrings("s", pluralSuffixFor("pack"));
}
