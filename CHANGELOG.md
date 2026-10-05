# Changelog

## Unreleased

- Support the UGREEN iDX6011 Pro `it5571` EC backend: detect the hwmon device, drive `pwm1`-`pwm4`, use manual PWM 255 for `full`, and hand fans back to the EC firmware curve for `auto`.
- Add `CHANNELS=auto`, which picks fan channels for the detected chip; new installs write it by default. Older `fan` versions reject `CHANNELS=auto`, so set explicit channels before downgrading.
- Warn during install when `ugreen-fan-control.service` is active.
- On it5571, `fan status` shows `-` for PWM while a channel is in EC auto mode.
- On it5571, `fan auto` attempts every channel before reporting a failed hand-back to the EC.

## 0.2.2

- Add install/uninstall smoke tests that run against a temporary root with fake `systemctl`.
- Add test-only installer path overrides so CI can verify generated files and service commands without touching the host.
- Cover stdin/one-line install mode in tests.

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
