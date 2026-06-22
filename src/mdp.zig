const std = @import("std");
const analyzer = @import("analyzer.zig");
const simd = @import("simd_string.zig");

/// MorphEnv implements a Sequential Morpheme-Segmentation MDP.
/// The agent steps through the word from left to right.
/// Action 0 = do not split after current char
/// Action 1 = split after current char
pub const MorphEnv = struct {
    word: []const u8,
    cursor: usize,
    splits: std.ArrayList(usize),
    allocator: std.mem.Allocator,
    oracle: *analyzer.Analyzer,

    pub const StepResult = struct {
        reward: f32,
        done: bool,
    };

    pub fn init(allocator: std.mem.Allocator, oracle: *analyzer.Analyzer) MorphEnv {
        return MorphEnv{
            .word = "",
            .cursor = 0,
            .splits = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
            .oracle = oracle,
        };
    }

    pub fn deinit(self: *MorphEnv) void {
        self.splits.deinit();
    }

    pub fn reset(self: *MorphEnv, word: []const u8) void {
        self.word = word;
        self.cursor = 0;
        self.splits.clearRetainingCapacity();
    }

    pub fn step(self: *MorphEnv, action: u8) !StepResult {
        if (self.cursor >= self.word.len) {
            return StepResult{ .reward = 0.0, .done = true };
        }

        // action == 1 means we place a split boundary *before* the character at self.cursor.
        // Wait, sequential: at each step, we consider the character at `cursor`.
        // If action 1, we split AFTER the current character. So the boundary is at `cursor + 1`.
        if (action == 1) {
            // Cannot split after the very last character (that's just the end of the word)
            if (self.cursor + 1 < self.word.len) {
                try self.splits.append(self.cursor + 1);
            }
        }

        self.cursor += 1;

        if (self.cursor == self.word.len) {
            // Episode done, compute reward
            const reward = try self.computeReward();
            return StepResult{ .reward = reward, .done = true };
        }

        return StepResult{ .reward = 0.0, .done = false };
    }

    fn computeReward(self: *MorphEnv) !f32 {
        const decomp = try self.oracle.analyze(self.word);
        
        var expected_splits = std.ArrayList(usize).init(self.allocator);
        defer expected_splits.deinit();

        switch (decomp.kind) {
            .Compound => {
                if (decomp.compound_left) |left| {
                    try expected_splits.append(left.len);
                }
            },
            .RuleBased => {
                // Determine the split index from the rule string.
                // If it's a prefix rule like "re- + V -> V"
                if (decomp.rule) |rule| {
                    if (std.mem.indexOf(u8, rule, "- +")) |idx| {
                        // Prefix, e.g. "pre- + X"
                        // The affix is rule[0..idx]
                        const prefix_len = idx;
                        try expected_splits.append(prefix_len);
                    } else if (std.mem.indexOf(u8, rule, "+ -")) |idx| {
                        // Suffix, e.g. "V + -able"
                        // Find the space after "-able" if any, or end of rule word
                        // Actually, we can just check if word ends with something.
                        // But simpler: just guess based on result length if it's exact match.
                        if (std.mem.startsWith(u8, self.word, decomp.result)) {
                            try expected_splits.append(decomp.result.len);
                        } else {
                            // If stem was modified (e.g. happi -> happy), 
                            // we just do word.len - (rule's suffix length).
                            // But for our simplified reward, we can just say if the 
                            // agent's splits produce a valid stem + suffix, we give reward.
                            // To be rigorous, we will just use the length of the suffix.
                            // The suffix is everything after "+ -" up to the next space.
                            const suffix_start = idx + 3; // after "+ -"
                            if (std.mem.indexOf(u8, rule[suffix_start..], " ")) |space_idx| {
                                const suffix_len = space_idx;
                                if (self.word.len > suffix_len) {
                                    try expected_splits.append(self.word.len - suffix_len);
                                }
                            } else {
                                const suffix_len = rule.len - suffix_start;
                                if (self.word.len > suffix_len) {
                                    try expected_splits.append(self.word.len - suffix_len);
                                }
                            }
                        }
                    }
                }
            },
            .Stemmed, .Unchanged => {
                // Expected 0 splits
            },
        }

        // Check if agent splits exactly match expected splits
        if (self.splits.items.len != expected_splits.items.len) {
            return 0.0;
        }

        for (self.splits.items, 0..) |split, i| {
            if (split != expected_splits.items[i]) {
                return 0.0;
            }
        }

        return 1.0;
    }
};
