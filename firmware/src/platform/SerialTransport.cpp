#include "platform/SerialTransport.h"

#include <Arduino.h>

#include <cstring>

namespace catneck {

bool SerialTransport::readLine(char* buf, size_t cap, size_t& len) {
    while (Serial.available() > 0) {
        const int c = Serial.read();
        if (c < 0) break;
        if (c == '\n') {
            if (overflowing_) {
                overflowing_ = false;
                overflowPending_ = true;
                fill_ = 0;
                len = 0;
                if (cap > 0) buf[0] = '\0';
                return true;
            }
            len = fill_ < cap - 1 ? fill_ : cap - 1;
            std::memcpy(buf, line_, len);
            buf[len] = '\0';
            fill_ = 0;
            return true;
        }
        if (overflowing_) continue;
        if (fill_ < sizeof line_ - 1) {
            line_[fill_++] = static_cast<char>(c);
        } else {
            overflowing_ = true;
        }
    }
    return false;
}

bool SerialTransport::takeOverflow() {
    const bool pending = overflowPending_;
    overflowPending_ = false;
    return pending;
}

void SerialTransport::println(const char* line) { Serial.println(line); }

}  // namespace catneck
