# Japanese pronunciation frontend

This static library is the sole Japanese pronunciation frontend before Supertonic.
It uses jpreprocess 0.15.0 and the matching NAIST dictionary. It produces kana text,
not phonemes or Open JTalk full-context labels. Original display/memory text is owned
by the caller and is never edited here.

`Pronouncer::pronounce` preserves URLs, email, backtick spans, punctuation and
unknown runs. Known runs use contextual NJD pronunciation, with Open JTalk devoicing
marks removed. Case aliases select dictionary spellings; they do not contain the
old Swift iPhone/Bluetooth pronunciation substitutions. Standalone plus means
「プラス」; identifiers and C++ keep their lexical meaning. An operational failure
is an error, never a retry through the old normalizer.

Use Rust 1.90.0. `Cargo.lock` fixes all transitive packages. For host tests:

```sh
JPREPROCESS_DICT=/absolute/path/to/naist-jdic cargo test --manifest-path native/japanese-pronunciation/Cargo.toml --locked
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
