# Rigol USB Wi-Fi (TP-Link TL-WN725N v3)

Wi-Fi for Rigol instruments built on the Allwinner T3 / Android 7.1 platform (DM858, DG900), using a TP-Link TL-WN725N v3 USB dongle.

The firmware's Android Wi-Fi loader only knows the XR819 chip, so the Android Wi-Fi toggle can never start this dongle, even though the matching driver (`8188eu.ko`) ships in the firmware. `wifi.sh` bypasses Android's Wi-Fi framework: it loads the driver, joins your network with `wpa_supplicant`, gets an address by DHCP, and keeps the link up. Nothing in `/system` is modified.

## What you get, and what you don't

- The instrument is reachable over Wi-Fi: SCPI on port 5025, the web UI on port 8080 and adb on port 55555 were tested; FTP and ssh listen on every interface as well.
- Wi-Fi starts automatically at every boot, reconnects after a dropout, and comes back when the dongle is replugged.
- Android's Wi-Fi switch and network list stay off and empty. The network is chosen in the settings at the top of `wifi.sh`, not in the Android UI.
- Android itself does not know about the Wi-Fi link: with the Ethernet cable unplugged it reports no network, and apps get no DNS. Connections *to* the instrument work either way, which is what remote control needs, and the instrument's own connections to IP addresses go out over Wi-Fi while the cable is unplugged.
- The dongle is 2.4 GHz only. Your network must have a 2.4 GHz band, with WPA2-PSK or no password (WPA3-only networks do not work).

## Files

| File | Purpose |
|---|---|
| `wifi.sh` | The whole tool: settings at the top, the commands below them. |
| `README.md` | This guide. |
| `fix-line-endings.bat` | Converts `wifi.sh` to the LF line endings the instrument needs; double-click it after editing. |
| `.gitattributes` | Keeps `wifi.sh` on LF and the `.bat` on CRLF when the repository is cloned on Windows. |

## Before you start

- The instrument is on your network by Ethernet and reachable with adb: `adb connect <instrument-ip>:55555`. The examples below write it as `192.168.xxx.xxx`; replace it with your instrument's Ethernet address.
- The dongle is plugged into the instrument's USB host port.
- `adb` is installed on your PC.
- Run the commands from **PowerShell or cmd**, in the folder that holds `wifi.sh`. In Git Bash, prefix every `adb push` / `adb pull` with `MSYS_NO_PATHCONV=1`, otherwise Git Bash rewrites `/data/...` into a Windows path.

## Installation

### 1. Set your network

Open `wifi.sh` and replace `YOUR_SSID` and `YOUR_PASSWORD` in the block at the top with your network name and password:

```sh
WIFI_SSID='YOUR_SSID'         # network name to join
WIFI_PSK='YOUR_PASSWORD'      # WPA2 passphrase; empty joins an open network
WIFI_HOSTNAME='DM858'         # name sent to the DHCP server; empty sends none
DRIVER_ARGS=''                # extra 8188eu module parameters, e.g. rtw_power_mgnt=0
```

- Keep the values in single quotes. A single quote inside a value is written as `'\''` (for example `'Bob'\''s net'`).
- Hidden networks work as well; nothing extra to set.
- Save the file with **LF** line endings (VS Code shows `LF` or `CRLF` in the status bar; click it to change). With CRLF the instrument's shell cannot run the script.
- Not sure about your editor? Double-click `fix-line-endings.bat` after saving. It converts `wifi.sh` to LF, removes a UTF-8 BOM if the editor added one, and leaves everything else exactly as you saved it.

### 2. Connect to the instrument

```powershell
adb connect 192.168.xxx.xxx:55555
```

### 3. Copy the script to the instrument

```powershell
adb shell mkdir -p /data/local/wifi
adb push wifi.sh /data/local/wifi/wifi.sh
adb shell chmod 711 /data/local/wifi
adb shell chmod 700 /data/local/wifi/wifi.sh
adb shell sh -n /data/local/wifi/wifi.sh
```

The last command checks the script's syntax on the instrument; it prints nothing when the script is fine. `chmod 700` makes the script readable by root only, since it holds your Wi-Fi password.

### 4. Test it by hand

```powershell
adb shell /data/local/wifi/wifi.sh start
```

Wait about 30 seconds, then:

```powershell
adb shell /data/local/wifi/wifi.sh status
```

A working link shows:

- `watchdog:  running`
- `driver:    8188eu loaded`
- `link:      COMPLETED <your network name>`
- `address:   <the Wi-Fi address>`, for example `192.168.xxx.xxx/16`
- the rules with priorities 9000 and 31000 under `rules:`

Then test from your PC with the Wi-Fi address: open `http://<wifi-address>:8080/` in a browser, or send `*IDN?` to port 5025. If something is missing, see [Troubleshooting](#troubleshooting).

### 5. Start it at every boot

```powershell
adb shell /data/local/wifi/wifi.sh install
```

This adds a line to Rigol's boot script `/rigol/shell/start_rigol_app.sh`, right after its first line, and saves the original as `/data/local/wifi/start_rigol_app.sh.orig`. The script checks the edited boot script with `bash -n` and restores the previous content if the check fails.

Check the result:

```powershell
adb shell head -n 3 /rigol/shell/start_rigol_app.sh
adb shell ls -l /rigol/shell/start_rigol_app.sh
```

The second line of the boot script is the `wifi.sh start` hook, and the file is still `-rwxrwxrwx`. The execute bit matters: without it the Rigol app does not start at boot.

### 6. Reboot and verify

```powershell
adb reboot
```

After the instrument has booted, connect again and run `adb shell /data/local/wifi/wifi.sh status`. It shows `boot hook: installed` and `link: COMPLETED`.

Optional: reserve the Wi-Fi address in your router's DHCP settings for the dongle's MAC address, so the address never changes. `adb shell cat /sys/class/net/wlan0/address` prints the MAC.

## Commands

Run each one as `adb shell /data/local/wifi/wifi.sh <command>`:

| Command | What it does |
|---|---|
| `start` | Starts the watchdog in the background; does nothing if it already runs. |
| `status` | Shows watchdog, driver, DHCP client, interface, link, signal, address, routing rules, boot hook and the last log lines. |
| `stop` | Stops everything, removes the Wi-Fi address and rules, unloads the driver. |
| `run` | Runs the watchdog in the foreground for debugging, when no other watchdog runs; end it with `stop` from a second terminal. |
| `install` | Adds the boot hook (step 5). |
| `uninstall` | Removes the boot hook and stops Wi-Fi. |

The log is `/data/local/wifi/wifi.log`: `adb shell cat /data/local/wifi/wifi.log`.

## Changing the network

Edit the settings in `wifi.sh`, double-click `fix-line-endings.bat`, then:

```powershell
adb push wifi.sh /data/local/wifi/wifi.sh
adb shell chmod 700 /data/local/wifi/wifi.sh
adb shell /data/local/wifi/wifi.sh stop
adb shell /data/local/wifi/wifi.sh start
```

The boot hook does not need to be reinstalled.

## After a Rigol firmware update

A firmware update rewrites the files in `/rigol/`, which can remove the boot hook; `status` then shows `boot hook: not installed`. The script and its settings in `/data/local/wifi` survive. Run `adb shell /data/local/wifi/wifi.sh install` again, then reboot.

## Uninstall

```powershell
adb shell /data/local/wifi/wifi.sh uninstall
adb shell rm -rf /data/local/wifi
```

`uninstall` removes the hook line from the boot script and stops Wi-Fi. A reboot afterwards leaves no trace of it.

## Troubleshooting

`start` refuses to run, and logs why, when the setup cannot work:

- **`set WIFI_SSID ...` or `set WIFI_PSK ...`**: the placeholders from step 1 are still in `wifi.sh`. Fill them in and push the script again.
- **`WIFI_PSK must be 8 to 63 characters`**: WPA2 passwords have that length. For an open network, set `WIFI_PSK=''`.
- **`make the script executable`**: rerun `adb shell chmod 700 /data/local/wifi/wifi.sh`; the DHCP client calls the script back and needs the execute bit.
- **`wifi.sh must run as root`**: the adb shell is not root on this instrument, and this tool needs root.

Keep the quotes in the commands below: they make the `|` run on the instrument, not on your PC.

- **`interface: wlan0 missing`**: the dongle is not plugged in or not detected. `adb shell lsusb` must list `0bda:8179`.
- **`driver: 8188eu not loaded`**: look for `driver 8188eu failed to load` in the log; `adb shell "dmesg | grep -i rtl"` shows the kernel's reason.
- **`link: SCANNING` or `DISCONNECTED` that never changes**: wrong network name, a 5 GHz-only network, or WPA3-only security. `adb shell "iw dev wlan0 scan | grep SSID"` lists the networks the dongle sees.
- **`link:` cycles through `4WAY_HANDSHAKE` and back to `DISCONNECTED`**: wrong password.
- **`link: COMPLETED` but no address**: the router gave no DHCP lease, and the log shows `dhcp: leasefail`. Check the router's DHCP server.
- **`link: no answer from wpa_supplicant`**: wpa_supplicant did not start. `adb shell logcat -d -s wpa_supplicant` shows why.
- **Pings work but replies are slow or lost now and then**: the driver's power saving. Set `DRIVER_ARGS='rtw_power_mgnt=0'`, push the script, then `stop` and `start`.

Leave Android's own Wi-Fi switch off. It cannot drive this dongle, and the script works without it.

## How it works

- Loads `/system/vendor/modules/8188eu.ko`, which creates `wlan0` whenever the dongle is plugged in.
- Writes a `wpa_supplicant` config from the settings and starts the system's `wpa_supplicant` on `wlan0`. Android's build of `wpa_supplicant` does not scan on its own at startup, so the script sends the first scan and repeats it while the link is idle.
- Gets an address with busybox `udhcpc`, which calls `wifi.sh` back on every lease event to set the address and routes.
- Android routes traffic per network and only knows the Ethernet network. The script adds its own routing table, a rule that sends replies from the Wi-Fi address out through `wlan0`, and a low-priority rule that lets Wi-Fi carry traffic when Ethernet is unplugged.
- Ethernet and Wi-Fi usually sit on the same subnet. The script sets `arp_ignore=1` and `arp_announce=2` so each interface answers only for its own address; otherwise Wi-Fi traffic can end up on the cable.
- A watchdog checks every 10 seconds and restarts whatever is missing: driver, `wpa_supplicant`, DHCP client, routing rules.
- At boot, Rigol's `/rigol/shell/start_rigol_app.sh` (run as root by init's `bootApp` service) calls `wifi.sh start` through the hook line.

Security note: once filled in, `wifi.sh` holds your Wi-Fi password in plain text. On the instrument it is readable by root only; on your PC, never commit or upload the filled-in copy.
