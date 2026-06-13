const std = @import("std");

/// Morphological pattern detector for affix discovery
pub const MorphologicalPatternDetector = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayList(AffixPattern),
    
    pub const AffixPattern = struct {
        affix: []const u8,
        affix_type: AffixType,
        examples: std.ArrayList(Example),
        frequency: usize,
        productivity: f64, // Ratio of types to tokens
        
        pub const AffixType = enum {
            PREFIX,
            SUFFIX,
            INFIX,
            UNKNOWN,
        };
        
        pub const Example = struct {
            stem: []const u8,
            derived: []const u8,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator) MorphologicalPatternDetector {
        return .{
            .allocator = allocator,
            .patterns = .empty,
        };
    }
    
    pub fn deinit(self: *MorphologicalPatternDetector) void {
        for (self.patterns.items) |*pattern| {
            self.allocator.free(pattern.affix);
            for (pattern.examples.items) |example| {
                self.allocator.free(example.stem);
                self.allocator.free(example.derived);
            }
            pattern.examples.deinit(self.allocator);
        }
        self.patterns.deinit(self.allocator);
    }
    
    /// Detect common suffixes from word list
    pub fn detectSuffixes(self: *MorphologicalPatternDetector, words: []const []const u8, min_freq: usize) !void {
        // Common English suffixes to look for
        const known_suffixes = [_][]const u8{
            "ing", "ed", "s", "es", "er", "est", "ly", "ness", 
            "tion", "sion", "ment", "able", "ible", "ful", "less",
            "ous", "ious", "al", "ial", "ive"
        };
        
        var suffix_counts = std.StringHashMap(usize).init(self.allocator);
        defer suffix_counts.deinit();
        
        // Count occurrences of each suffix
        for (words) |word| {
            if (word.len < 4) continue; // Skip short words
            
            for (known_suffixes) |suffix| {
                if (std.mem.endsWith(u8, word, suffix)) {
                    const entry = try suffix_counts.getOrPut(suffix);
                    if (entry.found_existing) {
                        entry.value_ptr.* += 1;
                    } else {
                        entry.value_ptr.* = 1;
                    }
                }
            }
        }
        
        // Create patterns for frequent suffixes
        var it = suffix_counts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* >= min_freq) {
                var pattern = AffixPattern{
                    .affix = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .affix_type = .SUFFIX,
                    .examples = .empty,
                    .frequency = entry.value_ptr.*,
                    .productivity = 0.0,
                };
                
                // Collect examples
                var example_count: usize = 0;
                for (words) |word| {
                    if (std.mem.endsWith(u8, word, entry.key_ptr.*) and example_count < 10) {
                        const stem_len = word.len - entry.key_ptr.*.len;
                        const stem = word[0..stem_len];
                        
                        try pattern.examples.append(self.allocator, .{
                            .stem = try self.allocator.dupe(u8, stem),
                            .derived = try self.allocator.dupe(u8, word),
                        });
                        example_count += 1;
                    }
                }
                
                // Calculate productivity (types / tokens)
                pattern.productivity = @as(f64, @floatFromInt(pattern.examples.items.len)) / 
                                       @as(f64, @floatFromInt(pattern.frequency));
                
                try self.patterns.append(self.allocator, pattern);
            }
        }
    }
    
    /// Detect common prefixes
    pub fn detectPrefixes(self: *MorphologicalPatternDetector, words: []const []const u8, min_freq: usize) !void {
        const known_prefixes = [_][]const u8{
            "un", "re", "dis", "in", "im", "pre", "post", "over", 
            "under", "mis", "sub", "super", "anti", "non", "de"
        };
        
        var prefix_counts = std.StringHashMap(usize).init(self.allocator);
        defer prefix_counts.deinit();
        
        for (words) |word| {
            if (word.len < 4) continue;
            
            for (known_prefixes) |prefix| {
                if (std.mem.startsWith(u8, word, prefix)) {
                    const entry = try prefix_counts.getOrPut(prefix);
                    if (entry.found_existing) {
                        entry.value_ptr.* += 1;
                    } else {
                        entry.value_ptr.* = 1;
                    }
                }
            }
        }
        
        var it = prefix_counts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* >= min_freq) {
                var pattern = AffixPattern{
                    .affix = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .affix_type = .PREFIX,
                    .examples = .empty,
                    .frequency = entry.value_ptr.*,
                    .productivity = 0.0,
                };
                
                var example_count: usize = 0;
                for (words) |word| {
                    if (std.mem.startsWith(u8, word, entry.key_ptr.*) and example_count < 10) {
                        const stem = word[entry.key_ptr.*.len..];
                        
                        try pattern.examples.append(self.allocator, .{
                            .stem = try self.allocator.dupe(u8, stem),
                            .derived = try self.allocator.dupe(u8, word),
                        });
                        example_count += 1;
                    }
                }
                
                pattern.productivity = @as(f64, @floatFromInt(pattern.examples.items.len)) / 
                                       @as(f64, @floatFromInt(pattern.frequency));
                
                try self.patterns.append(self.allocator, pattern);
            }
        }
    }
    
    /// Get all detected patterns sorted by frequency
    pub fn getPatterns(self: *const MorphologicalPatternDetector) []const AffixPattern {
        return self.patterns.items;
    }
    
    /// Export patterns to JSON format
    pub fn exportJSON(self: *const MorphologicalPatternDetector, writer: anytype) !void {
        try writer.writeAll("{\\n");
        try writer.writeAll("  \"morphological_patterns\": [\\n");
        
        for (self.patterns.items, 0..) |pattern, i| {
            try writer.writeAll("    {\\n");
            try writer.print("      \"affix\": \"{s}\",\\n", .{pattern.affix});
            try writer.print("      \"type\": \"{s}\",\\n", .{@tagName(pattern.affix_type)});
            try writer.print("      \"frequency\": {},\\n", .{pattern.frequency});
            try writer.print("      \"productivity\": {d:.4},\\n", .{pattern.productivity});
            try writer.writeAll("      \"examples\": [\\n");
            
            const max_examples = @min(pattern.examples.items.len, 5);
            for (pattern.examples.items[0..max_examples], 0..) |example, j| {
                try writer.writeAll("        {\\n");
                try writer.print("          \"stem\": \"{s}\",\\n", .{example.stem});
                try writer.print("          \"derived\": \"{s}\"\\n", .{example.derived});
                if (j + 1 < max_examples) {
                    try writer.writeAll("        },\\n");
                } else {
                    try writer.writeAll("        }\\n");
                }
            }
            
            try writer.writeAll("      ]\\n");
            if (i + 1 < self.patterns.items.len) {
                try writer.writeAll("    },\\n");
            } else {
                try writer.writeAll("    }\\n");
            }
        }
        
        try writer.writeAll("  ]\\n");
        try writer.writeAll("}\\n");
    }
};

// Tests
test "detect suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    
    var detector = MorphologicalPatternDetector.init(alloc);
    defer detector.deinit();
    
    const words = [_][]const u8{
        "walking", "running", "jumping", "reading", 
        "walked", "jumped", "played", "wanted",
        "quickly", "slowly", "happily"
    };
    
    try detector.detectSuffixes(&words, 2);
    
    const patterns = detector.getPatterns();
    try std.testing.expect(patterns.len > 0);
    
    // Should detect -ing, -ed, -ly
    var found_ing = false;
    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern.affix, "ing")) {
            found_ing = true;
            try std.testing.expectEqual(@as(usize, 4), pattern.frequency);
        }
    }
    try std.testing.expect(found_ing);
}

test "detect prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    
    var detector = MorphologicalPatternDetector.init(alloc);
    defer detector.deinit();
    
    const words = [_][]const u8{
        "undo", "unlock", "unhappy", "unknown",
        "redo", "rew rite", "return",
        "disconnect", "disagree", "dislike"
    };
    
    try detector.detectPrefixes(&words, 2);
    
    const patterns = detector.getPatterns();
    try std.testing.expect(patterns.len > 0);
    
    var found_un = false;
    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern.affix, "un")) {
            found_un = true;
            try std.testing.expectEqual(@as(usize, 4), pattern.frequency);
        }
    }
    try std.testing.expect(found_un);
}
