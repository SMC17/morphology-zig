const std = @import("std");

pub const Category = enum {
    N, // Noun
    V, // Verb
    Adj, // Adjective
    Adv, // Adverb
    Det, // Determiner
    Aux, // Auxiliary
    Pron,
    Prep,
    Conj,
    Num,
    Part,
    Interj,
    Unknown,
};

pub fn categoryToString(cat: Category) []const u8 {
    return switch (cat) {
        .N => "N",
        .V => "V",
        .Adj => "Adj",
        .Adv => "Adv",
        .Det => "Det",
        .Aux => "Aux",
        .Pron => "Pron",
        .Prep => "Prep",
        .Conj => "Conj",
        .Num => "Num",
        .Part => "Part",
        .Interj => "Interj",
        .Unknown => "Unknown",
    };
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

pub fn parseCategory(s: []const u8) Category {
    if (eqIgnoreCase(s, "n")) return .N;
    if (eqIgnoreCase(s, "v")) return .V;
    if (eqIgnoreCase(s, "adj")) return .Adj;
    if (eqIgnoreCase(s, "adv")) return .Adv;
    if (eqIgnoreCase(s, "det")) return .Det;
    if (eqIgnoreCase(s, "aux")) return .Aux;
    return .Unknown;
}

test "category string roundtrip basic" {
    try std.testing.expectEqualStrings("N", categoryToString(.N));
    try std.testing.expectEqualStrings("V", categoryToString(.V));
    try std.testing.expectEqual(parseCategory("Adj"), .Adj);
}
