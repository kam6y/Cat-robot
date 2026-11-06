# Japanese pronunciation frontend

This static library is the sole Japanese pronunciation frontend before Supertonic.
It uses jpreprocess 0.15.0 and the matching NAIST dictionary for known Latin terms
and complete large quantities. Other Japanese surface text stays unchanged;
full-sentence kana conversion is intentionally avoided after a user-observed
speech-quality regression.
The caller retains the original display/memory text.

`Pronouncer::pronounce` preserves URLs, email, backtick spans, punctuation and
unknown word clusters. Maximal non-Japanese word clusters prevent partially rewriting
an identifier with accents, combining marks or another script. Only original ASCII/fullwidth
Latin terms are eligible; width folding precedes dictionary lookup. Their digits are read
with the whole term (e.g. iPhone15).
Independent integers of at least five digits, valid three-digit comma groups
(ASCII/fullwidth), and quantities with 万/億/兆/京 use NJD numerical readings.
For example, `1,500,000円` becomes `百五十万円` and `３億５０００万`
becomes `三億五千万`. Surrounding Japanese and counters stay in their
original notation. Normalization precedes Supertonic's comma-based chunking.
Number pronunciations come from the pinned library, with no app-owned numeral
or digit-reading table. One-dot decimals and percentages use NJD's whole-span
pronunciation (`3.14` → `サンテンイチヨン`, `25%` → `ニジューゴパーセント`).
Japanese 10/11-digit zero-leading phone notation uses its standard digit-sequence
reading; labelled IDs select genuine single-digit dictionary inputs. Existing
Supertonic paragraph chunks synthesize each digit separately and supply their
standard inter-chunk silence. The surrounding original context stays in its own
chunks. The paragraph separators count toward the expanded 2,000-character limit. The single
source-label rule distinguishes ID/No./番号/コード/郵便, telephone labels and
explicit version labels (including spaces, colon and particles). Explicit ID
intent wins over a phone-shaped value; genuine telephone labels retain the
standard whole-phone reading.
Valid H:MM is rendered with 時/分; the library spells both fields as kanji,
leading zeros are dropped and zero minutes are omitted. No app-owned counter
pronunciation is introduced.
Ambiguous bare leading-zero strings, dates, versions, ranges, malformed grouping,
grouped decimals and grouped Latin tails retain their notation as complete spans.
Bare unlabelled large integers are quantities; arbitrary identifiers cannot be
inferred semantically. Quantity spans containing more than 24 literal digits remain unchanged because the
next NJD unit 𥝱 is absent from the bundled synthesis vocabulary. Small counters
(`3人で25個`), integer-temperature examples and year inputs retain the prior notation.
Known terms use NJD pronunciation with devoicing marks removed, never phoneme labels.
Case aliases select dictionary spellings, not a hand-maintained pronunciation vocabulary.
Standalone plus means
「プラス」; identifiers and C++ keep their lexical meaning. An operational failure
is an error, never a retry through the old normalizer.

Use Rust 1.90.0. `Cargo.lock` fixes all transitive packages. For host tests:

```sh
JPREPROCESS_DICT=/absolute/path/to/naist-jdic CARGO_TARGET_DIR=.build/jpreprocess-host cargo +1.90.0 test --manifest-path native/japanese-pronunciation/Cargo.toml --locked
```

Tests require the real, hash-checked dictionary; missing assets are not skipped.
Asset preparation and XCFramework packaging are described in the project README.
Generated libraries, toolchains and dictionaries must remain outside tracked source.

The C interface is in `include/CJPPronunciation.h`. One actor/thread owns a handle
and serializes calls. Inputs are valid live pointers; null arguments, invalid UTF-8,
embedded NUL and inputs over 32 KiB are rejected. Outputs are cleared on error.
The caller frees successful strings exactly once with `cjp_string_free` and destroys
the handle exactly once with `cjp_destroy`, after all conversion calls have finished.
Both free functions accept null. Rust panics are contained at the C boundary.

Native input byte limits complement the Swift/engine 2,000-character limit. Swift
also checks expanded output before synthesis, and checks cancellation before/after
synchronous native work; native processing is not forcibly interruptible mid-call.

Dictionary files are mapped read-only and must not be modified while a frontend
handle is alive. The signed app bundle already provides immutable resources.

ID chunking prioritizes complete audibility and adds inference calls. The user
selected it after comparing three realizations of each library-based candidate;
the nine-digit example took about 5.4 seconds to synthesize and 17.4 seconds to
play on the test iPhone. This does not satisfy the general S1 latency target for
that ID case; the S1 definition is unchanged. Very long IDs remain subject to
the existing synthesis-duration limit. See the dated validation record for the
measurements, accepted tradeoff and conservative unsupported forms.

Consecutive malformed unit strings such as `1万万2` and grouped percentages
remain known minor limitations; they are not claimed as fully supported numeric
grammars. The digit cap counts written digits, not a computed value after unit
multiplication. Negative/range retention does not override existing plus verbalization.
