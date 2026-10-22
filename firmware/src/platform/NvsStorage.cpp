#include "platform/NvsStorage.h"

namespace catneck {
namespace {
constexpr const char* kNamespace = "catneck";
constexpr const char* kKey = "cal";

bool sameBlob(const CalBlob& a, const CalBlob& b) {
    return a.version == b.version && a.yawOffDeci == b.yawOffDeci && a.pitchOffDeci == b.pitchOffDeci &&
           a.invert == b.invert && a.yawGainCenti == b.yawGainCenti && a.pitchGainCenti == b.pitchGainCenti &&
           a.crc16 == b.crc16;
}
}  // namespace

bool NvsStorage::begin() {
    ready_ = prefs_.begin(kNamespace, false);
    return ready_;
}

bool NvsStorage::save(const CalBlob& blob) {
    if (!ready_) return false;
    if (prefs_.putBytes(kKey, &blob, sizeof blob) != sizeof blob) return false;
    CalBlob back{};
    if (prefs_.getBytes(kKey, &back, sizeof back) != sizeof back) return false;
    return sameBlob(back, blob);
}

bool NvsStorage::load(CalBlob& out) {
    if (!ready_) return false;
    if (prefs_.getBytesLength(kKey) != sizeof(CalBlob)) return false;
    return prefs_.getBytes(kKey, &out, sizeof out) == sizeof out;
}

}  // namespace catneck
