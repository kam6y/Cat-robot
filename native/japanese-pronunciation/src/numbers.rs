//! Admission of complete quantities, before dictionary pronunciation.
use crate::{fold_width, is_digit};
use regex::{Match, Regex};
use std::{ops::Range, sync::LazyLock};

pub(super) struct NumberSpan {
    pub range: Range<usize>,
    pub next_term: usize,
    pub style: Option<NumberStyle>,
}

#[derive(Clone, Copy)]
pub(super) enum NumberStyle {
    Quantity,
    Decimal,
    Percent,
    Phone,
    Time,
    Digits,
}

// 10^24 introduces 𥝱, which the bundled Supertonic indexer cannot encode.
const MAX_QUANTITY_DIGITS: usize = 24;

#[derive(Clone, Copy, PartialEq, Eq)]
enum SourceLabel {
    Identifier,
    Telephone,
    Version,
}

static SOURCE_LABEL: LazyLock<Regex> = LazyLock::new(|| {
    // One source-context rule; width has already been folded.
    Regex::new(r"(?i)(?:(?P<phone>電話(?:番号)?)|(?P<id>番号|コード|郵便(?:番号)?|(?:^|[^a-z])(?:ID|No\.?))|(?P<version>バージョン|(?:^|[^a-z])ver(?:sion)?\.?))[\s:=#はがのを]*$").unwrap()
});

fn digits(text: &str) -> bool {
    !text.is_empty() && text.chars().all(is_digit)
}

fn magnitude(c: char) -> Option<u8> {
    match c {
        '万' => Some(4),
        '億' => Some(8),
        '兆' => Some(12),
        '京' => Some(16),
        _ => None,
    }
}

fn single_magnitude(text: &str) -> Option<u8> {
    let mut chars = text.chars();
    let value = magnitude(chars.next()?)?;
    chars.next().is_none().then_some(value)
}

pub(super) fn number_span(text: &str, terms: &[Match<'_>], first: usize) -> Option<NumberSpan> {
    let term = terms[first];
    if !term.as_str().chars().next().is_some_and(is_digit) {
        return None;
    }
    let prefix = &text[..term.start()];
    let left_blocked = blocked_left(prefix);
    // Inspect original source once: Latin correction can change ID to アイディー.
    let label = source_label(prefix);
    if let Some(span) = semantic_span(text, terms, first, label, left_blocked) {
        return Some(span);
    }
    if !digits(term.as_str()) {
        return None;
    }
    let mut last = first;
    let mut valid = !term.as_str().starts_with(['0', '０']);
    let mut grouped = false;
    let mut units = false;
    let mut previous_unit = u8::MAX;
    let mut group_size = term.as_str().chars().count();
    while let Some(next) = terms.get(last + 1) {
        let gap = &text[terms[last].end()..next.start()];
        if matches!(gap, "," | "，") && next.as_str().chars().next().is_some_and(is_digit) {
            // Consume the entire comma chain even when malformed or when its tail
            // is a decimal/Latin word. Never pronounce a valid-looking prefix.
            valid &= if grouped {
                group_size == 3
            } else {
                group_size <= 3
            };
            grouped = true;
            last += 1;
            group_size = next.as_str().chars().count();
            valid &= digits(next.as_str()) && group_size == 3;
        } else if let Some(unit) = single_magnitude(gap) {
            if !next.as_str().chars().next().is_some_and(is_digit) {
                break;
            }
            valid &= unit < previous_unit
                && digits(next.as_str())
                && !next.as_str().starts_with(['0', '０']);
            previous_unit = unit;
            units = true;
            grouped = false;
            last += 1;
            group_size = next.as_str().chars().count();
        } else {
            break;
        }
    }
    let mut end = terms[last].end();
    if let Some(c) = text[end..]
        .chars()
        .next()
        .filter(|c| magnitude(*c).is_some())
    {
        valid &= magnitude(c).unwrap() < previous_unit;
        units = true;
        end += c.len_utf8();
    }
    let original = &text[term.start()..end];
    let digit_count = original.chars().filter(|c| is_digit(*c)).count();
    let style = (valid
        && (digit_count >= 5 || grouped || units)
        && digit_count <= MAX_QUANTITY_DIGITS
        && !left_blocked
        && label.is_none())
    .then_some(NumberStyle::Quantity);
    Some(finish_span(text, term.start()..end, last + 1, style))
}

fn numeric_colon(mut chars: impl Iterator<Item = char>) -> bool {
    matches!(chars.next(), Some(':' | '：')) && chars.next().is_some_and(is_digit)
}

fn blocked_left(prefix: &str) -> bool {
    prefix.chars().next_back().is_some_and(|c| {
        matches!(
            c,
            ',' | '，' | '/' | '／' | '.' | '．' | '-' | '－' | '−' | '〜' | '～'
        )
    }) || numeric_colon(prefix.chars().rev())
}

fn finish_span(
    text: &str,
    range: Range<usize>,
    next_term: usize,
    style: Option<NumberStyle>,
) -> NumberSpan {
    let suffix = &text[range.end..];
    let style = style.filter(|style| {
        let common = suffix
            .chars()
            .next()
            .is_some_and(|c| matches!(c, '/' | '／' | '-' | '－' | '−' | '〜' | '～'))
            || numeric_colon(suffix.chars());
        let extra = if matches!(style, NumberStyle::Quantity) {
            // The quantity scanner has already consumed comma chains.
            suffix
                .chars()
                .next()
                .is_some_and(|c| matches!(c, '年' | '月' | '日' | '時' | '分' | '秒' | '.' | '．'))
        } else {
            suffix.starts_with([',', '，'])
        };
        !common && !extra
    });
    // A rejected complete semantic span stays consumed. Falling back to Quantity
    // would otherwise rewrite the prefix of e.g. 12345%〜67890%.
    NumberSpan {
        range,
        next_term,
        style,
    }
}

fn source_label(prefix: &str) -> Option<SourceLabel> {
    let start = prefix.char_indices().rev().nth(63).map_or(0, |(i, _)| i);
    let context = fold_width(&prefix[start..]);
    let captures = SOURCE_LABEL.captures(&context)?;
    Some(if captures.name("phone").is_some() {
        SourceLabel::Telephone
    } else if captures.name("id").is_some() {
        SourceLabel::Identifier
    } else {
        SourceLabel::Version
    })
}

fn phone_number(word: &str) -> bool {
    if !word.starts_with('0') || word.starts_with("00") {
        return false;
    }
    let groups: Vec<_> = word.split('-').collect();
    let count = word.chars().filter(char::is_ascii_digit).count();
    word.starts_with('0')
        && !word.starts_with("00")
        && matches!(count, 10 | 11)
        && (groups.len() == 1 || groups.len() == 3)
        && groups
            .iter()
            .all(|g| !g.is_empty() && g.chars().all(|c| c.is_ascii_digit()))
}

fn semantic_span(
    text: &str,
    terms: &[Match<'_>],
    first: usize,
    label: Option<SourceLabel>,
    left_blocked: bool,
) -> Option<NumberSpan> {
    if left_blocked || label == Some(SourceLabel::Version) {
        return None;
    }
    let term = terms[first];
    let suffix = &text[term.end()..];
    let word = fold_width(term.as_str());
    let make =
        |end, next_term, style| Some(finish_span(text, term.start()..end, next_term, Some(style)));
    let identifier_digits = word.chars().all(|c| c.is_ascii_digit() || c == '-')
        && word.chars().any(|c| c.is_ascii_digit())
        && !numeric_colon(suffix.chars())
        && !suffix
            .chars()
            .next()
            .is_some_and(|c| magnitude(c).is_some());
    // Explicit ID intent wins over a telephone-shaped value.
    if label == Some(SourceLabel::Identifier) {
        return if identifier_digits {
            make(term.end(), first + 1, NumberStyle::Digits)
        } else {
            None
        };
    }
    if phone_number(&word) {
        return make(term.end(), first + 1, NumberStyle::Phone);
    }
    if label == Some(SourceLabel::Telephone) && identifier_digits {
        return make(term.end(), first + 1, NumberStyle::Digits);
    }
    if label.is_some() {
        return None;
    }
    let unsigned_integer = !word.is_empty() && word.chars().all(|c| c.is_ascii_digit());
    if unsigned_integer && word.len() <= 2 {
        if let Some(minute) = terms.get(first + 1) {
            let separator = &text[term.end()..minute.start()];
            if matches!(separator, ":" | "：") {
                let minute_word = fold_width(minute.as_str());
                if minute_word.len() == 2
                    && word.parse::<u8>().is_ok_and(|v| v <= 23)
                    && minute_word.parse::<u8>().is_ok_and(|v| v <= 59)
                {
                    return make(minute.end(), first + 2, NumberStyle::Time);
                }
            }
        }
    }
    let decimal = word.split_once('.').is_some_and(|(whole, fraction)| {
        !whole.is_empty()
            && whole.len() <= MAX_QUANTITY_DIGITS
            && !fraction.is_empty()
            && whole.chars().all(|c| c.is_ascii_digit())
            && fraction.chars().all(|c| c.is_ascii_digit())
            && (whole == "0" || !whole.starts_with('0'))
    });
    if (unsigned_integer
        && word.len() <= MAX_QUANTITY_DIGITS
        && (word == "0" || !word.starts_with('0')))
        || decimal
    {
        if let Some(c @ ('%' | '％')) = suffix.chars().next() {
            return make(term.end() + c.len_utf8(), first + 1, NumberStyle::Percent);
        }
    }
    if decimal
        && !suffix
            .chars()
            .next()
            .is_some_and(|c| magnitude(c).is_some())
    {
        return make(term.end(), first + 1, NumberStyle::Decimal);
    }
    None
}
