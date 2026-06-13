# morphology

English derivational/inflectional morphology in Zig 0.16: a typed rule engine
plus a hybrid word analyzer.

## What it is

Two layers over plain string operations:

- **Rule engine** (`morphology.zig`) — typed derivation rules over a small
  category set (N / V / Adj / Adv / ...):
  - `SuffixRule`, `PrefixRule`, `ProcessRule`, each with an `apply` that builds
    a binary derivation tree (`Node` with `left` stem / `right` affix).
  - Allomorph selectors and spell-out combiners: final-e deletion
    (`arrive` + `-al` -> `arrival`), y->i (`rely` + `-ance` -> `reliance`),
    CVC consonant doubling (`stop` + `-able` -> `stoppable`), plural -s
    allomorphy (`cat` -> `cats`, `dog` -> `dogz` in the slide model).
  - Irregular plurals, comparative/superlative (morphological vs periphrastic),
    rules-vs-storage past tense, ablaut, reduplication, genitive construction.
- **Hybrid analyzer** (`analyzer.zig`) — decomposes a surface word via:
  1. rule-based affix stripping (with e-drop / consonant-doubling / y->i
     corrections and fuzzy stem matching when a frequency table is present),
  2. multi-pass (compound + inflectional suffix),
  3. binary compound detection,
  4. fallback to a stemmer (Porter or Snowball).

  Three `ValidationMode`s — `Disabled`, `FrequencyBased`, `Semantic` — gate how
  aggressively candidate stems are accepted, and demonstrably change results.

Supporting modules: `phonology.zig` (plural allomorph heuristic),
`syntax.zig` (toy NP/PP/clause validators used by the genitive builder),
`simd_string.zig` (`@Vector` affix matchers), `morphological_patterns.zig`
(suffix/prefix productivity discovery), and `frequency.zig` (the in-memory
`FrequencyTable`).

## Usage

```zig
const morph = @import("morphology");

// Analyzer
var a = morph.Analyzer.init(allocator);
defer a.deinit();
const d = try a.analyze("readable");      // RuleBased, result "read", category .V
defer allocator.free(d.result);

// With a frequency table (enables FrequencyBased validation + compound detection)
var table = try morph.FrequencyTable.fromSlice(allocator, &.{
    .{ .word = "fire", .count = 1000 },
    .{ .word = "man",  .count = 1000 },
});
defer table.deinit();
var fa = morph.Analyzer.initWithFrequencyTable(allocator, &table, 5);
defer fa.deinit();
const c = try fa.analyze("fireman");      // Compound, "fire+man"
// ... free c.result, c.compound_left, c.compound_right

// Rule engine directly
const root = try morph.morphology.newRoot(allocator, "read", .V);
const node = try morph.Rules.V_to_Adj_able.apply(allocator, root); // "readable"
```

`FrequencyTable` can also be loaded from a `word<space>count` text file:

```zig
var table = try morph.FrequencyTable.fromTextFile(allocator, io, "freqs.txt");
```

## Provenance

Extracted from a private research repo (`ZigLinguistics`, Zig 0.15.1) and
migrated to Zig 0.16. All decomposition logic is unchanged from the source; the
work was migration, dependency rewiring, and test refereeing.

Migration items applied:

- Function-type struct fields made pointers (`?fn(...)` -> `?*const fn(...)`)
  in `SuffixRule` / `ProcessRule`.
- `std.ArrayList(T){}` -> `.empty` for the unmanaged-list 0.16 API.
- The bundled Porter/Snowball stemmers were dropped in favor of the external
  [`stemmer`](../stemmer-zig) package (path dependency).

## Descoped

The source repo loaded word frequencies from a custom **mmap'd binary file
format** (`FREQ` magic, v1/v2, zero-copy pointers into mapped memory) via
`initWithFrequencies` / `initWithBinaryFrequencies`. That format was **removed**
during extraction because:

- it is the hardest part of the 0.16 `Io`/`posix.mmap` migration, and
- the binary-container concern is handled elsewhere (safetensors-zig).

It is replaced by `FrequencyTable`: an in-memory `word -> count` map plus a
`stem -> base-word` reverse index, built from a slice/iterator of `(word,
count)` pairs or from a simple text file. The analyzer's `FrequencyBased`
validation and compound detector consume this table. No analyzer capability was
lost — the hybrid pipeline runs fully on the in-memory table.

Also not ported: the source analyzer's parallel `analyzeManyParallel`
thread-pool path (it depended on the bundled-stemmer internals and the
zero-copy mmap'd map). `analyzeMany` (sequential) is retained.

## Test corrections

The source repo's build was broken, so some analyzer test expectations had
**never executed** and were wrong against the engine's own default config
(`rule_validation = .Disabled`, no frequency table). Corrected here, each with
an inline comment citing the evidence:

- `running` — legacy expected Stemmed `"run"`. Under the default config the
  `-ing` rule strips it to `"runn"` and accepts it (the consonant-doubling
  correction that yields `"run"` only fires with a frequency table). Actual:
  RuleBased `"runn"`.
- `relational` — legacy expected Stemmed `"relate"`. The `re-` prefix rule
  strips it to `"lational"` (passes Disabled validation) before the stemmer is
  reached. Actual: RuleBased `"lational"`.

The "stemming fallback" and "bulk analysis" tests were updated to use words
that genuinely reach the stemmer (`feed` -> `"fee"`, `need` -> `"nee"`), since
the original words are intercepted by rules under the default config.

## Verification

```sh
zig build test          # 45 tests: rule engine, analyzer, frequency table,
                        # pattern detector, syntax/phonology, and the
                        # 20-word reference set + validation-mode behavior
```

Requires the `stemmer` package as a sibling path dependency (`../stemmer-zig`).

## Scope limits

- **English / ASCII only.** No Unicode normalization; `std.ascii` throughout.
- **Teaching-grade, not exhaustive.** Rules and combiners model the common
  patterns from the source lecture material (the slide subset), not the full
  irregular inventory of English. Plural allomorphy uses an `s`/`z` heuristic
  from the slides, not full `[s]`/`[z]`/`[ɪz]` phonology.
- The analyzer's affix stripping is a fast heuristic decomposer; with no
  frequency table it accepts any stem >= 3 chars, so it over-segments. Load a
  `FrequencyTable` and use `FrequencyBased` validation for precision.

## License

AGPL-3.0 (see `LICENSE`). Original source is the operator's own work,
relicensed here.
