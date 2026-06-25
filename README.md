# UGREEN DXP Fan CLI

Simple fan control CLI for UGREEN DXP NAS systems running Debian or Proxmox with the IT8613E `it87` hwmon driver.

This repo does not replace the kernel driver. It installs a clean `fan` command and a boot service that applies a safe hardware-auto curve by default.

Big credit goes to [IT-Kuny/UGREEN-DXP-FAN-NAS-Driver](https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver). That project did the hard hardware-driver work that makes this CLI possible; this repo is a user-facing control layer on top of it.

Tested on:

- UGREEN DXP4800 Plus
- Proxmox VE 8.4
- IT8613E exposed through the out-of-tree `it87` driver
- Fan channels `pwm2` and `pwm3`

## Install

First install and load the UGREEN-compatible `it87` driver. The hardware should expose an `it8613` device under `/sys/class/hwmon`.

Then install this CLI:

```sh
curl -fsSL https://raw.githubusercontent.com/smashah/ugreen-dxp-fan-cli/main/install.sh | sudo bash
```

The installer:

- installs `/usr/local/bin/fan`
- installs `/usr/local/sbin/ugreen-fan-mode` as a compatibility symlink
- writes `/etc/ugreen-fan.conf`
- writes `it87` module-load config
- creates and enables `ugreen-fan-auto.service`
- creates and enables `ugreen-fan-graph.timer`
- applies `fan auto` immediately
- starts graph collection immediately

Default auto target is `35c`. To install with a different target:

```sh
curl -fsSL https://raw.githubusercontent.com/smashah/ugreen-dxp-fan-cli/main/install.sh | sudo bash -s -- --target 40
```

Graph collection is enabled by default at a 10-second interval. To change that during install:

```sh
curl -fsSL https://raw.githubusercontent.com/smashah/ugreen-dxp-fan-cli/main/install.sh | sudo bash -s -- --graph-interval 30
```

To install without graph collection:

```sh
curl -fsSL https://raw.githubusercontent.com/smashah/ugreen-dxp-fan-cli/main/install.sh | sudo bash -s -- --no-graph
```

## Usage

```sh
fan              # show current mode, PWM values, RPMs, curve, and sensors output
fan status       # same as above
fan auto         # apply saved hardware auto curve
fan 35c          # save/apply auto target temperature
fan auto 35c     # same as fan 35c
fan full         # full-speed mode
fan max          # same as fan full
fan 255          # manual raw PWM value
fan 50%          # manual percentage
fan off --yes    # manual PWM 0, guarded because it can overheat the NAS
fan graph        # terminal graph for the last 24h
fan graph status # graph config, timer state, and sample count
fan graph on     # enable graph collection
fan graph off    # disable graph collection
fan graph interval 30 # poll every 30 seconds
```

`fan 35c` persists the target in `/etc/ugreen-fan.conf`, so the same target is used by the boot service.

`fan 255` may show as `full` on this driver. That is expected: the IT8613E `it87` driver reports max duty as full-speed mode.

## Auto Curve

For the default `35c` target the CLI programs:

| Channel | Sensor | Point 1 | Point 2 | Point 3 | Start PWM |
| --- | --- | ---: | ---: | ---: | ---: |
| `pwm2` | `temp1` | `30c` | `35c` | `55c` | `180` |
| `pwm3` | `temp2` | `25c` | `32c` | `42c` | `150` |

Changing the target shifts the curve:

- `pwm2`: `target - 5c`, `target`, `target + 20c`
- `pwm3`: `target - 10c`, `target - 3c`, `target + 7c`

This is intentionally conservative. On the DXP4800 Plus tested, the previous invalid/weak auto settings let the CPU package hit the thermal limit. This curve keeps hardware auto mode but gives it a more useful fan response.

## Services

Check the boot service:

```sh
systemctl status ugreen-fan-auto.service
```

The service runs:

```sh
/usr/local/bin/fan auto
```

It is a one-shot service, so `active (exited)` is normal.

Graph collection uses a timer:

```sh
systemctl status ugreen-fan-graph.timer
```

The timer runs a short one-shot service:

```sh
/usr/local/bin/fan graph collect
```

There is no resident graph daemon. Each collection reads hwmon values once, appends one compact TSV row, and prunes history older than 24 hours.

The installer disables `fancontrol.service` only when the service exists but `/etc/fancontrol` is empty or missing. If CoolerControl or another fan manager is actively controlling these channels, disable that policy or it can overwrite `fan`.

## Configuration

`/etc/ugreen-fan.conf`:

```sh
AUTO_TARGET_C=35
CHANNELS="pwm2 pwm3"
GRAPH_ENABLED=1
GRAPH_INTERVAL_SEC=10
HISTORY_FILE="/var/lib/ugreen-fan/history.tsv"
```

The defaults are for the DXP4800 Plus. If another UGREEN DXP model exposes different PWM channels, update `CHANNELS`.

## Fan Graph

Graph history is enabled by default and polls every 10 seconds:

```sh
fan graph
```

The graph stores only the last 24 hours. At the default interval that is at most 8640 samples. The history file is intentionally small, plain text, and pruned on every collection:

```sh
/var/lib/ugreen-fan/history.tsv
```

Useful commands:

```sh
fan graph status
sudo fan graph off
sudo fan graph on
sudo fan graph interval 30
```

`fan graph interval` accepts 5 to 3600 seconds. Longer intervals reduce writes and sample count. Shorter intervals below 5 seconds are rejected.

## Uninstall

```sh
sudo ./uninstall.sh
```

Or keep config files:

```sh
sudo ./uninstall.sh --keep-config
```

## Development

Run syntax checks and the fake-hwmon smoke test:

```sh
bash -n fan install.sh uninstall.sh tests/smoke.sh
bash tests/smoke.sh
```

## Safety

Fan control can overheat hardware. Keep `fan status` open and watch temperatures after changing modes. `fan off --yes` exists for testing only and should not be used unattended.

## Credits

This project depends on and is inspired by the UGREEN DXP `it87` driver work from [IT-Kuny/UGREEN-DXP-FAN-NAS-Driver](https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver). Please star and credit that repository too; without it, this CLI would not be useful.
