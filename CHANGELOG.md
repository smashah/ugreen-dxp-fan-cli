# Changelog

## 0.2.1

- Fix one-line installer warning when run through `curl | bash`.
- Restart the auto service during install so upgrades reapply the curve even when the oneshot is already active.
- Skip clearly invalid graph temperature readings such as disconnected `-128c` sensors.

## 0.2.0

- Add `fan graph` terminal history view.
- Add graph collection with `ugreen-fan-graph.timer`, enabled by default.
- Add `fan graph on`, `fan graph off`, `fan graph status`, and `fan graph interval <seconds>`.
- Store compact TSV history with hard 24-hour pruning.
- Expand README credit for `IT-Kuny/UGREEN-DXP-FAN-NAS-Driver`.

## 0.1.0

- Initial public release.
- Add `fan` CLI with auto, full/max, raw PWM, percentage, target temperature, and guarded off modes.
- Add installer, uninstaller, boot-time auto systemd service, and fake-hwmon smoke test.
