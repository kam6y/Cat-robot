// シリアル経路のテキスト行 → Command（設計書 §4.7）。Arduino 非依存。
#pragma once

#include <cstddef>
#include <cstdint>

#include "catneck/Protocol.h"

namespace catneck {

// Command に変換されない保守操作（Console が直接処理する）
enum class ConsoleAction : uint8_t {
    None,
    Status,
    WatchOn,
    WatchOff,
    Info,
    Help,
    BondsClear,
    PairOpen,
    Gain,
};

struct ParsedLine {
    enum class Kind : uint8_t { Command, Action, Error };
    Kind kind;
    Command command;      // kind == Command のとき有効
    ConsoleAction action; // kind == Action のとき有効
    float gainYaw;        // action == Gain のとき有効（µs/°）
    float gainPitch;
    const char* error;    // kind == Error のとき静的文字列（"BAD_ARGS" / "UNKNOWN" / "RANGE" / 復号エラー名）
};

// 1 行（改行を含まなくてよい。末尾の CR/LF は無視）を解釈する。大文字小文字は区別しない。
// 角度・速度の引数は度（小数可）で、0.1 単位に四捨五入する。
// SAVE で req を省略すると req = 0 を入れて返す（Console が「前回 +1」を埋める印）。
ParsedLine parseLine(const char* line, size_t len);

// `STATUS yaw=<deg> pitch=<deg> flags=0x<hex4> seq=<n> state=<n> err=<n> save=<n>` を out に書く。
// 戻り値は書き込んだ文字数（終端の NUL を除く。cap に収まらない場合は切り詰める）。
size_t formatStatusLine(const Status& status, char* out, size_t cap);

}  // namespace catneck
