const std = @import("std");
const Category = @import("categories.zig").Category;
const catStr = @import("categories.zig").categoryToString;
const Phono = @import("phonology.zig");
const syntax = @import("syntax.zig");

pub const MorphError = error{
    Ungrammatical,
    ConstraintViolation,
    NotApplicable,
};

pub const RuleKind = enum { Prefix, Suffix, Infix, Reduplication, ZeroDerivation, StressShift, Ablaut, Suppletion };

// Minimal binary tree to represent morphological derivations
pub const Source = enum { Stored, Derived };

pub const Node = struct {
    token: []const u8, // surface string at this node
    category: Category,
    rule: ?[]const u8, // e.g., "V + -able -> Adj"
    left: ?*Node, // stem
    right: ?*Node, // affix/operation node
    source: Source = .Derived,

    pub fn print(self: *const Node, writer: anytype, depth: usize) !void {
        try writer.print("{s}[{s}]\n", .{ self.token, catStr(self.category) });
        if (self.left) |l| {
            try writer.print("{s}", .{indent(depth + 1)});
            try l.print(writer, depth + 1);
        }
        if (self.right) |r| {
            try writer.print("{s}", .{indent(depth + 1)});
            try r.print(writer, depth + 1);
        }
    }
};

fn indent(n: usize) []const u8 {
    return switch (n) {
        0 => "",
        1 => "  ",
        2 => "    ",
        3 => "      ",
        4 => "        ",
        else => "            ",
    };
}

pub fn newRoot(allocator: std.mem.Allocator, form: []const u8, category: Category) !*Node {
    const node = try allocator.create(Node);
    node.* = .{ .token = try allocator.dupe(u8, form), .category = category, .rule = null, .left = null, .right = null, .source = .Stored };
    return node;
}

pub fn newAffixNode(allocator: std.mem.Allocator, affix: []const u8) !*Node {
    const node = try allocator.create(Node);
    node.* = .{ .token = try allocator.dupe(u8, affix), .category = .Unknown, .rule = null, .left = null, .right = null };
    return node;
}

pub const SuffixRule = struct {
    name: []const u8,
    input: Category,
    output: Category,
    base_affix: []const u8,
    // Optional allomorph selector; returns affix surface form.
    // Zig 0.16: function-type struct fields must be pointers (`?*const fn`).
    allomorph: ?*const fn (allocator: std.mem.Allocator, stem: []const u8) anyerror![]const u8,
    // Optional combiner that can implement simple spell-out adjustments.
    combiner: ?*const fn (allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) anyerror![]u8 = null,
    // Optional allow-predicate; when provided and false, rule is NotApplicable.
    allow: ?*const fn (stem: []const u8) bool = null,

    pub fn apply(self: *const SuffixRule, allocator: std.mem.Allocator, stem_node: *Node) !*Node {
        if (stem_node.category != self.input) return MorphError.NotApplicable;
        if (self.allow) |ok| {
            if (!ok(stem_node.token)) return MorphError.NotApplicable;
        }
        const suf: []const u8 = if (self.allomorph) |sel| try sel(allocator, stem_node.token) else self.base_affix;
        const combined = if (self.combiner) |c| try c(allocator, stem_node.token, suf) else try concat2(allocator, stem_node.token, suf);
        const aff = try newAffixNode(allocator, suf);
        const node = try allocator.create(Node);
        node.* = .{
            .token = combined,
            .category = self.output,
            .rule = self.name,
            .left = stem_node,
            .right = aff,
            .source = .Derived,
        };
        return node;
    }
};

pub const PrefixRule = struct {
    name: []const u8,
    input: Category,
    output: Category,
    affix: []const u8,

    pub fn apply(self: *const PrefixRule, allocator: std.mem.Allocator, stem_node: *Node) !*Node {
        if (stem_node.category != self.input) return MorphError.NotApplicable;
        const combined = try concat2(allocator, self.affix, stem_node.token);
        const aff = try newAffixNode(allocator, self.affix);
        const node = try allocator.create(Node);
        node.* = .{
            .token = combined,
            .category = self.output,
            .rule = self.name,
            .left = aff,
            .right = stem_node,
            .source = .Derived,
        };
        return node;
    }
};

fn concat2(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    const len = a.len + b.len;
    var out = try allocator.alloc(u8, len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

// Generic process rule where the surface change is handled entirely by a combiner.
pub const ProcessRule = struct {
    name: []const u8,
    input: Category,
    output: Category,
    // Zig 0.16: function-type struct fields must be pointers.
    combiner: *const fn (allocator: std.mem.Allocator, stem: []const u8) anyerror![]u8,

    pub fn apply(self: *const ProcessRule, allocator: std.mem.Allocator, stem_node: *Node) !*Node {
        if (stem_node.category != self.input) return MorphError.NotApplicable;
        const out = try self.combiner(allocator, stem_node.token);
        const node = try allocator.create(Node);
        node.* = .{
            .token = out,
            .category = self.output,
            .rule = self.name,
            .left = stem_node,
            .right = null,
            .source = .Derived,
        };
        return node;
    }
};

// Simple combiner helpers approximating spell-out changes highlighted in slides.
fn dropFinalEAndConcat(allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) ![]u8 {
    if (stem.len > 0 and std.ascii.toLower(stem[stem.len - 1]) == 'e') {
        return try concat2(allocator, stem[0 .. stem.len - 1], affix);
    }
    return try concat2(allocator, stem, affix);
}

fn yToIBeforeSuffix(allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) ![]u8 {
    if (stem.len >= 2 and std.ascii.toLower(stem[stem.len - 1]) == 'y') {
        const prev = std.ascii.toLower(stem[stem.len - 2]);
        const is_vowel = prev == 'a' or prev == 'e' or prev == 'i' or prev == 'o' or prev == 'u';
        if (!is_vowel) {
            // stem without final y + 'i' + affix
            const base = stem[0 .. stem.len - 1];
            const with_i = try concat2(allocator, base, "i");
            return try concat2(allocator, with_i, affix);
        }
    }
    return try concat2(allocator, stem, affix);
}

// Heuristic: double final consonant before -able for CVC stems like stop -> stoppable
fn doubleFinalConsonantAndConcat(allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) ![]u8 {
    if (stem.len >= 3) {
        const last = std.ascii.toLower(stem[stem.len - 1]);
        const prev = std.ascii.toLower(stem[stem.len - 2]);
        const prevprev = std.ascii.toLower(stem[stem.len - 3]);
        const is_vowel = prev == 'a' or prev == 'e' or prev == 'i' or prev == 'o' or prev == 'u';
        const is_consonant = !(last == 'a' or last == 'e' or last == 'i' or last == 'o' or last == 'u');
        const prevprev_is_consonant = !(prevprev == 'a' or prevprev == 'e' or prevprev == 'i' or prevprev == 'o' or prevprev == 'u');
        const non_doublers = last == 'w' or last == 'x' or last == 'y';
        if (prevprev_is_consonant and is_vowel and is_consonant and !non_doublers) {
            const base = try concat2(allocator, stem, &.{ last });
            return try concat2(allocator, base, affix);
        }
    }
return try concat2(allocator, stem, affix);
}

fn enCombiner(allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) ![]u8 {
    // Drop final 'e'
    if (stem.len > 0 and std.ascii.toLower(stem[stem.len - 1]) == 'e') {
        return try concat2(allocator, stem[0 .. stem.len - 1], affix);
    }
    // Double final t/d in short CVC monosyllables (red->redden, fat->fatten)
    if (approxMonosyllabic(stem) and stem.len >= 3) {
        const last = std.ascii.toLower(stem[stem.len - 1]);
        const prev = std.ascii.toLower(stem[stem.len - 2]);
        const prevprev = std.ascii.toLower(stem[stem.len - 3]);
        const is_cvc = !isVowel(prevprev) and isVowel(prev) and !isVowel(last);
        if (is_cvc and (last == 'd' or last == 't')) {
            const doubled = try concat2(allocator, stem, &.{ last });
            return try concat2(allocator, doubled, affix);
        }
    }
    return try concat2(allocator, stem, affix);
}

fn comparCombiner(allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) ![]u8 {
    // First handle y -> i
    const base = try yToIBeforeSuffix(allocator, stem, "");
    // Then apply doubling for short CVC monosyllabic adjectives
    if (approxMonosyllabic(stem) and stem.len >= 3) {
        const last = std.ascii.toLower(stem[stem.len - 1]);
        const prev = std.ascii.toLower(stem[stem.len - 2]);
        const prevprev = std.ascii.toLower(stem[stem.len - 3]);
        const last_is_cons = !isVowel(last) and last != 'w' and last != 'x' and last != 'y';
        const is_cvc = !isVowel(prevprev) and isVowel(prev) and last_is_cons;
        if (is_cvc) {
            const doubled = try concat2(allocator, base, &.{ last });
            return try concat2(allocator, doubled, affix);
        }
    }
    return try concat2(allocator, base, affix);
}

// Canonical rules from the slides (subset)
pub const MorphConfig = struct {
    use_irregular_plurals: bool = true,
    block_regular_if_irregular: bool = true,
};

pub const MorphSession = struct {
    use_irregular_plurals: bool = true,
    block_regular_plural: bool = true,
    // If true, when both irregular and regular are available, prefer irregular surface
    prefer_irregular_plural_if_available: bool = true,
    // Force these adjectives to periphrastic more/most regardless of heuristics
    periphrastic_adjectives: []const []const u8 = &.{ "fun", "real", "likely", "interesting", "beautiful", "expensive", "useful" },
    // Force these adjectives to morphological -er/-est even if polysyllabic
    morphological_adjectives: []const []const u8 = &.{},
    // If true, polysyllabic adjectives prefer periphrastic more/most
    prefer_periphrastic_if_polysyllabic: bool = true,
    // If false, for cases not covered by lexicon/heuristics, default to periphrastic instead of -er/-est
    prefer_morphological_comparative_default: bool = true,
    // Genitive choice
    prefer_of_phrase_for_possessive: bool = false,
    // Session-provided irregular plural overrides (runtime registry)
    irregular_plural_overrides: []const IrregularPair = &.{},
};

pub const IrregularPair = struct { singular: []const u8, plural: []const u8 };

fn irregularPluralLookup(word: []const u8) ?[]const u8 {
    const table = [_]IrregularPair{
        .{ .singular = "child", .plural = "children" },
        .{ .singular = "foot", .plural = "feet" },
        .{ .singular = "goose", .plural = "geese" },
        .{ .singular = "mouse", .plural = "mice" },
        .{ .singular = "tooth", .plural = "teeth" },
        .{ .singular = "man", .plural = "men" },
        .{ .singular = "woman", .plural = "women" },
        .{ .singular = "person", .plural = "people" },
        .{ .singular = "ox", .plural = "oxen" },
        .{ .singular = "louse", .plural = "lice" },
    };
    var i: usize = 0;
    while (i < table.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(word, table[i].singular)) return table[i].plural;
    }
    return null;
}

pub fn isPluralNoun(word: []const u8) bool {
    // Check irregular plurals first
    const irregular_plurals = [_][]const u8{
        "children", "feet", "geese", "mice", "teeth",
        "men", "women", "people", "oxen", "lice",
    };
    for (irregular_plurals) |pl| if (std.ascii.eqlIgnoreCase(word, pl)) return true;
    // Regular heuristic: ends with 's' or 'z' in our surface representation
    if (word.len == 0) return false;
    const last = std.ascii.toLower(word[word.len - 1]);
    return (last == 's') or (last == 'z');
}

pub fn pluralizeN(config: MorphConfig, allocator: std.mem.Allocator, n: *Node) !*Node {
    if (n.category != .N) return MorphError.NotApplicable;
    if (config.use_irregular_plurals) {
        if (irregularPluralLookup(n.token)) |pl|
            return try newRoot(allocator, pl, .N);
    }
    // Fallback to regular plural -s
    return try Rules.N_plural_s.apply(allocator, n);
}

fn regularPluralNoBlock(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    const suf = Phono.pluralSuffixFor(stem);
    return try concat2(allocator, stem, suf);
}

fn sessionIrregularPluralLookup(sess: MorphSession, word: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < sess.irregular_plural_overrides.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(word, sess.irregular_plural_overrides[i].singular)) return sess.irregular_plural_overrides[i].plural;
    }
    return null;
}

pub fn pluralWithSession(sess: MorphSession, allocator: std.mem.Allocator, n: *Node) !*Node {
    if (n.category != .N) return MorphError.NotApplicable;
    if (sess.use_irregular_plurals) {
        if (irregularPluralLookup(n.token)) |pl|
            return try newRoot(allocator, pl, .N);
        if (sessionIrregularPluralLookup(sess, n.token)) |pl2|
            return try newRoot(allocator, pl2, .N);
    }
    if (irregularPluralLookup(n.token) != null or sessionIrregularPluralLookup(sess, n.token) != null) {
        if (sess.block_regular_plural) return MorphError.NotApplicable;
        // else fall through to regular; this function purposefully returns regular path
    }
    const surf = try regularPluralNoBlock(allocator, n.token);
    const aff = try newAffixNode(allocator, Phono.pluralSuffixFor(n.token));
    const node = try allocator.create(Node);
    node.* = .{
        .token = surf,
        .category = .N,
        .rule = "N + -s -> Npl (no-block)",
        .left = n,
        .right = aff,
        .source = .Derived,
    };
    return node;
}

// Decide plural form using session preferences (irregular vs regular). If blocked, returns NotApplicable.
pub fn pluralDecideWithSession(sess: MorphSession, allocator: std.mem.Allocator, n: *Node) !*Node {
    if (n.category != .N) return MorphError.NotApplicable;
    const irr = irregularPluralLookup(n.token) orelse sessionIrregularPluralLookup(sess, n.token);
    if (irr) |pl| {
        if (sess.prefer_irregular_plural_if_available) {
            return try newRoot(allocator, pl, .N);
        } else {
            if (sess.block_regular_plural) return MorphError.NotApplicable;
            // choose regular
            const surf = try regularPluralNoBlock(allocator, n.token);
            const aff = try newAffixNode(allocator, Phono.pluralSuffixFor(n.token));
            const node = try allocator.create(Node);
            node.* = .{ .token = surf, .category = .N, .rule = "N + -s -> Npl (chosen-regular)", .left = n, .right = aff, .source = .Derived };
            return node;
        }
    }
    // No irregular; return regular
    const surf = try regularPluralNoBlock(allocator, n.token);
    const aff = try newAffixNode(allocator, Phono.pluralSuffixFor(n.token));
    const node = try allocator.create(Node);
    node.* = .{ .token = surf, .category = .N, .rule = "N + -s -> Npl (regular)", .left = n, .right = aff, .source = .Derived };
    return node;
}

// allow-predicate helpers
fn isVowel(c: u8) bool {
    const ch = std.ascii.toLower(c);
    return ch == 'a' or ch == 'e' or ch == 'i' or ch == 'o' or ch == 'u';
}

fn approxMonosyllabic(word: []const u8) bool {
    // Count vowel groups; treat 'y' as consonant for simplicity.
    var i: usize = 0;
    var groups: usize = 0;
    var in_vowel = false;
    while (i < word.len) : (i += 1) {
        const v = isVowel(word[i]);
        if (v and !in_vowel) {
            groups += 1;
            in_vowel = true;
        } else if (!v) {
            in_vowel = false;
        }
    }
    return groups <= 1;
}

fn finalAllowsEn(word: []const u8) bool {
    if (word.len == 0) return false;
    // Exclude certain orthographic clusters that rarely take -en in this model
    if (word.len >= 2) {
        const a = std.ascii.toLower(word[word.len - 2]);
        const b = std.ascii.toLower(word[word.len - 1]);
        const bad = (a == 'c' and b == 'h') or (a == 's' and b == 'h') or (a == 's' and b == 's') or (a == 'z' and b == 'z');
        if (bad) return false;
    }
    // If ends with 'e', inspect preceding letter
    var idx: isize = @as(isize, @intCast(word.len)) - 1;
    var u: usize = @as(usize, @intCast(idx));
    var last = std.ascii.toLower(word[u]);
    if (last == 'e' and word.len >= 2) {
        idx -= 1;
        u = @as(usize, @intCast(idx));
        last = std.ascii.toLower(word[u]);
    }
    const prev: u8 = if (idx - 1 >= 0) std.ascii.toLower(word[@as(usize, @intCast(idx - 1))]) else 0;
    const prevprev: u8 = if (idx - 2 >= 0) std.ascii.toLower(word[@as(usize, @intCast(idx - 2))]) else 0;
    const stops = last == 'p' or last == 'b' or last == 't' or last == 'd' or last == 'k' or last == 'g' or last == 'f';
    const non_doublers = last == 'w' or last == 'x' or last == 'y';
    const cv_pattern = isVowel(prev) and (prevprev != 0 and !isVowel(prevprev));
    return stops and !non_doublers and cv_pattern;
}

fn allowAdjEn(stem: []const u8) bool {
    // Allow a curated list OR monosyllabic + final stop/affricate approximation
    const allow_list = [_][]const u8{ "white", "soft", "quick", "thick", "bright", "black", "broad", "dark", "red", "wide", "sharp" };
    for (allow_list) |w| if (std.ascii.eqlIgnoreCase(stem, w)) return true;
    // Specific exclusions (e.g., board -> *boarden)
    const exclude = [_][]const u8{ "board", "fresh" };
    for (exclude) |w| if (std.ascii.eqlIgnoreCase(stem, w)) return false;
    return approxMonosyllabic(stem) and finalAllowsEn(stem);
}

fn allowNEn(stem: []const u8) bool {
    // N + -en -> V for a small set like lengthen/strengthen
    return std.ascii.eqlIgnoreCase(stem, "length") or std.ascii.eqlIgnoreCase(stem, "strength");
}

fn allowRegularPlural(stem: []const u8) bool {
    // Block regular -s when irregular is present
    return irregularPluralLookup(stem) == null;
}

fn ableCombiner(allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) ![]u8 {
    // Drop final 'e' if present (use -> usable), then apply CVC doubling
    var base: []const u8 = stem;
    if (stem.len > 0 and std.ascii.toLower(stem[stem.len - 1]) == 'e') {
        base = stem[0 .. stem.len - 1];
    }
    // Now double final consonant for short CVC if applicable
    if (base.len >= 3) {
        const last = std.ascii.toLower(base[base.len - 1]);
        const prev = std.ascii.toLower(base[base.len - 2]);
        const prevprev = std.ascii.toLower(base[base.len - 3]);
        const is_vowel = prev == 'a' or prev == 'e' or prev == 'i' or prev == 'o' or prev == 'u';
        const is_consonant = !(last == 'a' or last == 'e' or last == 'i' or last == 'o' or last == 'u');
        const prevprev_is_consonant = !(prevprev == 'a' or prevprev == 'e' or prevprev == 'i' or prevprev == 'o' or prevprev == 'u');
        const non_doublers = last == 'w' or last == 'x' or last == 'y';
        if (prevprev_is_consonant and is_vowel and is_consonant and !non_doublers) {
            const base2 = try concat2(allocator, base, &.{ last });
            return try concat2(allocator, base2, affix);
        }
    }
    return try concat2(allocator, base, affix);
}

fn ifyCombiner(allocator: std.mem.Allocator, stem: []const u8, affix: []const u8) ![]u8 {
    // glory -> glorify (drop final y after consonant); pure -> purify (drop final e)
    if (stem.len >= 2 and std.ascii.toLower(stem[stem.len - 1]) == 'y') {
        const prev = std.ascii.toLower(stem[stem.len - 2]);
        const is_vowel = prev == 'a' or prev == 'e' or prev == 'i' or prev == 'o' or prev == 'u';
        if (!is_vowel) {
            return try concat2(allocator, stem[0 .. stem.len - 1], affix);
        }
    }
    if (stem.len > 0 and std.ascii.toLower(stem[stem.len - 1]) == 'e') {
        return try concat2(allocator, stem[0 .. stem.len - 1], affix);
    }
    return try concat2(allocator, stem, affix);
}

pub const Rules = struct {
pub const V_to_Adj_able = SuffixRule{ .name = "V + -able -> Adj", .input = .V, .output = .Adj, .base_affix = "able", .allomorph = null, .combiner = ableCombiner };
    pub const Adj_to_N_ity = SuffixRule{ .name = "Adj + -ity -> N", .input = .Adj, .output = .N, .base_affix = "ity", .allomorph = null, .combiner = dropFinalEAndConcat };
    pub const Adj_to_N_ness = SuffixRule{ .name = "Adj + -ness -> N", .input = .Adj, .output = .N, .base_affix = "ness", .allomorph = null, .combiner = yToIBeforeSuffix };
    pub const V_to_N_er = SuffixRule{ .name = "V + -er -> N", .input = .V, .output = .N, .base_affix = "er", .allomorph = null, .combiner = null };
    pub const V_to_N_ment = SuffixRule{ .name = "V + -ment -> N", .input = .V, .output = .N, .base_affix = "ment", .allomorph = null, .combiner = null };
    pub const N_to_Adj_ful = SuffixRule{ .name = "N + -ful -> Adj", .input = .N, .output = .Adj, .base_affix = "ful", .allomorph = null, .combiner = null };
    pub const N_to_Adj_less = SuffixRule{ .name = "N + -less -> Adj", .input = .N, .output = .Adj, .base_affix = "less", .allomorph = null, .combiner = null };
    pub const N_to_Adj_ish = SuffixRule{ .name = "N + -ish -> Adj", .input = .N, .output = .Adj, .base_affix = "ish", .allomorph = null, .combiner = null };
    pub const Adj_to_Adj_ish = SuffixRule{ .name = "Adj + -ish -> Adj", .input = .Adj, .output = .Adj, .base_affix = "ish", .allomorph = null, .combiner = null };
    pub const V_to_N_ation = SuffixRule{ .name = "V + -ation -> N", .input = .V, .output = .N, .base_affix = "ation", .allomorph = null, .combiner = dropFinalEAndConcat };
    pub const V_to_N_al = SuffixRule{ .name = "V + -al -> N", .input = .V, .output = .N, .base_affix = "al", .allomorph = null, .combiner = dropFinalEAndConcat };
    pub const V_to_N_ance = SuffixRule{ .name = "V + -ance -> N", .input = .V, .output = .N, .base_affix = "ance", .allomorph = null, .combiner = yToIBeforeSuffix };
    pub const N_to_V_ize = SuffixRule{ .name = "N + -ize -> V", .input = .N, .output = .V, .base_affix = "ize", .allomorph = null, .combiner = null };
    pub const Adj_to_V_ize = SuffixRule{ .name = "Adj + -ize -> V", .input = .Adj, .output = .V, .base_affix = "ize", .allomorph = null, .combiner = null };
    pub const N_to_V_ify = SuffixRule{ .name = "N + -ify -> V", .input = .N, .output = .V, .base_affix = "ify", .allomorph = null, .combiner = ifyCombiner };
    pub const Adj_to_V_ify = SuffixRule{ .name = "Adj + -ify -> V", .input = .Adj, .output = .V, .base_affix = "ify", .allomorph = null, .combiner = ifyCombiner };
    pub const Adj_to_V_en = SuffixRule{ .name = "Adj + -en -> V", .input = .Adj, .output = .V, .base_affix = "en", .allomorph = null, .combiner = enCombiner, .allow = allowAdjEn };
    pub const N_to_V_en = SuffixRule{ .name = "N + -en -> V", .input = .N, .output = .V, .base_affix = "en", .allomorph = null, .combiner = null, .allow = allowNEn };
    pub const Adj_to_Adj_er = SuffixRule{ .name = "Adj + -er -> Adjcmp", .input = .Adj, .output = .Adj, .base_affix = "er", .allomorph = null, .combiner = comparCombiner };
    pub const Adj_to_Adj_est = SuffixRule{ .name = "Adj + -est -> Adjsup", .input = .Adj, .output = .Adj, .base_affix = "est", .allomorph = null, .combiner = comparCombiner };

    pub const N_plural_s = SuffixRule{
        .name = "N + -s -> Npl",
        .input = .N,
        .output = .N, // keep N; plurality can be carried as feature in future
        .base_affix = "s",
        .allomorph = pluralAllomorph,
        .combiner = null,
        .allow = allowRegularPlural,
    };

    pub const N_possessive_s = SuffixRule{ .name = "N + 's -> Nposs", .input = .N, .output = .N, .base_affix = "'s", .allomorph = null, .combiner = null };

    pub const Un_not_Adj = PrefixRule{ .name = "un-(not) + Adj -> Adj", .input = .Adj, .output = .Adj, .affix = "un" };
    pub const Un_reverse_V = PrefixRule{ .name = "un-(reverse) + V -> V", .input = .V, .output = .V, .affix = "un" };
    pub const Non_not_Adj = PrefixRule{ .name = "non- + Adj -> Adj", .input = .Adj, .output = .Adj, .affix = "non" };
    pub const Mis_V = PrefixRule{ .name = "mis- + V -> V", .input = .V, .output = .V, .affix = "mis" };

    // Processes
    pub const Redup_V = ProcessRule{ .name = "Redup CV (V -> V)", .input = .V, .output = .V, .combiner = redupFirstCV };
    pub const StressToVerb = ProcessRule{ .name = "Stress shift to V (N -> V)", .input = .N, .output = .V, .combiner = stressToVerb };
    pub const StressToNoun = ProcessRule{ .name = "Stress shift to N (V -> N)", .input = .V, .output = .N, .combiner = stressToNoun };
    pub const PastAblaut = ProcessRule{ .name = "Past Ablaut (V -> Vpst)", .input = .V, .output = .V, .combiner = ablautPast };
};

fn pluralAllomorph(allocator: std.mem.Allocator, stem: []const u8) ![]const u8 {
    _ = allocator;
    const suf = Phono.pluralSuffixFor(stem);
    return suf;
}

// Additional process combiners
fn redupFirstCV(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    // Duplicate from start up to and including first vowel (crudely).
    var i: usize = 0;
    while (i < stem.len) : (i += 1) {
        const ch = std.ascii.toLower(stem[i]);
        const is_vowel = ch == 'a' or ch == 'e' or ch == 'i' or ch == 'o' or ch == 'u';
        if (is_vowel) {
            const piece = stem[0 .. i + 1];
            const pre = try concat2(allocator, piece, stem);
            return pre;
        }
    }
    // If no vowel found, return stem duplicated entirely.
    return try concat2(allocator, stem, stem);
}

fn stressToVerb(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    // Represent stress by capitalizing the last syllable (very crude proxy).
    _ = allocator;
    if (stem.len < 2) return try concat2(std.heap.page_allocator, stem, "");
    var out = try std.heap.page_allocator.dupe(u8, stem);
    defer std.heap.page_allocator.free(out);
    // Capitalize last 3 letters as a proxy for final stress.
    const n = if (out.len >= 3) 3 else out.len;
    var i: usize = out.len - n;
    while (i < out.len) : (i += 1) out[i] = std.ascii.toUpper(out[i]);
    return try std.heap.page_allocator.dupe(u8, out);
}

fn stressToNoun(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    // Capitalize first 3 letters as a proxy for initial stress.
    _ = allocator;
    if (stem.len == 0) return try concat2(std.heap.page_allocator, stem, "");
    var out = try std.heap.page_allocator.dupe(u8, stem);
    defer std.heap.page_allocator.free(out);
    const n = if (out.len >= 3) 3 else out.len;
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = std.ascii.toUpper(out[i]);
    return try std.heap.page_allocator.dupe(u8, out);
}

fn ablautPast(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    _ = allocator;
    // Lexicon first
    const pairs = [_]IrregularPair{
        .{ .singular = "sing", .plural = "sang" },
        .{ .singular = "ring", .plural = "rang" },
        .{ .singular = "drink", .plural = "drank" },
        .{ .singular = "begin", .plural = "began" },
        .{ .singular = "swim", .plural = "swam" },
        .{ .singular = "sink", .plural = "sank" },
        .{ .singular = "spring", .plural = "sprang" },
        .{ .singular = "shrink", .plural = "shrank" },
    };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(stem, p.singular))
            return try std.heap.page_allocator.dupe(u8, p.plural);
    }
    // Overgeneralization pattern: -ing -> -ang
    if (stem.len >= 3 and std.mem.eql(u8, stem[stem.len - 3 ..], "ing")) {
        var out = try std.heap.page_allocator.dupe(u8, stem);
        defer std.heap.page_allocator.free(out);
        out[stem.len - 3] = 'a';
        return try std.heap.page_allocator.dupe(u8, out);
    }
    return try std.heap.page_allocator.dupe(u8, stem);
}

// Helpers to build classic examples from slides
// Rules-vs-Storage config for past tense (small demo)
pub const RulesVsStorageConfig = struct {
    // If true, stored past forms take precedence when present
    prefer_stored: bool = true,
    store_past: []const IrregularPair = &.{
        .{ .singular = "go", .plural = "went" },
        .{ .singular = "begin", .plural = "began" },
        .{ .singular = "swim", .plural = "swam" },
        .{ .singular = "do", .plural = "did" },
        .{ .singular = "have", .plural = "had" },
    }, // reuse fields; singular=lemma, plural=stored past
};

pub fn derivePastV(cfg: RulesVsStorageConfig, allocator: std.mem.Allocator, v: *Node) !*Node {
    if (v.category != .V) return MorphError.NotApplicable;
    // check storage
    var found: ?[]const u8 = null;
    var i: usize = 0;
    while (i < cfg.store_past.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(v.token, cfg.store_past[i].singular)) {
            found = cfg.store_past[i].plural;
            break;
        }
    }
    if (cfg.prefer_stored and found != null)
        return try newRoot(allocator, found.?, .V);
    // else apply rule
    const derived = try Rules.PastAblaut.apply(allocator, v);
    if (!cfg.prefer_stored and found != null) {
        // prefer rule even when stored exists; ignore storage
        return derived;
    }
    return derived;
}

pub fn comparativeWithSession(sess: MorphSession, allocator: std.mem.Allocator, adj: *Node, superlative: bool) !*Node {
    if (adj.category != .Adj) return MorphError.NotApplicable;

    // Morphological exceptions by lexicon
    var i: usize = 0;
    while (i < sess.morphological_adjectives.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(adj.token, sess.morphological_adjectives[i])) {
            return if (superlative) try Rules.Adj_to_Adj_est.apply(allocator, adj) else try Rules.Adj_to_Adj_er.apply(allocator, adj);
        }
    }

    // Periphrastic exceptions by lexicon
    i = 0;
    while (i < sess.periphrastic_adjectives.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(adj.token, sess.periphrastic_adjectives[i])) {
            const prefix = if (superlative) "most " else "more ";
            const tok = try concat2(allocator, prefix, adj.token);
            const node = try allocator.create(Node);
            node.* = .{ .token = tok, .category = .Adj, .rule = if (superlative) "periphrastic-most" else "periphrastic-more", .left = adj, .right = null, .source = .Derived };
            return node;
        }
    }

    // Heuristic: polysyllabic adjectives prefer periphrastic
    if (sess.prefer_periphrastic_if_polysyllabic and !approxMonosyllabic(adj.token)) {
        const prefix = if (superlative) "most " else "more ";
        const tok = try concat2(allocator, prefix, adj.token);
        const node = try allocator.create(Node);
        node.* = .{ .token = tok, .category = .Adj, .rule = if (superlative) "periphrastic-most" else "periphrastic-more", .left = adj, .right = null, .source = .Derived };
        return node;
    }

    // Default choice controlled by session
    if (sess.prefer_morphological_comparative_default) {
        return if (superlative) try Rules.Adj_to_Adj_est.apply(allocator, adj) else try Rules.Adj_to_Adj_er.apply(allocator, adj);
    } else {
        const prefix = if (superlative) "most " else "more ";
        const tok = try concat2(allocator, prefix, adj.token);
        const node = try allocator.create(Node);
        node.* = .{ .token = tok, .category = .Adj, .rule = if (superlative) "periphrastic-most" else "periphrastic-more", .left = adj, .right = null, .source = .Derived };
        return node;
    }
}

pub fn buildGenitive(sess: MorphSession, allocator: std.mem.Allocator, owner_det: []const u8, owner_adjs: []const []const u8, owner_n: []const u8, owned_det: []const u8, owned_adjs: []const []const u8, owned_n: []const u8, owner_is_plural: bool) ![]u8 {
    if (!syntax.validateNP(owner_det, owner_adjs, owner_n) or !syntax.validateNP(owned_det, owned_adjs, owned_n)) return error.Ungrammatical;
    if (sess.prefer_of_phrase_for_possessive) {
        const left = try std.mem.concat(allocator, u8, &.{ owner_det, " ", owner_n });
        defer allocator.free(left);
        const right = try std.mem.concat(allocator, u8, &.{ owned_det, " ", owned_n });
        defer allocator.free(right);
        // Capitalize first token of sentence
        var cap_det = try allocator.dupe(u8, owned_det);
        if (cap_det.len > 0) cap_det[0] = std.ascii.toUpper(cap_det[0]);
        defer allocator.free(cap_det);
        const body = try std.mem.concat(allocator, u8, &.{ cap_det, " ", owned_n, " of ", owner_det, " ", owner_n });
        defer allocator.free(body);
        return try std.mem.concat(allocator, u8, &.{ body, "." });
    } else {
        // Decide possessive suffix: plural owners ending with 's' take just apostrophe
        const ends_with_s = owner_n.len > 0 and std.ascii.toLower(owner_n[owner_n.len - 1]) == 's';
        const suffix = if (owner_is_plural and ends_with_s) "'" else "'s";
        const owner = try std.mem.concat(allocator, u8, &.{ owner_det, " ", owner_n, suffix });
        defer allocator.free(owner);
        var cap_owner = try allocator.dupe(u8, owner);
        if (cap_owner.len > 0) cap_owner[0] = std.ascii.toUpper(cap_owner[0]);
        defer allocator.free(cap_owner);
        const body = try std.mem.concat(allocator, u8, &.{ cap_owner, " ", owned_n });
        defer allocator.free(body);
        return try std.mem.concat(allocator, u8, &.{ body, "." });
    }
}

pub fn buildGenitiveAutoPlural(sess: MorphSession, allocator: std.mem.Allocator, owner_det: []const u8, owner_adjs: []const []const u8, owner_n: []const u8, owned_det: []const u8, owned_adjs: []const []const u8, owned_n: []const u8) ![]u8 {
    const plural = isPluralNoun(owner_n);
    return try buildGenitive(sess, allocator, owner_det, owner_adjs, owner_n, owned_det, owned_adjs, owned_n, plural);
}

pub const Examples = struct {
    pub fn derive_readable(allocator: std.mem.Allocator) !*Node {
        const root = try newRoot(allocator, "read", .V);
        return try Rules.V_to_Adj_able.apply(allocator, root);
    }

    pub fn derive_hostility(allocator: std.mem.Allocator) !*Node {
        const root = try newRoot(allocator, "hostile", .Adj);
        return try Rules.Adj_to_N_ity.apply(allocator, root);
    }

    pub fn derive_unhappiness(allocator: std.mem.Allocator) !*Node {
        const happy = try newRoot(allocator, "happy", .Adj);
        const un_adj = try Rules.Un_not_Adj.apply(allocator, happy);
        return try Rules.Adj_to_N_ness.apply(allocator, un_adj);
    }

    pub fn derive_unlockable_ambiguous(allocator: std.mem.Allocator) !struct { not_able_locked: *Node, able_unlocked: *Node } {
        // not [able to be [locked]]
        const lock_v = try newRoot(allocator, "lock", .V);
        const lockable = try Rules.V_to_Adj_able.apply(allocator, lock_v);
        const not_lockable = try Rules.Un_not_Adj.apply(allocator, lockable);

        // able to be [un-[locked]]
        const lock_v2 = try newRoot(allocator, "lock", .V);
        const unlock_v = try Rules.Un_reverse_V.apply(allocator, lock_v2);
        const unlockable = try Rules.V_to_Adj_able.apply(allocator, unlock_v);

        return .{ .not_able_locked = not_lockable, .able_unlocked = unlockable };
    }
};

// Tests
test "V + -able -> Adj (readable)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try Examples.derive_readable(alloc);
    try std.testing.expectEqualStrings("readable", node.token);
    try std.testing.expectEqual(@intFromEnum(Category.Adj), @intFromEnum(node.category));
}

test "Adj + -ity -> N (hostility)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try Examples.derive_hostility(alloc);
    try std.testing.expectEqualStrings("hostility", node.token);
    try std.testing.expectEqual(@intFromEnum(Category.N), @intFromEnum(node.category));
}

test "unhappiness correct branching (un- attaches to Adj)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try Examples.derive_unhappiness(alloc);
    try std.testing.expectEqualStrings("unhappiness", node.token);
    try std.testing.expectEqual(@intFromEnum(Category.N), @intFromEnum(node.category));
}

test "unlockable ambiguity: both structures exist" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const both = try Examples.derive_unlockable_ambiguous(alloc);
    try std.testing.expectEqualStrings("unlockable", both.not_able_locked.token);
    try std.testing.expectEqualStrings("unlockable", both.able_unlocked.token);
}

test "plural -s allomorphy (cats vs. dogz)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cat_n = try newRoot(alloc, "cat", .N);
    const cats = try Rules.N_plural_s.apply(alloc, cat_n);
    try std.testing.expectEqualStrings("cats", cats.token);

    const dog_n = try newRoot(alloc, "dog", .N);
    const dogz = try Rules.N_plural_s.apply(alloc, dog_n);
    try std.testing.expectEqualStrings("dogz", dogz.token);
}

test "Day3 practice: spiteful/unsure/stoppable" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    // spiteful: N + -ful -> Adj
    const spite = try newRoot(A, "spite", .N);
    const spiteful = try Rules.N_to_Adj_ful.apply(A, spite);
    try std.testing.expectEqualStrings("spiteful", spiteful.token);
    try std.testing.expectEqual(@intFromEnum(Category.Adj), @intFromEnum(spiteful.category));

    // unsure: un- + Adj -> Adj
    const sure = try newRoot(A, "sure", .Adj);
    const unsure = try Rules.Un_not_Adj.apply(A, sure);
    try std.testing.expectEqualStrings("unsure", unsure.token);

    // stoppable: V + -able -> Adj
    const stop = try newRoot(A, "stop", .V);
    const stoppable = try Rules.V_to_Adj_able.apply(A, stop);
    try std.testing.expectEqualStrings("stoppable", stoppable.token);
}

test "Adj/N + -en -> V with allow list; ungrammatical others" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const white = try newRoot(A, "white", .Adj);
    const whiten = try Rules.Adj_to_V_en.apply(A, white);
    try std.testing.expectEqualStrings("whiten", whiten.token);
    try std.testing.expectEqual(@intFromEnum(Category.V), @intFromEnum(whiten.category));

    const quick = try newRoot(A, "quick", .Adj);
    const quicken = try Rules.Adj_to_V_en.apply(A, quick);
    try std.testing.expectEqualStrings("quicken", quicken.token);

    const black = try newRoot(A, "black", .Adj);
    const blacken = try Rules.Adj_to_V_en.apply(A, black);
    try std.testing.expectEqualStrings("blacken", blacken.token);

    const red = try newRoot(A, "red", .Adj);
    const redden = try Rules.Adj_to_V_en.apply(A, red);
    try std.testing.expectEqualStrings("redden", redden.token);

    const wide = try newRoot(A, "wide", .Adj);
    const widen = try Rules.Adj_to_V_en.apply(A, wide);
    try std.testing.expectEqualStrings("widen", widen.token);

    const sharp = try newRoot(A, "sharp", .Adj);
    const sharpen = try Rules.Adj_to_V_en.apply(A, sharp);
    try std.testing.expectEqualStrings("sharpen", sharpen.token);

    const soft = try newRoot(A, "soft", .Adj);
    const soften = try Rules.Adj_to_V_en.apply(A, soft);
    try std.testing.expectEqualStrings("soften", soften.token);

    const mad = try newRoot(A, "mad", .Adj);
    const madden = try Rules.Adj_to_V_en.apply(A, mad);
    try std.testing.expectEqualStrings("madden", madden.token);

    const glad = try newRoot(A, "glad", .Adj);
    const gladden = try Rules.Adj_to_V_en.apply(A, glad);
    try std.testing.expectEqualStrings("gladden", gladden.token);

    const slow = try newRoot(A, "slow", .Adj);
    try std.testing.expectError(MorphError.NotApplicable, Rules.Adj_to_V_en.apply(A, slow));

    // N + -en -> V
    const length = try newRoot(A, "length", .N);
    const lengthen = try Rules.N_to_V_en.apply(A, length);
    try std.testing.expectEqualStrings("lengthen", lengthen.token);

    const board = try newRoot(A, "board", .Adj);
    try std.testing.expectError(MorphError.NotApplicable, Rules.Adj_to_V_en.apply(A, board));
}

test "mismanagement, nonrefundable, and new suffixes (-less, -ish, -ation, -al, -ance, -ize, -ify)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    // mismanagement = mis- + manage + -ment
    const manage = try newRoot(A, "manage", .V);
    const mismanage = try Rules.Mis_V.apply(A, manage);
    const mismanagement = try Rules.V_to_N_ment.apply(A, mismanage);
    try std.testing.expectEqualStrings("mismanagement", mismanagement.token);
    try std.testing.expectEqual(@intFromEnum(Category.N), @intFromEnum(mismanagement.category));

    // nonrefundable = non- + (refund + -able)
    const refund = try newRoot(A, "refund", .V);
    const refundable = try Rules.V_to_Adj_able.apply(A, refund);
    const nonrefundable = try Rules.Non_not_Adj.apply(A, refundable);
    try std.testing.expectEqualStrings("nonrefundable", nonrefundable.token);

    // fearless = fear + -less
    const fear = try newRoot(A, "fear", .N);
    const fearless = try Rules.N_to_Adj_less.apply(A, fear);
    try std.testing.expectEqualStrings("fearless", fearless.token);
    try std.testing.expectEqual(@intFromEnum(Category.Adj), @intFromEnum(fearless.category));

    // childish = child + -ish
    const childn = try newRoot(A, "child", .N);
    const childish = try Rules.N_to_Adj_ish.apply(A, childn);
    try std.testing.expectEqualStrings("childish", childish.token);

    // greenish = green + -ish (Adj)
    const green = try newRoot(A, "green", .Adj);
    const greenish = try Rules.Adj_to_Adj_ish.apply(A, green);
    try std.testing.expectEqualStrings("greenish", greenish.token);

    // information = inform + -ation
    const inform_v = try newRoot(A, "inform", .V);
    const information = try Rules.V_to_N_ation.apply(A, inform_v);
    try std.testing.expectEqualStrings("information", information.token);

    // arrival = arrive + -al (e-drop)
    const arrive_v = try newRoot(A, "arrive", .V);
    const arrival = try Rules.V_to_N_al.apply(A, arrive_v);
    try std.testing.expectEqualStrings("arrival", arrival.token);

    // reliance = rely + -ance (y->i)
    const rely_v = try newRoot(A, "rely", .V);
    const reliance = try Rules.V_to_N_ance.apply(A, rely_v);
    try std.testing.expectEqualStrings("reliance", reliance.token);

    // atomize = atom + -ize; modernize = modern + -ize
    const atom = try newRoot(A, "atom", .N);
    const atomize = try Rules.N_to_V_ize.apply(A, atom);
    try std.testing.expectEqualStrings("atomize", atomize.token);
    const modern = try newRoot(A, "modern", .Adj);
    const modernize = try Rules.Adj_to_V_ize.apply(A, modern);
    try std.testing.expectEqualStrings("modernize", modernize.token);

    // glorify = glory + -ify (drop y); purify = pure + -ify (drop e)
    const glory = try newRoot(A, "glory", .N);
    const glorify = try Rules.N_to_V_ify.apply(A, glory);
    try std.testing.expectEqualStrings("glorify", glorify.token);
    const pure_adj = try newRoot(A, "pure", .Adj);
    const purify = try Rules.Adj_to_V_ify.apply(A, pure_adj);
    try std.testing.expectEqualStrings("purify", purify.token);
}

test "ungrammatical evidence checks for rule/category mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    // *un- + N -> N (not allowed in our rule set)
    const desk = try newRoot(A, "desk", .N);
    try std.testing.expectError(MorphError.NotApplicable, Rules.Un_not_Adj.apply(A, desk));

    // *un-(reverse) + Adj -> Adj (not allowed)
    const tidy = try newRoot(A, "tidy", .Adj);
    try std.testing.expectError(MorphError.NotApplicable, Rules.Un_reverse_V.apply(A, tidy));

    // *N + -ful -> Adj applied to V should be NotApplicable
    const swim = try newRoot(A, "swim", .V);
    try std.testing.expectError(MorphError.NotApplicable, Rules.N_to_Adj_ful.apply(A, swim));
}

test "rules-vs-storage toggle for past tense (go->went stored; ring->rang derived)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const cfg = RulesVsStorageConfig{};
    const go = try newRoot(A, "go", .V);
    const went = try derivePastV(cfg, A, go);
    try std.testing.expectEqualStrings("went", went.token);

    const ring = try newRoot(A, "ring", .V);
    const rang = try derivePastV(cfg, A, ring);
    try std.testing.expectEqualStrings("rang", rang.token);
}

test "irregular plural blocking via lexicon (children, feet, mice, teeth)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();
    const cfg = MorphConfig{};

    const child = try newRoot(A, "child", .N);
    const children = try pluralizeN(cfg, A, child);
    try std.testing.expectEqualStrings("children", children.token);

    const foot = try newRoot(A, "foot", .N);
    const feet = try pluralizeN(cfg, A, foot);
    try std.testing.expectEqualStrings("feet", feet.token);

    const mouse = try newRoot(A, "mouse", .N);
    const mice = try pluralizeN(cfg, A, mouse);
    try std.testing.expectEqualStrings("mice", mice.token);

    const tooth = try newRoot(A, "tooth", .N);
    const teeth = try pluralizeN(cfg, A, tooth);
    try std.testing.expectEqualStrings("teeth", teeth.token);
}

test "isPluralNoun helper and genitive auto-plural" {
    try std.testing.expect(isPluralNoun("children"));
    try std.testing.expect(isPluralNoun("dogz"));
    try std.testing.expect(!isPluralNoun("dog"));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();
    const sess = MorphSession{};
    const s1 = try buildGenitiveAutoPlural(sess, A, "the", &.{}, "dogs", "the", &.{}, "bone");
    try std.testing.expectEqualStrings("The dogs' bone.", s1);
}

test "comparative/superlative and possessive tests" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const fast = try newRoot(A, "fast", .Adj);
    const faster = try Rules.Adj_to_Adj_er.apply(A, fast);
    try std.testing.expectEqualStrings("faster", faster.token);
    const fastest = try Rules.Adj_to_Adj_est.apply(A, fast);
    try std.testing.expectEqualStrings("fastest", fastest.token);

    const happy = try newRoot(A, "happy", .Adj);
    const happier = try Rules.Adj_to_Adj_er.apply(A, happy);
    const happiest = try Rules.Adj_to_Adj_est.apply(A, happy);
    try std.testing.expectEqualStrings("happier", happier.token);
    try std.testing.expectEqualStrings("happiest", happiest.token);

    const dog = try newRoot(A, "dog", .N);
    const dogs = try Rules.N_plural_s.apply(A, dog);
    try std.testing.expectEqualStrings("dogz", dogs.token);
    const dogs_poss = try Rules.N_possessive_s.apply(A, dogs);
    try std.testing.expectEqualStrings("dogz's", dogs_poss.token);
}

test "comparative periphrastic exceptions (fun -> more/most fun) and doubling (big)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const sess = MorphSession{ .periphrastic_adjectives = &.{ "fun" } };
    const fun = try newRoot(A, "fun", .Adj);
    const more_fun = try comparativeWithSession(sess, A, fun, false);
    try std.testing.expectEqualStrings("more fun", more_fun.token);
    const most_fun = try comparativeWithSession(sess, A, fun, true);
    try std.testing.expectEqualStrings("most fun", most_fun.token);

    // Doubling example: big -> bigger/biggest
    const big = try newRoot(A, "big", .Adj);
    const bigger = try Rules.Adj_to_Adj_er.apply(A, big);
    const biggest = try Rules.Adj_to_Adj_est.apply(A, big);
    try std.testing.expectEqualStrings("bigger", bigger.token);
    try std.testing.expectEqualStrings("biggest", biggest.token);
}

test "periphrastic heuristic toggle (likely: morphological when heuristic off)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const sess = MorphSession{ .periphrastic_adjectives = &.{}, .prefer_periphrastic_if_polysyllabic = false };
    const likely = try newRoot(A, "likely", .Adj);
    const likelier = try comparativeWithSession(sess, A, likely, false);
    try std.testing.expectEqualStrings("likelier", likelier.token);
}

test "stored past frequency examples (swim->swam, do->did, have->had stored)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const cfg = RulesVsStorageConfig{};

    const swim = try newRoot(A, "swim", .V);
    const swam = try derivePastV(cfg, A, swim);
    try std.testing.expectEqualStrings("swam", swam.token);
    try std.testing.expectEqual(@intFromEnum(Source.Stored), @intFromEnum(swam.source));

    const do_ = try newRoot(A, "do", .V);
    const did = try derivePastV(cfg, A, do_);
    try std.testing.expectEqualStrings("did", did.token);
    try std.testing.expectEqual(@intFromEnum(Source.Stored), @intFromEnum(did.source));

    const have = try newRoot(A, "have", .V);
    const had = try derivePastV(cfg, A, have);
    try std.testing.expectEqualStrings("had", had.token);
    try std.testing.expectEqual(@intFromEnum(Source.Stored), @intFromEnum(had.source));
}

test "reduplication process examples (takbuh->tatakbuh, lakad->lalakad)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const takbuh = try newRoot(A, "takbuh", .V);
    const tatakbuh = try Rules.Redup_V.apply(A, takbuh);
    try std.testing.expectEqualStrings("tatakbuh", tatakbuh.token);

    const lakad = try newRoot(A, "lakad", .V);
    const lalakad = try Rules.Redup_V.apply(A, lakad);
    try std.testing.expectEqualStrings("lalakad", lalakad.token);
}

test "stress shift representation (permit)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const permit_n = try newRoot(A, "permit", .N);
    const permit_v = try Rules.StressToVerb.apply(A, permit_n);
    try std.testing.expectEqualStrings("perMIT", permit_v.token);
    try std.testing.expectEqual(@intFromEnum(Category.V), @intFromEnum(permit_v.category));

    const permit_v2 = try newRoot(A, "permit", .V);
    const permit_n2 = try Rules.StressToNoun.apply(A, permit_v2);
    try std.testing.expectEqualStrings("PERmit", permit_n2.token);
    try std.testing.expectEqual(@intFromEnum(Category.N), @intFromEnum(permit_n2.category));
}

test "ablaut past (sing->sang, ring->rang, sink->sank, shrink->shrank, spring->sprang) and overgeneralization (bring->brang)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const sing = try newRoot(A, "sing", .V);
    const sang = try Rules.PastAblaut.apply(A, sing);
    try std.testing.expectEqualStrings("sang", sang.token);

    const ring = try newRoot(A, "ring", .V);
    const rang = try Rules.PastAblaut.apply(A, ring);
    try std.testing.expectEqualStrings("rang", rang.token);

    const sink = try newRoot(A, "sink", .V);
    const sank = try Rules.PastAblaut.apply(A, sink);
    try std.testing.expectEqualStrings("sank", sank.token);

    const shrink = try newRoot(A, "shrink", .V);
    const shrank = try Rules.PastAblaut.apply(A, shrink);
    try std.testing.expectEqualStrings("shrank", shrank.token);

    const spring = try newRoot(A, "spring", .V);
    const sprang = try Rules.PastAblaut.apply(A, spring);
    try std.testing.expectEqualStrings("sprang", sprang.token);

    const bring = try newRoot(A, "bring", .V);
    const brang = try Rules.PastAblaut.apply(A, bring);
    try std.testing.expectEqualStrings("brang", brang.token);
}
