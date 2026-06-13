// Hybrid Morphological Analyzer
//
// Combines rule-based morphology with a fallback stemmer.
// Strategy:
//   1. Try rule-based decomposition (suffix/prefix rules, with
//      morphophonological corrections and fuzzy stem matching)
//   2. Try multi-pass (compound + inflectional suffix)
//   3. Try compound-word detection (requires a frequency table)
//   4. Fall back to the stemmer (Porter or Snowball, from stemmer-zig)
//
// Provenance: extracted from a private research repo (ZigLinguistics). The
// bundled Porter/Snowball stemmers were replaced by the `stemmer` path
// dependency, and the mmap'd binary frequency format was replaced by the
// in-memory `FrequencyTable` (see frequency.zig). All decomposition logic is
// unchanged from the source.

const std = @import("std");
const morphology = @import("morphology.zig");
const stemmer = @import("stemmer");
const porter = stemmer.porter;
const snowball = stemmer.snowball;
const Category = @import("categories.zig").Category;
const simd = @import("simd_string.zig");
const FrequencyTable = @import("frequency.zig").FrequencyTable;

// Top 100 most frequent English words (function words)
// Used for semantic filtering in compound detection.
const TOP_100_WORDS = [_][]const u8{
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
    "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
    "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
    "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
    "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
    "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
    "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
    "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
    "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
    "even", "new", "want", "because", "any", "these", "give", "day", "most", "us",
};

pub const StemmerType = enum {
    Porter, // Porter stemmer (1980)
    Snowball, // Snowball/Porter2 stemmer (2001)
};

/// Validation mode for stem checking.
///
/// Controls how strictly stems are validated during decomposition.
pub const ValidationMode = enum {
    /// Accept all stems without validation.
    /// Use for: rare-word analysis where stems may be infrequent.
    Disabled,

    /// Validate stems against a frequency threshold.
    /// Use for: mixed corpora with moderate filtering needs.
    FrequencyBased,

    /// Strict semantic validation (TOP_100 + length checks for compounds;
    /// frequency-threshold for rules).
    /// Use for: compound detection to prevent implausible splits.
    Semantic,
};

pub const DecompositionKind = enum {
    RuleBased, // Successfully decomposed via morphological rules
    Compound, // Binary compound word (e.g., "fireman" -> "fire" + "man")
    Stemmed, // Fallback to stemmer
    Unchanged, // No decomposition possible
};

pub const Decomposition = struct {
    kind: DecompositionKind,
    result: []const u8,
    category: ?Category = null,
    rule: ?[]const u8 = null,
    // For compound decompositions
    compound_left: ?[]const u8 = null,
    compound_right: ?[]const u8 = null,
};

/// Hybrid Analyzer.
///
/// Combines rule-based morphological analysis with stemmer fallback.
/// Supports selective validation modes for rules vs. compounds.
///
/// The optional `frequencies` is *borrowed* (not owned): the caller owns the
/// FrequencyTable and must keep it alive for the analyzer's lifetime.
pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    stemmer_type: StemmerType,
    porter_stemmer: porter.Stemmer,
    snowball_stemmer: snowball.Stemmer,
    frequencies: ?*const FrequencyTable,
    min_stem_freq: u32,

    // Selective validation modes
    rule_validation: ValidationMode,
    compound_validation: ValidationMode,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{
            .allocator = allocator,
            .stemmer_type = .Snowball, // Default to Snowball (better performance)
            .porter_stemmer = porter.Stemmer.init(allocator),
            .snowball_stemmer = snowball.Stemmer.init(allocator),
            .frequencies = null,
            .min_stem_freq = 5,
            // Default to disabled rule validation (permissive for rare words).
            .rule_validation = .Disabled,
            .compound_validation = .Semantic,
        };
    }

    pub fn initWithStemmer(allocator: std.mem.Allocator, stemmer_type: StemmerType) Analyzer {
        var a = Analyzer.init(allocator);
        a.stemmer_type = stemmer_type;
        return a;
    }

    /// Initialize with a borrowed in-memory frequency table.
    ///
    /// Enables FrequencyBased rule validation and frequency-driven compound
    /// detection. The table is not owned; the caller must keep it alive and
    /// free it. Replaces the legacy `initWithFrequencies` /
    /// `initWithBinaryFrequencies` file/mmap loaders.
    pub fn initWithFrequencyTable(
        allocator: std.mem.Allocator,
        table: *const FrequencyTable,
        min_freq: u32,
    ) Analyzer {
        var a = Analyzer.init(allocator);
        a.frequencies = table;
        a.min_stem_freq = min_freq;
        a.rule_validation = .FrequencyBased;
        return a;
    }

    /// Clean up resources. The borrowed frequency table is NOT freed here.
    pub fn deinit(self: *Analyzer) void {
        _ = self;
        // Nothing owned: stemmers hold no persistent allocations across calls
        // (each stem() call manages its own), and the frequency table is
        // borrowed.
    }

    /// Analyze a word using the hybrid strategy. Caller owns returned memory
    /// (`result`, and `compound_left`/`compound_right` when present).
    pub fn analyze(self: *Analyzer, word: []const u8) !Decomposition {
        // 1. Rule-based decomposition
        if (try self.tryRuleBased(word)) |decomp| return decomp;

        // 2. Multi-pass (compound + inflectional suffix)
        if (try self.tryMultiPass(word)) |decomp| return decomp;

        // 3. Compound-word detection
        if (try self.tryCompound(word)) |decomp| return decomp;

        // 4. Stemmer fallback (Porter or Snowball)
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const stem_temp = switch (self.stemmer_type) {
            .Porter => blk: {
                var s = porter.Stemmer.init(arena.allocator());
                break :blk try s.stem(word);
            },
            .Snowball => blk: {
                var s = snowball.Stemmer.init(arena.allocator());
                break :blk try s.stem(word);
            },
        };

        const stem = try self.allocator.dupe(u8, stem_temp);

        if (!std.mem.eql(u8, word, stem)) {
            // Reject very short stems (< 3 chars).
            if (stem.len < 3) {
                self.allocator.free(stem);
                return self.unchanged(word);
            }

            // Reject stems ending in unnatural consonant clusters.
            if (endsWithConsonantCluster(stem)) {
                self.allocator.free(stem);
                return self.unchanged(word);
            }

            // Validate stem against corpus (major false-positive reducer),
            // only when frequency data is loaded.
            if (self.frequencies != null) {
                const is_valid_stem = blk: {
                    if (self.frequencies.?.contains(stem)) break :blk true;

                    // Morphophonological corrections; reject if they give back
                    // the original word (circular).
                    if (self.tryEDropping(stem)) |c| {
                        if (!std.mem.eql(u8, c, word)) break :blk true;
                    }
                    if (self.tryYToI(stem)) |c| {
                        if (!std.mem.eql(u8, c, word)) break :blk true;
                    }
                    if (self.tryConsonantDoubling(stem)) |c| {
                        if (!std.mem.eql(u8, c, word)) break :blk true;
                    }
                    if (self.lookupFuzzyStem(stem)) |c| {
                        if (!std.mem.eql(u8, c, word)) break :blk true;
                    }
                    break :blk false;
                };

                if (!is_valid_stem) {
                    self.allocator.free(stem);
                    return self.unchanged(word);
                }
            }

            return Decomposition{
                .kind = .Stemmed,
                .result = stem,
                .category = null,
                .rule = null,
            };
        }

        self.allocator.free(stem);
        return self.unchanged(word);
    }

    fn unchanged(self: *Analyzer, word: []const u8) !Decomposition {
        return Decomposition{
            .kind = .Unchanged,
            .result = try self.allocator.dupe(u8, word),
            .category = null,
            .rule = null,
        };
    }

    /// Multi-pass: strip a common inflectional suffix, then test for a compound.
    /// Example: "floorboards" -> strip "-s" -> "floorboard" -> "floor+board".
    fn tryMultiPass(self: *Analyzer, word: []const u8) !?Decomposition {
        const suffixes = [_]struct { suffix: []const u8, len: usize }{
            .{ .suffix = "s", .len = 1 },
            .{ .suffix = "ed", .len = 2 },
            .{ .suffix = "ing", .len = 3 },
        };

        for (suffixes) |suf| {
            if (word.len <= suf.len + 6) continue;

            if (std.mem.endsWith(u8, word, suf.suffix)) {
                if (std.mem.eql(u8, suf.suffix, "s")) {
                    if (simd.endsWithSs(word)) continue;
                }

                const base = word[0 .. word.len - suf.len];

                if (try self.tryCompound(base)) |comp_decomp| {
                    const result = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}+{s}",
                        .{ comp_decomp.result, suf.suffix },
                    );

                    self.allocator.free(comp_decomp.result);
                    if (comp_decomp.compound_left) |left| self.allocator.free(left);
                    if (comp_decomp.compound_right) |right| self.allocator.free(right);

                    return Decomposition{
                        .kind = .Compound,
                        .result = result,
                        .category = null,
                        .rule = "Multi-pass: compound + suffix",
                        .compound_left = null,
                        .compound_right = null,
                    };
                }
            }
        }

        return null;
    }

    /// Fuzzy stem lookup via the frequency table's stem -> base-word index.
    /// Example: "happi" (not a word) -> "happy".
    fn lookupFuzzyStem(self: *Analyzer, stem: []const u8) ?[]const u8 {
        const table = self.frequencies orelse return null;

        if (table.baseWordForStem(stem)) |base_word| return base_word;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var s = snowball.Stemmer.init(arena.allocator());
        const double_stem = s.stem(stem) catch return null;

        if (!std.mem.eql(u8, stem, double_stem)) {
            if (table.baseWordForStem(double_stem)) |base_word| return base_word;
        }
        return null;
    }

    /// Detect unnatural consonant clusters at the end of a stem (e.g. "warlik",
    /// "visibl"), used to reject over-aggressive stemmer output.
    fn endsWithConsonantCluster(stem: []const u8) bool {
        if (stem.len < 2) return false;

        const last1 = stem[stem.len - 1];
        const last2 = stem[stem.len - 2];
        const vowels = "aeiouAEIOU";

        const is_vowel1 = for (vowels) |v| {
            if (last1 == v) break true;
        } else false;
        const is_vowel2 = for (vowels) |v| {
            if (last2 == v) break true;
        } else false;

        if (!is_vowel1 and !is_vowel2) {
            const natural_clusters = [_][]const u8{
                "nt", "nd", "st", "ng", "nk", "mp", "th", "ch", "sh",
                "ck", "sk", "sp", "sm", "sw", "sc", "lt", "rt", "rm",
                "rn", "rk", "rd", "ld", "lm", "lk", "pt", "ct", "ft",
            };
            const ending = stem[stem.len - 2 ..];
            for (natural_clusters) |cluster| {
                if (std.mem.eql(u8, ending, cluster)) return false;
            }
            return true;
        }
        return false;
    }

    /// e-dropping correction: does stem+'e' name a frequent word?
    /// Example: "usable" -> "us" (no) vs "use" (yes).
    fn tryEDropping(self: *Analyzer, stem: []const u8) ?[]const u8 {
        if (stem.len < 2) return null;
        var buf: [256]u8 = undefined;
        if (stem.len + 1 > buf.len) return null;
        @memcpy(buf[0..stem.len], stem);
        buf[stem.len] = 'e';
        const with_e = buf[0 .. stem.len + 1];
        return self.frequentKey(with_e);
    }

    /// Consonant-doubling correction: does stem with one final consonant removed
    /// name a frequent word? Example: "running" -> "runn" (no) vs "run" (yes).
    fn tryConsonantDoubling(self: *Analyzer, stem: []const u8) ?[]const u8 {
        if (stem.len < 3) return null;
        const last = stem[stem.len - 1];
        const second_last = stem[stem.len - 2];
        if (last != second_last) return null;

        const vowels = "aeiouAEIOU";
        const is_vowel = for (vowels) |v| {
            if (last == v) break true;
        } else false;
        if (is_vowel) return null;

        const undoubled = stem[0 .. stem.len - 1];
        return self.frequentKey(undoubled);
    }

    /// y->i correction: does stem with final 'i' changed to 'y' name a frequent
    /// word? Example: "happier" -> "happi" (no) vs "happy" (yes).
    fn tryYToI(self: *Analyzer, stem: []const u8) ?[]const u8 {
        if (stem.len < 2) return null;
        if (stem[stem.len - 1] != 'i') return null;
        var buf: [256]u8 = undefined;
        if (stem.len > buf.len) return null;
        @memcpy(buf[0..stem.len], stem);
        buf[stem.len - 1] = 'y';
        const with_y = buf[0..stem.len];
        return self.frequentKey(with_y);
    }

    /// Return the stable key pointer for `candidate` if it is in the table and
    /// meets the minimum frequency threshold.
    fn frequentKey(self: *Analyzer, candidate: []const u8) ?[]const u8 {
        const table = self.frequencies orelse return null;
        if (table.getKey(candidate)) |key| {
            const freq = table.get(key).?;
            if (freq >= self.min_stem_freq) return key;
        }
        return null;
    }

    fn validateStem(self: *Analyzer, stem: []const u8) bool {
        switch (self.rule_validation) {
            .Disabled => return true,
            .FrequencyBased, .Semantic => {
                if (self.frequencies) |table| {
                    const freq = table.get(stem) orelse return false;
                    return freq >= self.min_stem_freq;
                }
                return true; // No freq table -> accept all.
            },
        }
    }

    /// Rule-based decomposition. Returns null if no rule applies.
    /// Honors `rule_validation`; includes morphophonological adjustments
    /// (e-dropping, consonant doubling, y->i) and fuzzy stem matching.
    fn tryRuleBased(self: *Analyzer, word: []const u8) !?Decomposition {
        // -able (Adj) from V
        if (simd.endsWithAble(word)) {
            const stem = word[0 .. word.len - 4];
            if (self.tryEDropping(stem)) |corrected| {
                return try self.ruleResult(corrected, .V, "V + -able -> Adj (e-dropping)");
            }
            if (stem.len >= 3) {
                if (self.lookupFuzzyStem(stem)) |base_word| {
                    return try self.ruleResult(base_word, .V, "V + -able -> Adj (fuzzy)");
                }
            }
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .V, "V + -able -> Adj");
            }
        }

        // -ly (Adv) from Adj
        if (simd.endsWithLy(word)) {
            const stem = word[0 .. word.len - 2];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .Adj, "Adj + -ly -> Adv");
            }
        }

        // -ness (N) from Adj
        if (simd.endsWithNess(word)) {
            const stem = word[0 .. word.len - 4];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .Adj, "Adj + -ness -> N");
            }
        }

        // un- (negation) from Adj/V; require stem >= 5 chars to avoid noise.
        if (simd.startsWithUn(word) and word.len > 3) {
            const stem = word[2..];
            if (stem.len >= 5 and self.validateStem(stem)) {
                return try self.ruleResult(stem, null, "un- + X -> X (negation)");
            }
        }

        // -ing (V gerund/progressive)
        if (simd.endsWithIng(word)) {
            const stem = word[0 .. word.len - 3];
            if (self.tryEDropping(stem)) |c| return try self.ruleResult(c, .V, "V + -ing -> V/N (e-dropping)");
            if (self.tryConsonantDoubling(stem)) |c| return try self.ruleResult(c, .V, "V + -ing -> V/N (consonant doubling)");
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .V, "V + -ing -> V/N");
            }
        }

        // -ed (V past tense)
        if (simd.endsWithEd(word)) {
            const stem = word[0 .. word.len - 2];
            if (self.tryEDropping(stem)) |c| return try self.ruleResult(c, .V, "V + -ed -> V (e-dropping)");
            if (self.tryConsonantDoubling(stem)) |c| return try self.ruleResult(c, .V, "V + -ed -> V (consonant doubling)");
            if (self.tryYToI(stem)) |c| return try self.ruleResult(c, .V, "V + -ed -> V (y->i)");
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .V, "V + -ed -> V");
            }
        }

        // -er (comparative or agent)
        if (simd.endsWithEr(word)) {
            const stem = word[0 .. word.len - 2];
            if (self.tryConsonantDoubling(stem)) |c| return try self.ruleResult(c, null, "X + -er -> Adj/N (consonant doubling)");
            if (self.tryYToI(stem)) |c| return try self.ruleResult(c, .Adj, "Adj + -er -> Adj (y->i)");
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, null, "X + -er -> Adj/N");
            }
        }

        // -est (superlative)
        if (simd.endsWithEst(word)) {
            const stem = word[0 .. word.len - 3];
            if (self.tryConsonantDoubling(stem)) |c| return try self.ruleResult(c, .Adj, "Adj + -est -> Adj (consonant doubling)");
            if (self.tryYToI(stem)) |c| return try self.ruleResult(c, .Adj, "Adj + -est -> Adj (y->i)");
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .Adj, "Adj + -est -> Adj");
            }
        }

        // -tion (nominalization)
        if (simd.endsWithTion(word)) {
            const stem = word[0 .. word.len - 4];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .V, "V + -tion -> N");
            }
        }

        // -sion (nominalization)
        if (simd.endsWithSion(word)) {
            const stem = word[0 .. word.len - 4];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .V, "V + -sion -> N");
            }
        }

        // -ment (nominalization)
        if (simd.endsWithMent(word)) {
            const stem = word[0 .. word.len - 4];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .V, "V + -ment -> N");
            }
        }

        // -ize (verbalization)
        if (simd.endsWithIze(word)) {
            const stem = word[0 .. word.len - 3];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N/Adj + -ize -> V");
            }
        }

        // -ise (British spelling)
        if (simd.endsWithIse(word)) {
            const stem = word[0 .. word.len - 3];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N/Adj + -ise -> V");
            }
        }

        // re- (repetition)
        if (simd.startsWithRe(word) and word.len > 4) {
            const stem = word[2..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, .V, "re- + V -> V");
        }

        // dis- (negation)
        if (simd.startsWithDis(word) and word.len > 5) {
            const stem = word[3..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "dis- + X -> X");
        }

        // mis- (wrong/bad)
        if (simd.startsWithMis(word) and word.len > 5) {
            const stem = word[3..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "mis- + X -> X");
        }

        // pre- (before)
        if (simd.startsWithPre(word) and word.len > 5) {
            const stem = word[3..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "pre- + X -> X");
        }

        // in- (not/into)
        if (simd.startsWithIn(word) and word.len > 4) {
            const stem = word[2..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "in- + X -> X");
        }

        // im- (not, before p/b/m)
        if (simd.startsWithIm(word) and word.len > 4) {
            const stem = word[2..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "im- + X -> X");
        }

        // over- (excessive)
        if (simd.startsWithOver(word) and word.len > 6) {
            const stem = word[4..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "over- + X -> X");
        }

        // under- (below/insufficient)
        if (simd.startsWithUnder(word) and word.len > 7) {
            const stem = word[5..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "under- + X -> X");
        }

        // anti- (against)
        if (simd.startsWithAnti(word) and word.len > 6) {
            const stem = word[4..];
            if (self.validateStem(stem)) return try self.ruleResult(stem, null, "anti- + X -> X");
        }

        // -ful (full of)
        if (simd.endsWithFul(word)) {
            const stem = word[0 .. word.len - 3];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N + -ful -> Adj");
            }
        }

        // -less (without)
        if (simd.endsWithLess(word)) {
            const stem = word[0 .. word.len - 4];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N + -less -> Adj");
            }
        }

        // -ous (having qualities of)
        if (simd.endsWithOus(word)) {
            const stem = word[0 .. word.len - 3];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N + -ous -> Adj");
            }
        }

        // -ive (tending to)
        if (simd.endsWithIve(word)) {
            const stem = word[0 .. word.len - 3];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .V, "V + -ive -> Adj/N");
            }
        }

        // -al (relating to)
        if (simd.endsWithAl(word)) {
            const stem = word[0 .. word.len - 2];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N + -al -> Adj");
            }
        }

        // -ic (relating to)
        if (simd.endsWithIc(word)) {
            const stem = word[0 .. word.len - 2];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N + -ic -> Adj");
            }
        }

        // -ar (relating to)
        if (simd.endsWithAr(word)) {
            const stem = word[0 .. word.len - 2];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N + -ar -> Adj");
            }
        }

        // -ist (person who does/believes)
        if (simd.endsWithIst(word)) {
            const stem = word[0 .. word.len - 3];
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, .N, "N + -ist -> N");
            }
        }

        // -s (plural/3sg). Check AFTER -ness/-less/-ous/etc. Skip -ss and -us.
        if (simd.endsWithS(word) and !simd.endsWithSs(word) and !simd.endsWithUs(word)) {
            const stem = word[0 .. word.len - 1];
            if (stem.len >= 3) {
                if (self.lookupFuzzyStem(stem)) |base_word| {
                    return try self.ruleResult(base_word, null, "N/V + -s -> N/V (fuzzy)");
                }
            }
            if (stem.len >= 3 and self.validateStem(stem)) {
                return try self.ruleResult(stem, null, "N/V + -s -> N/V");
            }
        }

        return null;
    }

    fn ruleResult(self: *Analyzer, stem: []const u8, category: ?Category, rule: []const u8) !Decomposition {
        return Decomposition{
            .kind = .RuleBased,
            .result = try self.allocator.dupe(u8, stem),
            .category = category,
            .rule = rule,
        };
    }

    /// Compound-word detection. Splits a word into two valid components found in
    /// the frequency table. Honors `compound_validation`.
    fn tryCompound(self: *Analyzer, word: []const u8) !?Decomposition {
        if (self.compound_validation == .Disabled) return null;
        const table = self.frequencies orelse return null;
        if (word.len < 6) return null;

        var best_split: ?struct {
            left: []const u8,
            right: []const u8,
            score: u64,
        } = null;

        var split_pos: usize = 3;
        while (split_pos <= word.len - 3) : (split_pos += 1) {
            const left = word[0..split_pos];
            const right = word[split_pos..];

            const left_freq = table.get(left) orelse continue;
            const right_freq = table.get(right) orelse continue;

            const valid = switch (self.compound_validation) {
                .Disabled => unreachable,
                .FrequencyBased => (left_freq >= self.min_stem_freq * 2 and
                    right_freq >= self.min_stem_freq * 2),
                .Semantic => blk: {
                    if (left_freq < self.min_stem_freq * 2 or
                        right_freq < self.min_stem_freq * 2) break :blk false;
                    break :blk isSemanticallPlausible(left, right, word);
                },
            };
            if (!valid) continue;

            const score = @as(u64, left_freq) * @as(u64, right_freq);
            if (best_split == null or score > best_split.?.score) {
                best_split = .{ .left = left, .right = right, .score = score };
            }
        }

        if (best_split) |split| {
            const result = try std.fmt.allocPrint(self.allocator, "{s}+{s}", .{ split.left, split.right });
            return Decomposition{
                .kind = .Compound,
                .result = result,
                .category = null,
                .rule = "Binary compound",
                .compound_left = try self.allocator.dupe(u8, split.left),
                .compound_right = try self.allocator.dupe(u8, split.right),
            };
        }
        return null;
    }

    /// Bulk analyze multiple words. Caller owns returned memory.
    pub fn analyzeMany(self: *Analyzer, words: []const []const u8) ![]Decomposition {
        const results = try self.allocator.alloc(Decomposition, words.len);
        for (words, 0..) |word, i| results[i] = try self.analyze(word);
        return results;
    }
};

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

fn isTopWord(word: []const u8) bool {
    for (TOP_100_WORDS) |top_word| {
        if (std.mem.eql(u8, word, top_word)) return true;
    }
    return false;
}

/// Reject implausible compounds like "within" -> "with" + "in".
fn isSemanticallPlausible(left: []const u8, right: []const u8, word: []const u8) bool {
    // Rule 1: reject if either part is a TOP_100 function word.
    if (isTopWord(left) or isTopWord(right)) return false;
    // Rule 2: each part must be at least ~30% of total length.
    const min_len = @max(3, (word.len * 3) / 10);
    if (left.len < min_len or right.len < min_len) return false;
    // Rule 3: both parts at least 3 chars.
    if (left.len < 3 or right.len < 3) return false;
    return true;
}

// ============================================================================
// TESTS
// ============================================================================

test "hybrid analyzer - rule-based decomposition" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    {
        const decomp = try analyzer.analyze("readable");
        defer std.testing.allocator.free(decomp.result);
        try std.testing.expectEqual(DecompositionKind.RuleBased, decomp.kind);
        try std.testing.expectEqualStrings("read", decomp.result);
        try std.testing.expectEqual(Category.V, decomp.category.?);
    }
    {
        const decomp = try analyzer.analyze("quickly");
        defer std.testing.allocator.free(decomp.result);
        try std.testing.expectEqual(DecompositionKind.RuleBased, decomp.kind);
        try std.testing.expectEqualStrings("quick", decomp.result);
        try std.testing.expectEqual(Category.Adj, decomp.category.?);
    }
    {
        const decomp = try analyzer.analyze("happiness");
        defer std.testing.allocator.free(decomp.result);
        try std.testing.expectEqual(DecompositionKind.RuleBased, decomp.kind);
        try std.testing.expectEqualStrings("happi", decomp.result);
        try std.testing.expectEqual(Category.Adj, decomp.category.?);
    }
}

test "hybrid analyzer - stemming fallback" {
    // CORRECTED from the legacy expectations. The legacy test asserted
    // running -> Stemmed "run" and relational -> Stemmed "relate". Both are
    // dormant-and-wrong: under the default config (rule_validation = .Disabled,
    // no frequency table) those words are intercepted by affix RULES before the
    // stemmer is reached (-ing strips running -> "runn"; re- strips relational
    // -> "lational"; both pass Disabled validation). See reference_test.zig.
    //
    // To exercise the *stemmer fallback* path we must use words that match no
    // prefix/suffix rule yet are still reduced by Snowball. "feed" and "need"
    // qualify: no rule applies, and Snowball reduces the final long vowel.
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    {
        const decomp = try analyzer.analyze("feed");
        defer std.testing.allocator.free(decomp.result);
        try std.testing.expectEqual(DecompositionKind.Stemmed, decomp.kind);
        try std.testing.expectEqualStrings("fee", decomp.result);
    }
    {
        const decomp = try analyzer.analyze("need");
        defer std.testing.allocator.free(decomp.result);
        try std.testing.expectEqual(DecompositionKind.Stemmed, decomp.kind);
        try std.testing.expectEqualStrings("nee", decomp.result);
    }
}

test "hybrid analyzer - unchanged words" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const decomp = try analyzer.analyze("cat");
    defer std.testing.allocator.free(decomp.result);
    try std.testing.expectEqual(DecompositionKind.Unchanged, decomp.kind);
    try std.testing.expectEqualStrings("cat", decomp.result);
}

test "hybrid analyzer - bulk analysis" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // "running" was replaced with "feed": under the default config "running"
    // is RuleBased (-ing), not Stemmed (see the stemming-fallback test above).
    // "feed" matches no rule and genuinely reaches the stemmer.
    const words = [_][]const u8{ "readable", "feed", "cat" };
    const results = try analyzer.analyzeMany(&words);
    defer std.testing.allocator.free(results);
    for (results) |decomp| std.testing.allocator.free(decomp.result);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqual(DecompositionKind.RuleBased, results[0].kind);
    try std.testing.expectEqual(DecompositionKind.Stemmed, results[1].kind);
    try std.testing.expectEqual(DecompositionKind.Unchanged, results[2].kind);
}

test "compound detection - in-memory frequency table" {
    var table = try FrequencyTable.fromSlice(std.testing.allocator, &.{
        .{ .word = "fire", .count = 1000 },
        .{ .word = "man", .count = 1000 },
    });
    defer table.deinit();

    var analyzer = Analyzer.initWithFrequencyTable(std.testing.allocator, &table, 5);
    defer analyzer.deinit();

    const decomp = try analyzer.analyze("fireman");
    defer {
        std.testing.allocator.free(decomp.result);
        if (decomp.compound_left) |l| std.testing.allocator.free(l);
        if (decomp.compound_right) |r| std.testing.allocator.free(r);
    }

    try std.testing.expectEqual(DecompositionKind.Compound, decomp.kind);
    try std.testing.expectEqualStrings("fire+man", decomp.result);
    try std.testing.expectEqualStrings("fire", decomp.compound_left.?);
    try std.testing.expectEqualStrings("man", decomp.compound_right.?);
}

test "compound detection - semantic filtering helpers" {
    try std.testing.expect(isTopWord("the"));
    try std.testing.expect(isTopWord("and"));
    try std.testing.expect(isTopWord("with"));
    try std.testing.expect(!isTopWord("fire"));
    try std.testing.expect(!isTopWord("book"));

    try std.testing.expect(!isSemanticallPlausible("with", "in", "within"));
    try std.testing.expect(!isSemanticallPlausible("ab", "cdefgh", "abcdefgh"));
    try std.testing.expect(isSemanticallPlausible("fire", "man", "fireman"));
    try std.testing.expect(isSemanticallPlausible("book", "shelf", "bookshelf"));
}

test "compound detection - edge cases" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    {
        const decomp = try analyzer.analyze("cat");
        defer std.testing.allocator.free(decomp.result);
        try std.testing.expect(decomp.kind != .Compound);
    }
    {
        const decomp = try analyzer.analyze("abcdef");
        defer std.testing.allocator.free(decomp.result);
        try std.testing.expect(decomp.kind == .Stemmed or decomp.kind == .Unchanged);
    }
}
