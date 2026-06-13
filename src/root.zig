//! morphology — English derivational/inflectional morphology in Zig 0.16.
//!
//! A teaching-grade rule engine plus a hybrid analyzer:
//!
//!   - `morphology` — typed derivation rules (SuffixRule / PrefixRule /
//!     ProcessRule) with allomorph selectors and spell-out combiners
//!     (e-deletion, y->i, CVC doubling), irregular plurals, comparatives,
//!     ablaut, reduplication, and binary derivation trees (`Node`).
//!   - `Analyzer` — hybrid pipeline: rule-based decomposition -> multi-pass
//!     (compound + suffix) -> compound detection -> stemmer fallback. Three
//!     `ValidationMode`s (Disabled / FrequencyBased / Semantic) gate how
//!     aggressively stems are accepted.
//!   - `FrequencyTable` — in-memory word-frequency table consumed by the
//!     analyzer's FrequencyBased validation and compound detector.
//!   - `MorphologicalPatternDetector` — suffix/prefix productivity discovery.
//!
//! The fallback stemmer is the external `stemmer` package (Porter + Snowball).
//!
//! Provenance: extracted from a private research repo (ZigLinguistics, Zig
//! 0.15.1) and migrated to Zig 0.16. The mmap'd binary frequency-file format
//! was descoped in favor of `FrequencyTable`. Scope is English/ASCII; rule
//! coverage is illustrative, not exhaustive.

const std = @import("std");

pub const categories = @import("categories.zig");
pub const Category = categories.Category;

pub const phonology = @import("phonology.zig");
pub const syntax = @import("syntax.zig");
pub const simd_string = @import("simd_string.zig");

pub const morphology = @import("morphology.zig");
pub const Node = morphology.Node;
pub const Rules = morphology.Rules;
pub const MorphError = morphology.MorphError;

pub const frequency = @import("frequency.zig");
pub const FrequencyTable = frequency.FrequencyTable;

pub const analyzer = @import("analyzer.zig");
pub const Analyzer = analyzer.Analyzer;
pub const Decomposition = analyzer.Decomposition;
pub const DecompositionKind = analyzer.DecompositionKind;
pub const ValidationMode = analyzer.ValidationMode;
pub const StemmerType = analyzer.StemmerType;

pub const patterns = @import("morphological_patterns.zig");
pub const MorphologicalPatternDetector = patterns.MorphologicalPatternDetector;

test {
    // Pull in every module's own tests.
    _ = categories;
    _ = phonology;
    _ = syntax;
    _ = simd_string;
    _ = morphology;
    _ = frequency;
    _ = analyzer;
    _ = patterns;
    _ = @import("reference_test.zig");
}
