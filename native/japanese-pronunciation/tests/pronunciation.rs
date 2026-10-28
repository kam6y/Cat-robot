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
        ("1+2", "イチプラスニ"),
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
fn japanese_particles_numbers_and_counters_use_pronunciation() {
    for (input, expected) in [
        ("私は猫です。", "ワタシワネコデス。"),
        ("3人", "サンニン"),
        ("3.14", "サンテンイチヨン"),
        ("25%", "ニジューゴパーセント"),
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
    assert_eq!(frontend().pronounce("が").unwrap(), "ガ");
    assert_eq!(frontend().pronounce("か\u{3099}").unwrap(), "ガ");
    assert_eq!(frontend().pronounce("ｶﾞ").unwrap(), "ガ");
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
    for (input, expected) in [
        ("1,234", "センニヒャクサンジューヨン"),
        ("1,2", "イチ,ニ"),
        ("1,2,3", "イチ,ニ,サン"),
    ] {
        assert_eq!(frontend().pronounce(input).unwrap(), expected, "{input}");
    }
}
