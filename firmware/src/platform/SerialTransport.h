// USB CDC（Serial）の行単位の入出力。LF 区切り、CR は Parser 側で無視。
#pragma once

#include <cstddef>

namespace catneck {

class SerialTransport {
public:
    static constexpr size_t kLineCapacity = 200;

    // 1 行そろっていれば buf にコピー（LF を除く、NUL 終端）して true。
    // 行が長すぎた場合は捨てて len = 0 で true を返し、takeOverflow() が一度だけ true になる。
    bool readLine(char* buf, size_t cap, size_t& len);
    bool takeOverflow();
    void println(const char* line);

private:
    char line_[kLineCapacity];
    size_t fill_ = 0;
    bool overflowing_ = false;
    bool overflowPending_ = false;
};

}  // namespace catneck
