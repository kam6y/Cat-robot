# /// script
# requires-python = ">=3.10"
# dependencies = ["bleak==3.0.2"]
# ///
"""Run with uv run tools/test_ble_names.py; no Bluetooth hardware is needed."""
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from ble_client import BleakScanner, find_device, is_cat_robot, run
from catneck_proto import CHAR_INFO, encode_gesture


class DeviceNameTests(unittest.IsolatedAsyncioTestCase):
    async def test_name_selection_matches_the_advertised_name_exactly(self):
        device = SimpleNamespace(name=None)
        adv = SimpleNamespace(local_name="CaRot-5E8E", service_uuids=[])

        async def discover(matches, timeout):
            return device if matches(device, adv) else None

        with patch.object(BleakScanner, "find_device_by_filter", discover):
            self.assertIs(await find_device("CaRot-5E8E", None, 1), device)
            with self.assertRaises(SystemExit):
                await find_device("CatRobot-5E8E", None, 1)

    async def test_unsupported_firmware_is_rejected_before_sending_commands(self):
        device = SimpleNamespace(name="CaRot-1234", address="1234")
        args = SimpleNamespace(cmd="gesture", name=device.name, address=None, scan_timeout=1, connect_timeout=1)
        for version, caps in [(1, 1), (2, 2)]:
            with self.subTest(version=version, caps=caps):
                client = AsyncMock()
                client.read_gatt_char.return_value = bytes([version, 0, 1, 0, 1, caps, 0, 0])
                with patch("ble_client.find_device", new=AsyncMock(return_value=device)), \
                     patch("ble_client.BleakClient", return_value=client):
                    self.assertEqual(await run(args), 1)
                client.read_gatt_char.assert_awaited_once_with(CHAR_INFO)
                client.write_gatt_char.assert_not_awaited()
                client.disconnect.assert_awaited_once()

    def test_gesture_uses_the_pose_command_with_a_neutral_origin(self):
        self.assertEqual(encode_gesture("nod", 15, 2, 100), bytes([10, 1, 150, 2, 100, 0, 0, 0, 0]))

    def test_only_the_current_prefix_identifies_a_board_by_name(self):
        device = SimpleNamespace(name=None)
        for name, expected in [("CaRot-5E8E", True), ("CatRobot-5E8E", False)]:
            with self.subTest(name=name):
                self.assertEqual(is_cat_robot(device, SimpleNamespace(local_name=name, service_uuids=[])), expected)


if __name__ == "__main__":
    unittest.main()
