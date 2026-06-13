//! In-memory word-frequency table.
//!
//! Replaces the legacy mmap'd binary frequency-file format (and its v1/v2
//! loaders) from the source repo. That format was descoped during extraction:
//! it is the hardest Zig 0.16 Io migration (raw `std.posix.mmap`, zero-copy
//! pointers into mapped memory) and is superseded elsewhere by safetensors-zig.
//!
//! The analyzer's `FrequencyBased`/`Semantic` validation and its compound
//! detector consume a `FrequencyTable`: a `word -> count` map plus a
//! `stem -> base-word` reverse index. Build it from any slice/iterator of
//! `(word, count)` pairs, or from a simple `word<space>count` text file.

const std = @import("std");
const snowball = @import("stemmer").snowball;

pub const Entry = struct {
    word: []const u8,
    count: u32,
};

/// Owns duplicated copies of every word and stem key it stores; free with
/// `deinit`. Lookups never allocate.
pub const FrequencyTable = struct {
    allocator: std.mem.Allocator,
    counts: std.StringHashMap(u32),
    // Reverse index: stem -> shortest known base word that stems to it.
    // Example: "happi" -> "happy", "poni" -> "pony".
    stem_to_word: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) FrequencyTable {
        return .{
            .allocator = allocator,
            .counts = std.StringHashMap(u32).init(allocator),
            .stem_to_word = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FrequencyTable) void {
        var kit = self.counts.keyIterator();
        while (kit.next()) |k| self.allocator.free(k.*);
        self.counts.deinit();

        var sit = self.stem_to_word.keyIterator();
        while (sit.next()) |k| self.allocator.free(k.*);
        self.stem_to_word.deinit();
    }

    /// Insert or accumulate a single (word, count) pair. The word is copied.
    /// If the word already exists, counts are summed (matches a corpus where
    /// the same surface form may appear on multiple lines).
    pub fn put(self: *FrequencyTable, word: []const u8, count: u32) !void {
        const gop = try self.counts.getOrPut(word);
        if (gop.found_existing) {
            gop.value_ptr.* +|= count;
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, word);
            gop.value_ptr.* = count;
        }
    }

    /// Build a table from a slice of entries.
    pub fn fromSlice(allocator: std.mem.Allocator, entries: []const Entry) !FrequencyTable {
        var table = FrequencyTable.init(allocator);
        errdefer table.deinit();
        for (entries) |e| try table.put(e.word, e.count);
        try table.buildStemIndex();
        return table;
    }

    /// Load a table from a `word<space>count` text file (one entry per line).
    /// Blank lines and lines beginning with '#' are skipped. A line with a
    /// word but no parseable count is skipped.
    ///
    /// Uses straightforward Zig 0.16 file reading via `std.Io.Dir.cwd()`.
    pub fn fromTextFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !FrequencyTable {
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 << 20));
        defer allocator.free(contents);
        return fromText(allocator, contents);
    }

    /// Parse `word<space>count` text already in memory. Same line rules as
    /// `fromTextFile`. Exposed for tests and embedded corpora.
    pub fn fromText(allocator: std.mem.Allocator, contents: []const u8) !FrequencyTable {
        var table = FrequencyTable.init(allocator);
        errdefer table.deinit();

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const word = parts.next() orelse continue;
            const count_str = parts.next() orelse continue;
            const count = std.fmt.parseInt(u32, count_str, 10) catch continue;
            try table.put(word, count);
        }

        try table.buildStemIndex();
        return table;
    }

    /// (Re)build the stem -> base-word reverse index by Snowball-stemming every
    /// stored word. When several words share a stem, the shortest is kept (most
    /// likely the base form). Safe to call after a batch of `put`s.
    pub fn buildStemIndex(self: *FrequencyTable) !void {
        // Clear any existing index first.
        var existing = self.stem_to_word.keyIterator();
        while (existing.next()) |k| self.allocator.free(k.*);
        self.stem_to_word.clearRetainingCapacity();

        var it = self.counts.keyIterator();
        while (it.next()) |word_ptr| {
            const word = word_ptr.*;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var st = snowball.Stemmer.init(arena.allocator());
            const stem = st.stem(word) catch continue;

            if (std.mem.eql(u8, word, stem)) continue; // no meaningful stemming

            const gop = try self.stem_to_word.getOrPut(stem);
            if (gop.found_existing) {
                if (word.len < gop.value_ptr.*.len) {
                    gop.value_ptr.* = word; // points at a stable key in `counts`
                }
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, stem);
                gop.value_ptr.* = word;
            }
        }
    }

    pub fn get(self: *const FrequencyTable, word: []const u8) ?u32 {
        return self.counts.get(word);
    }

    pub fn contains(self: *const FrequencyTable, word: []const u8) bool {
        return self.counts.contains(word);
    }

    /// Return the stable key pointer for `word` if present (used by the
    /// analyzer's morphophonological corrections, which want a pointer that
    /// outlives a scratch buffer).
    pub fn getKey(self: *const FrequencyTable, word: []const u8) ?[]const u8 {
        return self.counts.getKey(word);
    }

    /// Reverse-index lookup: given a stem, return the shortest known base word.
    pub fn baseWordForStem(self: *const FrequencyTable, stem: []const u8) ?[]const u8 {
        return self.stem_to_word.get(stem);
    }

    pub fn len(self: *const FrequencyTable) u32 {
        return self.counts.count();
    }
};

test "FrequencyTable fromSlice and lookups" {
    var t = try FrequencyTable.fromSlice(std.testing.allocator, &.{
        .{ .word = "happy", .count = 100 },
        .{ .word = "fire", .count = 50 },
        .{ .word = "man", .count = 80 },
    });
    defer t.deinit();

    try std.testing.expectEqual(@as(?u32, 100), t.get("happy"));
    try std.testing.expect(t.contains("fire"));
    try std.testing.expect(!t.contains("absent"));
    try std.testing.expectEqual(@as(u32, 3), t.len());
}

test "FrequencyTable fromText skips comments and bad lines" {
    const text =
        \\# corpus
        \\happy 100
        \\fire 50
        \\garbage
        \\man 80
        \\
    ;
    var t = try FrequencyTable.fromText(std.testing.allocator, text);
    defer t.deinit();

    try std.testing.expectEqual(@as(u32, 3), t.len());
    try std.testing.expectEqual(@as(?u32, 50), t.get("fire"));
    try std.testing.expectEqual(@as(?u32, null), t.get("garbage"));
}

test "FrequencyTable accumulates duplicate words" {
    var t = FrequencyTable.init(std.testing.allocator);
    defer t.deinit();
    try t.put("dog", 10);
    try t.put("dog", 5);
    try std.testing.expectEqual(@as(?u32, 15), t.get("dog"));
}

test "FrequencyTable stem index maps inflected word to base" {
    var t = try FrequencyTable.fromSlice(std.testing.allocator, &.{
        .{ .word = "happy", .count = 100 },
        .{ .word = "happiness", .count = 40 },
    });
    defer t.deinit();
    // "happiness" stems (Snowball) to "happi"; reverse index should resolve it
    // to a stored base word that also stems to "happi".
    const base = t.baseWordForStem("happi");
    try std.testing.expect(base != null);
}
