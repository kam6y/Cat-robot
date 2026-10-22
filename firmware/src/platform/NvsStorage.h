// キャリブレーションの永続化（Preferences、名前空間 "catneck"、キー "cal"。設計書 §4.8）
#pragma once

#include <Preferences.h>

#include "catneck/Supervisor.h"

namespace catneck {

class NvsStorage : public Storage {
public:
    bool begin();
    bool save(const CalBlob& blob) override;  // 書き込み後に読み戻して一致したら true
    bool load(CalBlob& out) override;

private:
    Preferences prefs_;
    bool ready_ = false;
};

}  // namespace catneck
