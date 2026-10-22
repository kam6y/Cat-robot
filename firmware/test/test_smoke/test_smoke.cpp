#include <unity.h>

#include "catneck/Config.h"

void setUp() {}
void tearDown() {}

void test_config_values() {
    TEST_ASSERT_EQUAL_FLOAT(60.0f, catneck::config::kYawMaxAngle);
    TEST_ASSERT_EQUAL_FLOAT(11.11f, catneck::config::kDefaultGain);
    TEST_ASSERT_EQUAL_UINT32(1500u, catneck::config::kBootIdleMs);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_config_values);
    return UNITY_END();
}
