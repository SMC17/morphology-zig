# Changelog

All notable changes to this project are documented here.

## [0.0.1] - 2026-06-13

Initial extraction from a private research repo (`ZigLinguistics`, Zig 0.15.1),
migrated to Zig 0.16.

### Added
- Rule engine (`morphology.zig`): `SuffixRule` / `PrefixRule` / `ProcessRule`
  with allomorph selectors and spell-out combiners (e-deletion, y->i, CVC
  doubling), irregular plurals, comparative/superlative, rules-vs-storage past
  tense, ablaut, reduplication, genitive construction, and binary derivation
  trees (`Node`).
- Hybrid analyzer (`analyzer.zig`): rule-based decomposition -> multi-pass
  (compound + suffix) -> compound detection -> stemmer fallback, with three
  `ValidationMode`s (Disabled / FrequencyBased / Semantic).
- `FrequencyTable` (`frequency.zig`): in-memory `word -> count` map plus
  `stem -> base-word` reverse index; built from a slice of `(word, count)`
  pairs or a `word<space>count` text file.
- `MorphologicalPatternDetector` (`morphological_patterns.zig`): suffix/prefix
  productivity discovery.
- Supporting modules: `categories.zig`, `phonology.zig`, `syntax.zig`,
  `simd_string.zig`.
- 20-word canonical reference test and a validation-mode behavioral test
  (`reference_test.zig`).

### Changed (migration)
- Function-type struct fields made pointers (`?fn(...)` -> `?*const fn(...)`)
  in `SuffixRule` and `ProcessRule`.
- `std.ArrayList(T){}` -> `.empty` (unmanaged-list 0.16 API).
- Fallback stemmer rewired from bundled Porter/Snowball to the external
  `stemmer` path dependency (`../stemmer-zig`).

### Removed (descoped)
- The mmap'd binary frequency-file format (`FREQ` magic, v1/v2) and its
  loaders (`initWithFrequencies`, `initWithBinaryFrequencies`), replaced by the
  in-memory `FrequencyTable`.
- The parallel `analyzeManyParallel` thread-pool path (depended on bundled
  stemmer internals and the zero-copy mmap'd map). Sequential `analyzeMany`
  retained.

### Fixed (test refereeing)
- Corrected two dormant-and-wrong analyzer expectations that had never executed
  under the engine's default config:
  - `running` is RuleBased `"runn"` (was Stemmed `"run"`).
  - `relational` is RuleBased `"lational"` (was Stemmed `"relate"`).
  Each correction is documented inline with the evidence.
