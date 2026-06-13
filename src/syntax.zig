const std = @import("std");
const Category = @import("categories.zig").Category;

// Minimal distributional tests based on Day 3 – Syntactic Categories
pub fn canTakeDeterminer(cat: Category) bool {
    return cat == .N;
}

pub fn canFollowAuxiliary(cat: Category) bool {
    return cat == .V;
}

pub fn modifiableByDegree(cat: Category) bool {
    return cat == .Adj or cat == .Adv;
}

pub fn canAppearBetweenDetAndN(cat: Category) bool {
    return cat == .Adj;
}

pub fn advPositionVariety(cat: Category) struct { initial: bool, preverbal: bool, postverbal: bool, final: bool } {
    if (cat == .Adv) return .{ .initial = true, .preverbal = true, .postverbal = true, .final = true };
    return .{ .initial = false, .preverbal = false, .postverbal = false, .final = false };
}

pub const SyntaxError = error{Ungrammatical};

pub const DiagCode = enum {
    BadDeterminer,
    NonAlphabeticN,
    NonAlphabeticAdj,
    BadPreposition,
    UnknownAux,
    NonAlphabeticV,
    NonAlphabeticAdv,
};

pub const Diagnostics = struct {
    pub const Message = struct { code: DiagCode, text: []const u8, pos: ?usize = null };
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator, .messages = std.ArrayList(Message).empty };
    }

    pub fn deinit(self: *Diagnostics) void {
        var i: usize = 0;
        while (i < self.messages.items.len) : (i += 1) self.allocator.free(self.messages.items[i].text);
        self.messages.deinit(self.allocator);
    }

    pub fn addCode(self: *Diagnostics, code: DiagCode, msg: []const u8, pos: ?usize) !void {
        const dup = try self.allocator.dupe(u8, msg);
        try self.messages.append(self.allocator, .{ .code = code, .text = dup, .pos = pos });
    }
};

pub const PP = struct { p: []const u8, det: []const u8, adjs: []const []const u8, n: []const u8 };

fn isAlphabeticWord(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isAlphabetic(ch)) return false;
    return true;
}

pub fn validateNP(det: []const u8, adjs: []const []const u8, n: []const u8) bool {
    return validateNPWithDiagInternal(null, det, adjs, n);
}

fn validateNPWithDiagInternal(diag: ?*Diagnostics, det: []const u8, adjs: []const []const u8, n: []const u8) bool {
    const dets = [_][]const u8{ "the", "a", "this", "that", "these", "those", "my", "your" };
    var ok_det = false;
    for (dets) |d| {
        if (std.ascii.eqlIgnoreCase(det, d)) { ok_det = true; break; }
    }
    if (!ok_det) {
        if (diag) |d| d.addCode(.BadDeterminer, "Bad determiner", null) catch {};
        return false;
    }
    if (!isAlphabeticWord(n)) {
        if (diag) |d| d.addCode(.NonAlphabeticN, "N head must be alphabetic", null) catch {};
        return false;
    }
    for (adjs) |a| {
        if (!isAlphabeticWord(a)) {
            if (diag) |d| d.addCode(.NonAlphabeticAdj, "Adj must be alphabetic", null) catch {};
            return false;
        }
    }
    return true;
}

pub fn validateNPWithDiag(allocator: std.mem.Allocator, det: []const u8, adjs: []const []const u8, n: []const u8, diag: *Diagnostics) bool {
    _ = allocator; // reserved for future
    return validateNPWithDiagInternal(diag, det, adjs, n);
}

pub fn validatePP(p: []const u8, det: []const u8, adjs: []const []const u8, n: []const u8) bool {
    return validatePPWithDiagInternal(null, p, det, adjs, n);
}

fn validatePPWithDiagInternal(diag: ?*Diagnostics, p: []const u8, det: []const u8, adjs: []const []const u8, n: []const u8) bool {
    const preps = [_][]const u8{ "in", "on", "at", "with", "by", "for", "from", "to", "of" };
    var ok_p = false;
    for (preps) |pp| { if (std.ascii.eqlIgnoreCase(p, pp)) { ok_p = true; break; } }
    if (!ok_p) {
        if (diag) |d| d.addCode(.BadPreposition, "Bad preposition", null) catch {};
        return false;
    }
    return validateNPWithDiagInternal(diag, det, adjs, n);
}

pub fn validatePPWithDiag(allocator: std.mem.Allocator, p: []const u8, det: []const u8, adjs: []const []const u8, n: []const u8, diag: *Diagnostics) bool {
    _ = allocator;
    return validatePPWithDiagInternal(diag, p, det, adjs, n);
}

pub fn validateNPWithPPs(det: []const u8, adjs: []const []const u8, n: []const u8, pps: []const PP) bool {
    if (!validateNP(det, adjs, n)) return false;
    var i: usize = 0;
    while (i < pps.len) : (i += 1) {
        const pp = pps[i];
        if (!validatePP(pp.p, pp.det, pp.adjs, pp.n)) return false;
    }
    return true;
}

pub fn validateCoordinatedNP(det1: []const u8, adjs1: []const []const u8, n1: []const u8, conj: []const u8, det2: []const u8, adjs2: []const []const u8, n2: []const u8) bool {
    const conjs = [_][]const u8{ "and", "or" };
    var ok_conj = false;
    for (conjs) |c| { if (std.ascii.eqlIgnoreCase(conj, c)) { ok_conj = true; break; } }
    if (!ok_conj) return false;
    return validateNP(det1, adjs1, n1) and validateNP(det2, adjs2, n2);
}

pub fn validateClauseSingleNP(det: []const u8, adjs: []const []const u8, n: []const u8, auxes: []const []const u8, v: []const u8, advs: []const []const u8, vpps: []const PP) bool {
    return validateClauseSingleNPWithDiagInternal(null, det, adjs, n, auxes, v, advs, vpps);
}

fn validateClauseSingleNPWithDiagInternal(diag: ?*Diagnostics, det: []const u8, adjs: []const []const u8, n: []const u8, auxes: []const []const u8, v: []const u8, advs: []const []const u8, vpps: []const PP) bool {
    if (!validateNPWithDiagInternal(diag, det, adjs, n)) return false;
    const aux_set = [_][]const u8{ "may", "might", "will", "can", "should", "would" };
    for (auxes) |a| {
        var ok = false;
        for (aux_set) |b| {
            if (std.ascii.eqlIgnoreCase(a, b)) { ok = true; break; }
        }
        if (!ok) {
            if (diag) |d| d.addCode(.UnknownAux, "Unknown auxiliary", null) catch {};
            return false;
        }
    }
    if (!isAlphabeticWord(v)) {
        if (diag) |d| d.addCode(.NonAlphabeticV, "Verb must be alphabetic", null) catch {};
        return false;
    }
    for (advs) |adv| {
        if (!isAlphabeticWord(adv)) {
            if (diag) |d| d.addCode(.NonAlphabeticAdv, "Adverb must be alphabetic", null) catch {};
            return false;
        }
    }
    // VP-attached PPs
    var i: usize = 0;
    while (i < vpps.len) : (i += 1) {
        const pp = vpps[i];
        if (!validatePPWithDiagInternal(diag, pp.p, pp.det, pp.adjs, pp.n)) return false;
    }
    return true;
}

pub fn validateClauseSingleNPWithDiag(allocator: std.mem.Allocator, det: []const u8, adjs: []const []const u8, n: []const u8, auxes: []const []const u8, v: []const u8, advs: []const []const u8, vpps: []const PP, diag: *Diagnostics) bool {
    _ = allocator;
    return validateClauseSingleNPWithDiagInternal(diag, det, adjs, n, auxes, v, advs, vpps);
}

pub fn isGrammaticalDetAdjN(det: []const u8, adj: []const u8, n: []const u8) bool {
    // Treat empty adj as no adjective
    if (adj.len == 0) return validateNP(det, &.{}, n);
    return validateNP(det, &.{ adj }, n);
}

pub fn isGrammaticalAuxV(subj: []const u8, aux: []const u8, v: []const u8) bool {
    _ = subj;
    return validateClauseSingleNP("the", &.{}, "np", &.{ aux }, v, &.{}, &.{});
}

fn capitalizeFirst(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return allocator.dupe(u8, s);
    var out = try allocator.dupe(u8, s);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub fn buildPPWithDiag(allocator: std.mem.Allocator, p: []const u8, det: []const u8, adjs: []const []const u8, n: []const u8, diag: *Diagnostics) ![]u8 {
    if (!validatePPWithDiag(allocator, p, det, adjs, n, diag)) return SyntaxError.Ungrammatical;
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, p);
    try parts.append(allocator, det);
    for (adjs) |a| try parts.append(allocator, a);
    try parts.append(allocator, n);
    const body = try std.mem.join(allocator, " ", parts.items);
    return body;
}

pub fn buildPP(allocator: std.mem.Allocator, p: []const u8, det: []const u8, adjs: []const []const u8, n: []const u8) ![]u8 {
    if (!validatePP(p, det, adjs, n)) return SyntaxError.Ungrammatical;
    // p det adj* n
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, p);
    try parts.append(allocator, det);
    for (adjs) |a| try parts.append(allocator, a);
    try parts.append(allocator, n);
    const body = try std.mem.join(allocator, " ", parts.items);
    return body;
}

pub fn buildNPStringWithDiag(allocator: std.mem.Allocator, capitalize: bool, det: []const u8, adjs: []const []const u8, n: []const u8, pps: []const PP, diag: *Diagnostics) ![]u8 {
    if (!validateNPWithPPs(det, adjs, n, pps)) {
        // Re-run validation with diag to collect messages
        _ = validateNPWithDiag(allocator, det, adjs, n, diag);
        var i: usize = 0;
        while (i < pps.len) : (i += 1) _ = validatePPWithDiag(allocator, pps[i].p, pps[i].det, pps[i].adjs, pps[i].n, diag);
        return SyntaxError.Ungrammatical;
    }
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    var cap_buf: ?[]u8 = null;
    defer if (cap_buf) |buf| allocator.free(buf);
    if (capitalize) {
        cap_buf = try capitalizeFirst(allocator, det);
        try parts.append(allocator, cap_buf.?);
    } else {
        try parts.append(allocator, det);
    }
    for (adjs) |a| try parts.append(allocator, a);
    try parts.append(allocator, n);
    for (pps) |pp| {
        const pp_str = try buildPP(allocator, pp.p, pp.det, pp.adjs, pp.n);
        try parts.append(allocator, pp_str);
    }
    const body = try std.mem.join(allocator, " ", parts.items);
    return body;
}

pub fn buildNPString(allocator: std.mem.Allocator, capitalize: bool, det: []const u8, adjs: []const []const u8, n: []const u8, pps: []const PP) ![]u8 {
    if (!validateNPWithPPs(det, adjs, n, pps)) return SyntaxError.Ungrammatical;
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    var cap_buf: ?[]u8 = null;
    defer if (cap_buf) |buf| allocator.free(buf);
    if (capitalize) {
        cap_buf = try capitalizeFirst(allocator, det);
        try parts.append(allocator, cap_buf.?);
    } else {
        try parts.append(allocator, det);
    }
    for (adjs) |a| try parts.append(allocator, a);
    try parts.append(allocator, n);
    // Append PPs
    for (pps) |pp| {
        const pp_str = try buildPP(allocator, pp.p, pp.det, pp.adjs, pp.n);
        // add as separate item; sentence join will add spaces
        try parts.append(allocator, pp_str);
    }
    const body = try std.mem.join(allocator, " ", parts.items);
    return body;
}

pub fn buildDetAdjNSentence(allocator: std.mem.Allocator, det: []const u8, adj: []const u8, n: []const u8) ![]u8 {
    const body = try buildNPString(allocator, true, det, &.{ adj }, n, &.{});
    const sent = try std.mem.concat(allocator, u8, &.{ body, "." });
    allocator.free(body);
    return sent;
}

pub fn buildAuxSentence(allocator: std.mem.Allocator, subj: []const u8, auxes: []const []const u8, v: []const u8) ![]u8 {
    if (!isGrammaticalAuxV(subj, if (auxes.len > 0) auxes[0] else "", v)) return SyntaxError.Ungrammatical;
    const cap_subj = try capitalizeFirst(allocator, subj);
    defer allocator.free(cap_subj);
    // Join auxes with spaces
    var parts: [][]const u8 = try allocator.alloc([]const u8, 2 + auxes.len);
    defer allocator.free(parts);
    parts[0] = cap_subj;
    var i: usize = 0;
    while (i < auxes.len) : (i += 1) parts[1 + i] = auxes[i];
    parts[1 + auxes.len] = v;
    const tmp = try std.mem.join(allocator, " ", parts);
    const sent = try std.mem.concat(allocator, u8, &.{ tmp, "." });
    allocator.free(tmp);
    return sent;
}

pub fn buildClauseWithNPWithDiag(allocator: std.mem.Allocator, subj_det: []const u8, subj_adjs: []const []const u8, subj_n: []const u8, subj_pps: []const PP, auxes: []const []const u8, v: []const u8, advs: []const []const u8, vp_pps: []const PP, diag: *Diagnostics) ![]u8 {
    if (!validateClauseSingleNPWithDiag(allocator, subj_det, subj_adjs, subj_n, auxes, v, advs, vp_pps, diag)) return SyntaxError.Ungrammatical;
    const np = try buildNPStringWithDiag(allocator, true, subj_det, subj_adjs, subj_n, subj_pps, diag);
    defer allocator.free(np);
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, np);
    for (auxes) |a| try parts.append(allocator, a);
    try parts.append(allocator, v);
    for (advs) |adv| try parts.append(allocator, adv);
    for (vp_pps) |pp| {
        const pp_str = try buildPP(allocator, pp.p, pp.det, pp.adjs, pp.n);
        try parts.append(allocator, pp_str);
    }
    const body = try std.mem.join(allocator, " ", parts.items);
    const sent = try std.mem.concat(allocator, u8, &.{ body, "." });
    allocator.free(body);
    return sent;
}

pub fn buildClauseWithNP(allocator: std.mem.Allocator, subj_det: []const u8, subj_adjs: []const []const u8, subj_n: []const u8, subj_pps: []const PP, auxes: []const []const u8, v: []const u8, advs: []const []const u8, vp_pps: []const PP) ![]u8 {
    // Validate NP and Clause
    if (!validateNPWithPPs(subj_det, subj_adjs, subj_n, subj_pps)) return SyntaxError.Ungrammatical;
    if (!validateClauseSingleNP(subj_det, subj_adjs, subj_n, auxes, v, advs, vp_pps)) return SyntaxError.Ungrammatical;

    const np = try buildNPString(allocator, true, subj_det, subj_adjs, subj_n, subj_pps);
    defer allocator.free(np);

    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, np);
    for (auxes) |a| try parts.append(allocator, a);
    try parts.append(allocator, v);
    for (advs) |adv| try parts.append(allocator, adv);
    for (vp_pps) |pp| {
        const pp_str = try buildPP(allocator, pp.p, pp.det, pp.adjs, pp.n);
        try parts.append(allocator, pp_str);
    }
    const body = try std.mem.join(allocator, " ", parts.items);
    const sent = try std.mem.concat(allocator, u8, &.{ body, "." });
    allocator.free(body);
    return sent;
}

pub fn buildCoordinatedNP(allocator: std.mem.Allocator, det1: []const u8, adj1: ?[]const u8, n1: []const u8, conj: []const u8, det2: []const u8, n2: []const u8) ![]u8 {
    if (!isGrammaticalDetAdjN(det1, adj1 orelse "", n1)) return SyntaxError.Ungrammatical;
    if (!isGrammaticalDetAdjN(det2, "", n2)) return SyntaxError.Ungrammatical;
    const conjs = [_][]const u8{ "and", "or" };
    var ok = false;
    for (conjs) |c| {
        if (std.ascii.eqlIgnoreCase(conj, c)) { ok = true; break; }
    }
    if (!ok) return SyntaxError.Ungrammatical;

    const cap_det1 = try capitalizeFirst(allocator, det1);
    defer allocator.free(cap_det1);
    const left = if (adj1) |a| try std.mem.concat(allocator, u8, &.{ cap_det1, " ", a, " ", n1 }) else try std.mem.concat(allocator, u8, &.{ cap_det1, " ", n1 });
    defer allocator.free(left);
    const right = try std.mem.concat(allocator, u8, &.{ det2, " ", n2 });
    defer allocator.free(right);
    const joined = try std.mem.concat(allocator, u8, &.{ left, " ", conj, " ", right, "." });
    return joined;
}

test "distributional helpers reflect category properties" {
    try std.testing.expect(canTakeDeterminer(.N));
    try std.testing.expect(!canTakeDeterminer(.V));

    try std.testing.expect(canFollowAuxiliary(.V));
    try std.testing.expect(!canFollowAuxiliary(.N));

    try std.testing.expect(modifiableByDegree(.Adj));
    try std.testing.expect(modifiableByDegree(.Adv));
    try std.testing.expect(!modifiableByDegree(.N));
}

test "CFG NP with multiple Adjs and PP; Clause with Aux* and Adv*" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = arena.allocator();

    // NP: The very happy dog in the yard.
    try std.testing.expect(validateNP("the", &.{"very", "happy"}, "dog"));
    const ok_pp_np = validateNPWithPPs("the", &.{"very", "happy"}, "dog", &.{PP{ .p = "in", .det = "the", .adjs = &.{}, .n = "yard" }});
    try std.testing.expect(ok_pp_np);
    try std.testing.expect(validateCoordinatedNP("the", &.{"big"}, "dog", "and", "the", &.{}, "cat"));
    try std.testing.expect(validateClauseSingleNP("the", &.{"happy"}, "dog", &.{"may", "will"}, "walk", &.{"slowly"}, &.{}));
}

test "Adj between Det and N; Adv position variety" {
    // Adj between Det and N
    try std.testing.expect(canAppearBetweenDetAndN(.Adj));
    try std.testing.expect(!canAppearBetweenDetAndN(.N));

    // Adv can occur sentence-initial, pre/post-verbal, and sentence-final
    const pos = advPositionVariety(.Adv);
    try std.testing.expect(pos.initial and pos.preverbal and pos.postverbal and pos.final);

    // Toy string validators
    try std.testing.expect(isGrammaticalDetAdjN("The", "happy", "dog"));
    try std.testing.expect(isGrammaticalAuxV("She", "may", "walk"));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();
    const s1 = try buildDetAdjNSentence(A, "the", "happy", "dog");
    try std.testing.expectEqualStrings("The happy dog.", s1);
    const s2 = try buildAuxSentence(A, "they", &.{"might", "will"}, "walk");
    try std.testing.expectEqualStrings("They might will walk.", s2);

    const s3 = try buildCoordinatedNP(A, "the", "big", "dog", "and", "the", "cat");
    try std.testing.expectEqualStrings("The big dog and the cat.", s3);

    const clause = try buildClauseWithNP(A, "the", &.{"happy"}, "dog", &.{PP{ .p = "in", .det = "the", .adjs = &.{}, .n = "yard" }}, &.{"may", "will"}, "walk", &.{"slowly"}, &.{PP{ .p = "with", .det = "the", .adjs = &.{}, .n = "cat" }});
    try std.testing.expectEqualStrings("The happy dog in the yard may will walk slowly with the cat.", clause);
}

test "syntax diagnostics collect errors and builders wire diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const A = arena.allocator();

    var diag = Diagnostics.init(A);
    defer diag.deinit();

    // Bad determiner
    const np_ok = validateNPWithDiag(A, "zzz", &.{"happy"}, "dog", &diag);
    try std.testing.expect(!np_ok);
    try std.testing.expect(diag.messages.items.len >= 1);

    // Clear and test clause with unknown aux
    diag.deinit();
    diag = Diagnostics.init(A);
    const cl_ok = validateClauseSingleNPWithDiag(A, "the", &.{}, "dog", &.{"shall"}, "walk", &.{}, &.{}, &diag);
    try std.testing.expect(!cl_ok);
    try std.testing.expect(diag.messages.items.len >= 1);

    // Builder wires diagnostics: bad PP
    diag.deinit();
    diag = Diagnostics.init(A);
    const bad_pp = buildPPWithDiag(A, "under", "the", &.{}, "table", &diag);
    try std.testing.expectError(SyntaxError.Ungrammatical, bad_pp);
    try std.testing.expect(diag.messages.items.len >= 1);
}
