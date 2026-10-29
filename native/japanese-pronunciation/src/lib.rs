//! Japanese text frontend. Only the returned string changes; callers retain source text.
use jpreprocess::{normalize_text_for_naist_jdic, DefaultTokenizer, Dictionary, JPreprocess, NJD};
use regex::{Captures, Regex};
use std::{ops::Range, path::Path, sync::LazyLock};
use unicode_normalization::UnicodeNormalization;

pub const MAX_INPUT_BYTES: usize = 32_768;
const CANONICAL_ALIASES: [&str; 4] = ["YouTuber", "YouTube", "iPhone", "Bluetooth"];

#[derive(Debug)]
pub enum Error {
    InvalidInput,
    Dictionary,
    Conversion,
}

pub struct Pronouncer {
    frontend: JPreprocess<DefaultTokenizer>,
}

static PROTECTED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)https?://[^\s<>「」]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}").unwrap()
});
static ALIASES: LazyLock<Regex> = LazyLock::new(|| {
    let names = CANONICAL_ALIASES
        .iter()
        .map(|name| regex::escape(name))
        .collect::<Vec<_>>()
        .join("|");
    Regex::new(&format!(r"(?i)(?-u:\b)({names})(?-u:\b)")).unwrap()
});
static IDENTIFIERS: LazyLock<Regex> = LazyLock::new(|| {
    // Keep foreign-script suffixes and attached marks in the same candidate.
    // Only the ASCII/fullwidth whitelist below is eligible for correction.
    let base = r"[\p{L}\p{N}_＿+＋&&[^\p{Han}\p{Hiragana}\p{Katakana}ーｰﾞﾟ]]";
    let start = r"[\p{L}\p{N}_＿&&[^\p{Han}\p{Hiragana}\p{Katakana}ーｰﾞﾟ]]";
    let atom = format!(r"(?:{base}\p{{M}}*)");
    let segment = format!(r"(?:{start}\p{{M}}*){atom}*");
    // A plus operator cannot open a word or absorb its following quote wrapper.
    // Typographic connectors join a candidate but remain ineligible for rewriting.
    Regex::new(&format!(r"{segment}(?:[-'.－．＇‐‑’]{segment})*")).unwrap()
});

impl Pronouncer {
    pub fn load(path: &Path) -> Result<Self, Error> {
        // Bundled dictionary files are immutable for the lifetime of this frontend.
        let dictionary =
            Dictionary::load_from_path_with_options(path, true).map_err(|_| Error::Dictionary)?;
        Ok(Self {
            frontend: JPreprocess::with_dictionaries(dictionary, None),
        })
    }

    pub fn pronounce(&self, text: &str) -> Result<String, Error> {
        if text.len() > MAX_INPUT_BYTES || text.contains('\0') {
            return Err(Error::InvalidInput);
        }
        let mut result = String::with_capacity(text.len());
        let mut cursor = 0;
        for range in protected_ranges(text) {
            self.convert_plain(&text[cursor..range.start], &mut result)?;
            result.push_str(&text[range.clone()]);
            cursor = range.end;
        }
        self.convert_plain(&text[cursor..], &mut result)?;
        if !text.is_empty() && result.is_empty() {
            return Err(Error::Conversion);
        }
        Ok(result)
    }

    fn convert_plain(&self, text: &str, output: &mut String) -> Result<(), Error> {
        let mut cursor = 0;
        for term in IDENTIFIERS.find_iter(text) {
            output.push_str(&text[cursor..term.start()].replace(['+', '＋'], "プラス"));
            let word = term.as_str();
            if is_latin_word(word) {
                output.push_str(&self.convert_run(word)?);
            } else if word.chars().all(|c| {
                is_digit(c) || matches!(c, '+' | '＋' | '.' | '．' | '-' | '－' | '\'' | '＇')
            }) {
                // Numeric expressions retain their notation; only plus is verbalized.
                output.push_str(&word.replace(['+', '＋'], "プラス"));
            } else {
                output.push_str(word);
            }
            cursor = term.end();
        }
        output.push_str(&text[cursor..].replace(['+', '＋'], "プラス"));
        Ok(())
    }

    fn known_single_word(&self, text: &str, expected_surface: &str) -> Result<Option<NJD>, Error> {
        let njd = self
            .frontend
            .text_to_njd(text)
            .map_err(|_| Error::Conversion)?;
        let known = njd.nodes.len() == 1
            && njd.nodes[0].get_string() == expected_surface
            && njd.nodes[0].get_pron().mora_size() > 0;
        Ok(known.then_some(njd))
    }

    fn verbalize_plus(&self, text: &str) -> Result<String, Error> {
        let mut output = String::with_capacity(text.len());
        let mut cursor = 0;
        for term in IDENTIFIERS.find_iter(text) {
            output.push_str(&text[cursor..term.start()].replace(['+', '＋'], "プラス"));
            let word = term.as_str();
            // Preserve dictionary lexemes such as C++; other suffix/operator plus
            // signs must not fall through to the dictionary's arithmetic タス entry.
            let keep_word = if word.contains('+') {
                self.known_single_word(word, &normalize_text_for_naist_jdic(word))?
                    .is_some()
            } else {
                true
            };
            if keep_word {
                output.push_str(word);
            } else {
                output.push_str(&word.replace('+', "プラス"));
            }
            cursor = term.end();
        }
        output.push_str(&text[cursor..].replace(['+', '＋'], "プラス"));
        Ok(output)
    }

    fn convert_run(&self, original: &str) -> Result<String, Error> {
        if original.is_empty() {
            return Ok(String::new());
        }
        // Unattached voicing marks are silently dropped by upstream normalization.
        // Preserve such a run before any irreversible normalization takes place.
        if original
            .nfkc()
            .any(|c| matches!(c, '\u{3099}' | '\u{309a}' | '\u{309b}' | '\u{309c}'))
        {
            return Ok(original.to_owned());
        }
        // Eligibility was checked on the original characters. Fold width only:
        // compatibility forms such as Roman numerals/ligatures stay untouched.
        let composed: String = original
            .chars()
            .map(|c| {
                if ('\u{ff01}'..='\u{ff5e}').contains(&c) {
                    char::from_u32(c as u32 - 0xfee0).unwrap()
                } else {
                    c
                }
            })
            .collect();
        let canonical = ALIASES.replace_all(&composed, |captures: &Captures<'_>| {
            CANONICAL_ALIASES
                .iter()
                .copied()
                .find(|name| name.eq_ignore_ascii_case(&captures[1]))
                .unwrap_or(&captures[0])
                .to_owned()
        });
        let prepared = self.verbalize_plus(&canonical)?;
        let normalized = normalize_text_for_naist_jdic(&prepared);
        let mut njd = self
            .frontend
            .text_to_njd(&prepared)
            .map_err(|_| Error::Conversion)?;
        // Verify source coverage before NJD removes silent/unknown nodes. Conservative
        // whole-run preservation avoids guessing how changed nodes map to unknown text.
        let covered: String = njd.nodes.iter().map(|node| node.get_string()).collect();
        if covered != normalized || njd.nodes.is_empty() {
            return Ok(original.to_owned());
        }
        // Tokenizer context can prefer an unknown token even for a dictionary word.
        // Recover only an exact, single known Latin-word entry; never guess a reading
        // by splitting an unknown identifier into pronounceable letters.
        for node in &mut njd.nodes {
            if node.get_pron().mora_size() == 0 && is_latin_word(node.get_string()) {
                if let Some(known) = self.known_single_word(node.get_string(), node.get_string())? {
                    *node = known.nodes.into_iter().next().ok_or(Error::Conversion)?;
                }
            }
        }
        if njd
            .nodes
            .iter()
            .any(|node| node.get_pron().mora_size() == 0)
        {
            return Ok(original.to_owned());
        }
        njd.preprocess();
        // Despite its name, upstream to_pure_string retains the U+2019
        // devoicing marker. Supertonic accepts kana text, not Open JTalk marks.
        let mut result: String = njd
            .nodes
            .iter()
            .map(|node| node.get_pron().to_pure_string())
            .collect();
        result.retain(|c| c != '’');
        if result.is_empty()
            || !result
                .chars()
                .all(|c| matches!(c, '\u{30a1}'..='\u{30fa}' | 'ー' | '、' | '？'))
        {
            return Err(Error::Conversion);
        }
        Ok(result)
    }
}

fn is_latin_word(text: &str) -> bool {
    fn letter(c: char) -> bool {
        c.is_ascii_alphabetic() || ('Ａ'..='Ｚ').contains(&c) || ('ａ'..='ｚ').contains(&c)
    }
    text.chars().any(letter)
        && text.chars().all(|c| {
            letter(c)
                || is_digit(c)
                || matches!(
                    c,
                    '_' | '＿' | '+' | '＋' | '-' | '－' | '.' | '．' | '\'' | '＇'
                )
        })
}

fn is_digit(c: char) -> bool {
    c.is_ascii_digit() || ('０'..='９').contains(&c)
}
fn protected_ranges(text: &str) -> Vec<Range<usize>> {
    let mut ranges: Vec<Range<usize>> = PROTECTED.find_iter(text).map(|m| m.range()).collect();
    let mut cursor = 0;
    while let Some(relative) = text[cursor..].find('`') {
        let start = cursor + relative;
        let count = text[start..].bytes().take_while(|c| *c == b'`').count();
        let end_of_open = start + count;
        let delimiter = &text[start..end_of_open];
        let end = text[end_of_open..]
            .find(delimiter)
            .map_or(text.len(), |i| end_of_open + i + count);
        ranges.push(start..end);
        cursor = end;
    }
    ranges.sort_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        if let Some(last) = merged.last_mut() {
            if range.start <= last.end {
                last.end = last.end.max(range.end);
                continue;
            }
        }
        merged.push(range);
    }
    merged
}

pub mod ffi;
