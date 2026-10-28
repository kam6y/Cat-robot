//! Japanese text frontend. Only the returned string changes; callers retain source text.
use jpreprocess::{
    normalize_text_for_naist_jdic, DefaultTokenizer, JPreprocess, SystemDictionaryConfig,
};
use regex::{Captures, Regex};
use std::{ops::Range, path::Path, sync::LazyLock};
use unicode_normalization::UnicodeNormalization;

pub const MAX_INPUT_BYTES: usize = 32_768;

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
    Regex::new(r"(?i)(?-u:\b)(youtuber|youtube|iphone|bluetooth)(?-u:\b)").unwrap()
});
static IDENTIFIERS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z_][A-Za-z0-9_+]*").unwrap());

static GROUPED_NUMBER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[0-9０-９]{1,3}(?:[,，][0-9０-９]{3})+").unwrap());

impl Pronouncer {
    pub fn load(path: &Path) -> Result<Self, Error> {
        let dictionary = SystemDictionaryConfig::File(path.to_path_buf())
            .load()
            .map_err(|_| Error::Dictionary)?;
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
        let mut start = 0;
        let grouped: Vec<Range<usize>> = GROUPED_NUMBER
            .find_iter(text)
            .filter(|m| {
                !text[..m.start()].chars().next_back().is_some_and(is_digit)
                    && !text[m.end()..].chars().next().is_some_and(is_digit)
            })
            .map(|m| m.range())
            .collect();
        let chars: Vec<(usize, char)> = text.char_indices().collect();
        for (index, &(offset, c)) in chars.iter().enumerate() {
            let between_digits = index > 0
                && index + 1 < chars.len()
                && is_digit(chars[index - 1].1)
                && is_digit(chars[index + 1].1);
            let inside_number = (matches!(c, '.' | '．') && between_digits)
                || (matches!(c, ',' | '，') && grouped.iter().any(|r| r.contains(&offset)));
            if is_separator(c) && !inside_number {
                output.push_str(&self.convert_run(&text[start..offset])?);
                output.push(c);
                start = offset + c.len_utf8();
            }
        }
        output.push_str(&self.convert_run(&text[start..])?);
        Ok(())
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
        let composed: String = original.nfc().collect();
        let canonical = ALIASES.replace_all(&composed, |captures: &Captures<'_>| {
            match captures[1].to_ascii_lowercase().as_str() {
                "youtube" => "YouTube",
                "youtuber" => "YouTuber",
                "iphone" => "iPhone",
                _ => "Bluetooth",
            }
        });
        let prepared = verbalize_plus(&canonical);
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
                let isolated = self
                    .frontend
                    .text_to_njd(node.get_string())
                    .map_err(|_| Error::Conversion)?;
                if isolated.nodes.len() == 1 {
                    let known = &isolated.nodes[0];
                    if known.get_string() == node.get_string() && known.get_pron().mora_size() > 0 {
                        *node = known.clone();
                    }
                }
            }
        }
        if njd.nodes.iter().enumerate().any(|(i, node)| {
            let numeric_separator = matches!(node.get_string(), "．" | "，")
                && i > 0
                && i + 1 < njd.nodes.len()
                && njd.nodes[i - 1].get_string().chars().all(is_digit)
                && njd.nodes[i + 1].get_string().chars().all(is_digit);
            node.get_pron().mora_size() == 0 && !numeric_separator
        }) {
            return Ok(original.to_owned());
        }
        njd.preprocess();
        // Despite its name, upstream to_pure_string retains the U+2019
        // devoicing marker. Supertonic accepts kana text, not Open JTalk marks.
        let result: String = njd
            .nodes
            .iter()
            .map(|node| node.get_pron().to_pure_string())
            .collect::<String>()
            .chars()
            .filter(|c| *c != '’')
            .collect();
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
        && text
            .chars()
            .all(|c| letter(c) || is_digit(c) || matches!(c, '_' | '＿' | '+' | '＋'))
}

fn is_digit(c: char) -> bool {
    c.is_ascii_digit() || ('０'..='９').contains(&c)
}
fn is_separator(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '。' | '、'
                | '！'
                | '？'
                | '「'
                | '」'
                | '『'
                | '』'
                | '（'
                | '）'
                | '('
                | ')'
                | '['
                | ']'
                | '{'
                | '}'
                | '【'
                | '】'
                | '〈'
                | '〉'
                | '《'
                | '》'
                | '"'
                | '!'
                | '?'
                | ','
                | '.'
                | '，'
                | '．'
                | ':'
                | ';'
                | '：'
                | '；'
        )
}

fn verbalize_plus(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut cursor = 0;
    for term in IDENTIFIERS.find_iter(text) {
        output.push_str(&text[cursor..term.start()].replace(['+', '＋'], "プラス"));
        output.push_str(term.as_str()); // C++ and unknown ASCII identifiers remain one term.
        cursor = term.end();
    }
    output.push_str(&text[cursor..].replace(['+', '＋'], "プラス"));
    output
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
