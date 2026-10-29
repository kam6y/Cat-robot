use cjp_pronunciation::Pronouncer;
use std::{path::PathBuf, sync::OnceLock};

fn frontend() -> &'static Pronouncer {
    static INSTANCE: OnceLock<Pronouncer> = OnceLock::new();
    INSTANCE.get_or_init(|| {
        let path =
            PathBuf::from(std::env::var("JPREPROCESS_DICT").expect("JPREPROCESS_DICT is required"));
        assert!(
            path.join("metadata.json").is_file(),
            "real dictionary required"
        );
        Pronouncer::load(&path).expect("dictionary loads")
    })
}

#[test]
fn dictionary_reads_service_names_and_case_aliases() {
    for (input, expected) in [
        ("YouTube", "ユーチューブ"),
        ("youtube", "ユーチューブ"),
        ("YOUTUBE", "ユーチューブ"),
        ("YouTuber", "ユーチューバー"),
        ("youtuber", "ユーチューバー"),
        ("iPhone", "アイフォーン"),
        ("IPHONE", "アイフォーン"),
        ("Bluetooth", "ブルートゥース"),
        ("bluetooth", "ブルートゥース"),
    ] {
        assert_eq!(
            frontend()
                .pronounce(input)
                .unwrap_or_else(|e| panic!("{input}: {e:?}")),
            expected,
            "{input}"
        );
    }
}

#[test]
fn plus_operator_does_not_corrupt_cpp_or_identifiers() {
    for (input, expected) in [
        ("+", "プラス"),
        ("＋", "プラス"),
        ("+ボタン", "プラスボタン"),
        ("1+2", "1プラス2"),
        ("C++", "シープラスプラス"),
        ("c++", "シープラスプラス"),
        ("Ｃ＋＋", "シープラスプラス"),
        ("zzqx+identifier", "zzqx+identifier"),
        ("myYouTube_id", "myYouTube_id"),
    ] {
        assert_eq!(
            frontend()
                .pronounce(input)
                .unwrap_or_else(|e| panic!("{input}: {e:?}")),
            expected,
            "{input}"
        );
    }
}

#[test]
fn japanese_particles_numbers_and_counters_preserve_surface() {
    for (input, expected) in [
        ("私は猫です。", "私は猫です。"),
        ("3人", "3人"),
        ("3.14", "3.14"),
        ("25%", "25%"),
    ] {
        assert_eq!(
            frontend()
                .pronounce(input)
                .unwrap_or_else(|e| panic!("{input}: {e:?}")),
            expected,
            "{input}"
        );
    }
}

#[test]
fn protected_spans_and_punctuation_remain_exact() {
    for input in [
        "https://example.test/?q=YouTube+Bluetooth",
        "HTTPS://example.test/iPhone",
        "a+youtube@example.test",
        "`YouTube + iPhone`",
        "```\nBluetooth。\n```",
        "`unclosed YouTube +",
        "  \n\t",
        "「」、。！？()[]",
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), input, "{input}");
    }
    assert_eq!(
        frontend().pronounce("「YouTube」\nBluetooth。 ").unwrap(),
        "「ユーチューブ」\nブルートゥース。 "
    );
}

#[test]
fn unknown_content_never_disappears() {
    for input in [
        "zzqx987",
        "前zzqx987後",
        "𠮷𠮷",
        "👩🏽‍🚀",
        "YouTube👩🏽‍🚀",
        "゙",
        "あ゙",
        "\u{ff9e}",
    ] {
        let output = frontend().pronounce(input).unwrap();
        let required = if input.contains("👩") {
            "👩🏽‍🚀"
        } else {
            input
        };
        assert!(
            output.contains(required),
            "{input:?} lost content: {output:?}"
        );
    }
}

#[test]
fn combining_kana_is_read_without_losing_valid_voicing() {
    assert_eq!(frontend().pronounce("が").unwrap(), "が");
    assert_eq!(frontend().pronounce("か\u{3099}").unwrap(), "か\u{3099}");
    assert_eq!(frontend().pronounce("ｶﾞ").unwrap(), "ｶﾞ");
}

#[test]
fn invalid_or_oversized_input_is_an_error() {
    assert!(frontend().pronounce("a\0b").is_err());
    assert!(frontend().pronounce(&"a".repeat(32_769)).is_err());
}

#[test]
fn missing_dictionary_cannot_silently_become_passthrough() {
    assert!(Pronouncer::load(std::path::Path::new("/missing-catrobot-dictionary")).is_err());
}

#[test]
fn numeric_grouping_is_distinct_from_a_comma_separated_list() {
    for (input, expected) in [("1,234", "1,234"), ("1,2", "1,2"), ("1,2,3", "1,2,3")] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
}

#[test]
fn known_english_word_is_recovered_when_context_selects_unknown_token() {
    assert_eq!(
        frontend().pronounce("iPhoneとBluetooth。").unwrap(),
        "アイフォーンとブルートゥース。"
    );
    assert_eq!(
        frontend()
            .pronounce("iPhoneケースとBluetoothを使う。")
            .unwrap(),
        "アイフォーンケースとブルートゥースを使う。"
    );
}

#[test]
fn service_and_expression_suffix_plus_is_not_read_as_tasu() {
    for (input, expected) in [
        ("Disney+を見よう。", "ディズニープラスを見よう。"),
        ("Apple TV+", "アップル テレビプラス"),
        ("A+", "エイプラス"),
        ("A+B", "エイプラスビー"),
        ("x+1", "エックスプラスイチ"),
        ("g++", "ジープラスプラス"),
        ("i++", "アイプラスプラス"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
}

#[test]
fn known_punctuation_keeps_neighboring_corrections_active() {
    for (input, expected) in [
        ("+ボタンを押してね♪", "プラスボタンを押してね♪"),
        ("+ボタンを押してね〜", "プラスボタンを押してね〜"),
        ("YouTubeを見よう…", "ユーチューブを見よう…"),
        ("YouTube・Netflix", "ユーチューブ・ネットフリックス"),
        ("1+2=3", "1プラス2=3"),
        ("3〜5個", "3〜5個"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
    for mark in [
        '…', '‥', '・', '･', '〜', '～', '♪', '♫', '＝', '=', '※', '→', '←', '☆', '★', '♡', '♥',
    ] {
        let input = format!("+{mark}YouTube");
        let expected = format!("プラス{mark}ユーチューブ");
        assert_eq!(frontend().pronounce(&input).unwrap(), expected, "{input}");
    }
}

#[test]
fn punctuation_width_and_typographic_variants_keep_corrections() {
    for (input, expected) in [
        ("+ボタンを押してね｡", "プラスボタンを押してね｡"),
        ("｢+ボタン｣", "｢プラスボタン｣"),
        ("YouTube､Bluetooth", "ユーチューブ､ブルートゥース"),
        ("iPhone｡", "アイフォーン｡"),
        ("“YouTube”を見よう", "“ユーチューブ”を見よう"),
        ("［YouTube］を見よう", "［ユーチューブ］を見よう"),
        ("YouTube—見よう", "ユーチューブ—見よう"),
        ("‘YouTube’", "‘ユーチューブ’"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
    // Independent width/quote family oracle, not the production separator table.
    for mark in [
        '。', '｡', '、', '､', '「', '｢', '」', '｣', '[', '［', ']', '］', '{', '｛', '}', '｝',
        '"', '＂', '“', '”', '‘', '’', '—', '―',
    ] {
        let input = format!("+{mark}YouTube");
        let expected = format!("プラス{mark}ユーチューブ");
        assert_eq!(frontend().pronounce(&input).unwrap(), expected, "{input}");
    }
}

#[test]
fn japanese_surfaces_remain_intact_for_natural_speech() {
    for original in [
        "こんにちは。今日も一緒に遊ぼうね。",
        "辛いカレーが好きだよ。",
        "3人で25個を分けるよ。",
        "今日は25℃だよ。",
        "7:30に起こしてね。",
        "がか\u{3099}ｶﾞ。",
    ] {
        assert_eq!(
            frontend().pronounce(original).unwrap(),
            original,
            "{original}"
        );
    }
}

#[test]
fn latin_readings_preserve_surrounding_japanese_surface() {
    for (input, expected) in [
        (
            "YouTubeで動画を見て、友達と共有するよ。",
            "ユーチューブで動画を見て、友達と共有するよ。",
        ),
        (
            "iPhoneケースとBluetoothを使う。",
            "アイフォーンケースとブルートゥースを使う。",
        ),
        (
            "Netflixで映画を見よう。",
            "ネットフリックスで映画を見よう。",
        ),
        ("3人でYouTubeを見よう。", "3人でユーチューブを見よう。"),
        ("YouTube👩🏽‍🚀を見よう。", "ユーチューブ👩🏽‍🚀を見よう。"),
        ("前zzqx987後YouTube。", "前zzqx987後ユーチューブ。"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
}

#[test]
fn unicode_latin_and_fullwidth_terms_are_not_partially_rewritten() {
    for (input, expected) in [
        ("ＹｏｕＴｕｂｅを見よう。", "ユーチューブを見よう。"),
        ("Ｃ＋＋で書こう。", "シープラスプラスで書こう。"),
        ("zzqxéを使う。", "zzqxéを使う。"),
        ("YouTubeéを使う。", "YouTubeéを使う。"),
        ("YouTube\u{0301}を使う。", "YouTube\u{0301}を使う。"),
        ("zzqx\u{0301}を使う。", "zzqx\u{0301}を使う。"),
        ("zzqx+identifierを使う。", "zzqx+identifierを使う。"),
        ("YouTubeαを使う。", "YouTubeαを使う。"),
        ("ЯYouTubeを使う。", "ЯYouTubeを使う。"),
        ("YouTube+zzqxを使う。", "YouTube+zzqxを使う。"),
        ("zzqx+YouTubeを使う。", "zzqx+YouTubeを使う。"),
        (
            "Ｂｌｕｅｔｏｏｔｈ\u{0301}を使う。",
            "Ｂｌｕｅｔｏｏｔｈ\u{0301}を使う。",
        ),
        ("m²の第Ⅳ章。", "m²の第Ⅳ章。"),
        ("YouTubeーを見よう。", "ユーチューブーを見よう。"),
        ("Wi-Fiで動画を見よう。", "ワイファイで動画を見よう。"),
        ("don'tとe-mail。", "don'tとe-mail。"),
        (
            "25cmの長さと5G。",
            "ニジューゴセンチメートルの長さとゴジー。",
        ),
        ("iPhone15を使う。", "アイフォーンジューゴを使う。"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
}

#[test]
fn halfwidth_japanese_voicing_keeps_latin_neighbor_correction() {
    for (input, expected) in [
        ("ｶﾞYouTube", "ｶﾞユーチューブ"),
        ("YouTubeｶﾞ", "ユーチューブｶﾞ"),
        ("ﾊﾟBluetooth", "ﾊﾟブルートゥース"),
        ("Bluetoothﾊﾟ", "ブルートゥースﾊﾟ"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
}

#[test]
fn typographic_internal_connectors_do_not_split_unknown_terms() {
    for (input, expected) in [
        ("YouTube‐zzqxを使う。", "YouTube‐zzqxを使う。"),
        ("YouTube‑αを使う。", "YouTube‑αを使う。"),
        ("YouTube’zzqxを使う。", "YouTube’zzqxを使う。"),
        ("C++‑zzqxを使う。", "C++‑zzqxを使う。"),
        ("‘YouTube’を見よう。", "‘ユーチューブ’を見よう。"),
        ("“YouTube”を見よう。", "“ユーチューブ”を見よう。"),
        ("YouTube—見よう。", "ユーチューブ—見よう。"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
}
