# Rigol USB Wi-Fi (TP-Link TL-WN725N v3)

Wi-Fi for Rigol instruments built on the Allwinner T3 / Android 7.1 platform (the DM858 / DM858E multimeters and the DG800 Pro / DG900 Pro waveform generators), using a TP-Link TL-WN725N v3 USB dongle.

The firmware's Android Wi-Fi loader only knows the XR819 chip, so the Android Wi-Fi toggle can never start this dongle, even though the matching driver (`8188eu.ko`) ships in the firmware. `wifi.sh` bypasses Android's Wi-Fi framework: it loads the driver, joins your network with `wpa_supplicant`, gets an address by DHCP, and keeps the link up. Nothing in `/system` is modified.

## What you get, and what you don't

- The instrument is reachable over Wi-Fi: SCPI on port 5025, the web UI on port 8080 and adb on port 55555 were tested; FTP and ssh listen on every interface as well.
- Wi-Fi starts automatically at every boot, reconnects after a dropout, and comes back when the dongle is replugged.
- Android's Wi-Fi switch and network list stay off and empty. The network is chosen in the settings at the top of `wifi.sh`, not in the Android UI.
- Android itself does not know about the Wi-Fi link: with the Ethernet cable unplugged it reports no network, and apps get no DNS. Connections *to* the instrument work either way, which is what remote control needs, and the instrument's own connections to IP addresses go out over Wi-Fi while the cable is unplugged.
- The dongle is 2.4 GHz only. Your network must have a 2.4 GHz band, with WPA2-PSK or no password (WPA3-only networks do not work).

## Supported instruments

| Instrument | Firmware | Tested |
|---|---|---|
| DM858, DM858E | 00.01.00.00.22 | ✅ |
| DG821 Pro, DG822 Pro, DG852 Pro, DG902 Pro, DG912 Pro, DG922 Pro | 00.02.02.00.03 | ✅ |

On the DM858 and the DG922 Pro, the firmware's Android Wi-Fi loader is the XR819-only one, and the matching `8188eu.ko` driver ships with the firmware; the other Pro models run the DG922 Pro's firmware. The original DG800 / DG900 (without "Pro") use a different firmware line and are not covered.

## Files

| File | Purpose |
|---|---|
| `wifi.sh` | The whole tool: settings at the top, the commands below them. |
| `README.md` | This guide. |
| `fix-line-endings.bat` | Converts `wifi.sh` to the LF line endings the instrument needs; double-click it after editing. |
| `.gitattributes` | Keeps `wifi.sh` on LF and the `.bat` on CRLF when the repository is cloned on Windows. |

## Before you start

- The instrument is on your network by Ethernet and reachable with adb: `adb connect <instrument-ip>:55555`. The examples below write it as `192.168.xxx.xxx`; replace it with your instrument's Ethernet address.
- The dongle is plugged into the instrument's USB host port, and it uses the RTL8188EUS chip: on the instrument, `lsusb` lists it as `0bda:8179`. The TL-WN725N v2 and v3 use that chip; some units sold in China use an RTL8188GU chip instead, which the instrument's driver does not support.
- `adb` is installed on your PC.
- Run the commands from **PowerShell or cmd**, in the folder that holds `wifi.sh`. In Git Bash, prefix every `adb push` / `adb pull` with `MSYS_NO_PATHCONV=1`, otherwise Git Bash rewrites `/data/...` into a Windows path.

## Installation

### 1. Set your network

Open `wifi.sh` and replace `YOUR_SSID` and `YOUR_PASSWORD` in the block at the top with your network name and password:

```sh
WIFI_SSID='YOUR_SSID'         # network name to join
WIFI_PSK='YOUR_PASSWORD'      # WPA2 passphrase; empty joins an open network
WIFI_HOSTNAME='DM858'         # name sent to the DHCP server, e.g. 'DM858E' or 'DG922'; empty sends none
DRIVER_ARGS=''                # extra 8188eu module parameters, e.g. rtw_power_mgnt=0
```

- Set `WIFI_HOSTNAME` to a name for this instrument, such as `DM858` or `DG922`. It is the name your router shows for the Wi-Fi connection.
- `DRIVER_ARGS` passes options to the dongle's driver and can stay empty; see [Driver parameters](#driver-parameters).
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

Connect over Ethernet if you can: `uninstall` stops Wi-Fi, so an adb session that runs over Wi-Fi drops halfway through. Step 2 has a variant for when Wi-Fi is your only connection.

### 1. Connect to the instrument

```powershell
adb connect 192.168.xxx.xxx:55555
```

### 2. Remove the boot hook and stop Wi-Fi

```powershell
adb shell /data/local/wifi/wifi.sh uninstall
```

This removes the hook line from `/rigol/shell/start_rigol_app.sh`, then stops the watchdog, `wpa_supplicant` and the DHCP client, removes the Wi-Fi address and routing rules, and unloads the driver.

Connected only over Wi-Fi? Run steps 2 and 4 as one detached command instead, so they finish after the connection drops, then skip to step 5 and reboot with the power button:

```powershell
adb shell "setsid sh -c '/data/local/wifi/wifi.sh uninstall; rm -rf /data/local/wifi' < /dev/null > /dev/null 2>&1 &"
```

### 3. Check the boot script

```powershell
adb shell head -n 3 /rigol/shell/start_rigol_app.sh
adb shell ls -l /rigol/shell/start_rigol_app.sh
```

The `wifi.sh start` line is gone, and the file is still `-rwxrwxrwx`.

### 4. Delete the files

```powershell
adb shell rm -rf /data/local/wifi
```

This also deletes the instrument's copy of your Wi-Fi password and the boot script backup `start_rigol_app.sh.orig`.

### 5. Reboot

```powershell
adb reboot
```

The instrument then starts exactly as it did before the installation.

If you deleted `/data/local/wifi` before running `uninstall`, the hook line left in the boot script does nothing, because it first checks that `wifi.sh` exists. To remove it as well, copy the script back (installation step 3) and run step 2.

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
- **Pings work but replies are slow or lost now and then**: the driver's power saving. Set `DRIVER_ARGS='rtw_power_mgnt=0'`, push the script, then `stop` and `start` (see [Driver parameters](#driver-parameters)).

Leave Android's own Wi-Fi switch off. It cannot drive this dongle, and the script works without it.

## Driver parameters

`DRIVER_ARGS` in `wifi.sh` passes parameters to the `8188eu` driver, separated by spaces:

```sh
DRIVER_ARGS='rtw_power_mgnt=0 rtw_country_code=DE'
```

The driver reads them only when it loads: after a change, push the script and run `stop` and `start`, as in [Changing the network](#changing-the-network). To see the values the running driver uses:

```powershell
adb shell "cd /sys/module/8188eu/parameters && grep . *"
```

The defaults below were read from the running driver on a DG922 Pro; the DM858's driver declares the same parameters. The groups at the top are the ones worth changing; leave the board, calibration and test parameters at their defaults.

| Parameter | Type | Default | What it does |
|---|---|---|---|
| **Power saving** | | | |
| `rtw_power_mgnt` | int | `2` | Power saving while connected: `0` off (radio always awake, fastest replies), `1` minimum, `2` maximum. |
| `rtw_smart_ps` | int | `2` | How the dongle fetches packets the access point held during power saving; only matters when `rtw_power_mgnt` is not `0`. |
| `rtw_ips_mode` | int | `1` | Power saving while not connected, switching the radio off between scans: `0` off. |
| `rtw_enusbss` | int | `0` | USB selective suspend: `1` lets the dongle sleep on the USB bus. |
| `rtw_hwpdn_mode` | int | `2` | Hardware power-down: `0` off, `1` on, `2` from the chip's calibration data. |
| `rtw_hwpwrp_detect` | int | `0` | Hardware power-pin detection: `1` on. |
| **Interface** | | | |
| `ifname` | charp | `wlan%d` | Name of the main interface. If you change it, set `WIFI_IFACE` in `wifi.sh` to match. |
| `if2name` | charp | `wlan%d` | Name of the second interface the driver creates; `wifi.sh` does not use it. |
| `rtw_initmac` | charp | not set | MAC address to use instead of the dongle's own, as `xx:xx:xx:xx:xx:xx`. |
| **Country and channels** | | | |
| `rtw_country_code` | charp | not set | Country code in two letters, e.g. `DE`; selects the allowed channels and power. |
| `rtw_channel_plan` | int | `97` (`0x61`) | Channel plan ID, used when no country code is set. |
| `rtw_80211d` | int | `0` | Follow the country the access point announces (802.11d): `1` on. |
| `rtw_channel` | int | `1` | Channel for ad-hoc mode. |
| **Wireless link** | | | |
| `rtw_ht_enable` | int | `1` | 802.11n support; `0` limits the dongle to 802.11b/g. |
| `rtw_bw_mode` | int | `33` (`0x21`) | Maximum channel width; bits 0-3 for 2.4 GHz, bits 4-7 for 5 GHz: `0` 20 MHz, `1` 40 MHz, `2` 80 MHz. |
| `rtw_wmm_enable` | int | `1` | WMM (Wi-Fi QoS) support. |
| `rtw_ampdu_enable` | int | `1` | A-MPDU aggregation (802.11n): `1` on. |
| `rtw_ampdu_amsdu` | int | `0` | A-MSDU inside A-MPDU: `0` off, `1` on, `2` auto. |
| `rtw_rx_stbc` | int | `1` | Receive STBC: bit 0 for 2.4 GHz, bit 1 for 5 GHz. |
| `rtw_vrtl_carrier_sense` | int | `2` | Virtual carrier sense: `0` off, `1` on, `2` auto. |
| `rtw_vcs_type` | int | `1` | Virtual carrier sense type: `1` RTS/CTS, `2` CTS-to-self. |
| `rtw_qos_opt_enable` | int | `0` | QoS optimization: `1` on. |
| `rtw_busy_thresh` | int | `40` | Traffic level above which the link counts as busy. |
| `rtw_max_roaming_times` | uint | `2` | How many times to try roaming. |
| `rtw_network_mode` | int | `0` | Initial network type; `wpa_supplicant` sets the mode itself. |
| `rtw_usb_rxagg_mode` | int | `2` | USB receive aggregation: `1` DMA, `2` USB. |
| `rtw_lowrate_two_xmit` | int | `1` | Send low rates on both transmit paths; only matters on two-antenna chips. |
| **Access point and Wi-Fi Direct** | | | |
| `rtw_hiq_filter` | uint | `1` | Access-point mode, high-priority queue filter: `0` allow all, `1` allow special, `2` deny all. |
| `rtw_mc2u_disable` | int | `0` | Access-point mode: `1` stops converting multicast to unicast. |
| `rtw_full_ch_in_p2p_handshake` | int | `0` | Wi-Fi Direct: offer every channel during the handshake. |
| `rtw_hw_wps_pbc` | int | `1` | Hardware WPS push button. |
| **Transmit power and regulatory** | | | |
| `rtw_tx_pwr_lmt_enable` | int | `0` | Regulatory transmit power limits: `0` off, `1` on, `2` from the chip's calibration data. |
| `rtw_tx_pwr_by_rate` | int | `0` | Transmit power by rate: `0` off, `1` on, `2` from the chip's calibration data. |
| `rtw_target_tx_pwr_2g_a` | array of int | empty | Target 2.4 GHz transmit power in dBm per rate section, RF path A; `-1` undefined. |
| `rtw_target_tx_pwr_2g_b` | array of int | empty | Target 2.4 GHz transmit power in dBm per rate section, RF path B; `-1` undefined. |
| `rtw_target_tx_pwr_2g_c` | array of int | empty | Target 2.4 GHz transmit power in dBm per rate section, RF path C; `-1` undefined. |
| `rtw_target_tx_pwr_2g_d` | array of int | empty | Target 2.4 GHz transmit power in dBm per rate section, RF path D; `-1` undefined. |
| `rtw_adaptivity_en` | uint | `0` | Adaptivity (EDCCA, listen before talk): `0` off, `1` on. |
| `rtw_adaptivity_mode` | uint | `0` | Adaptivity mode: `0` normal, `1` carrier sense. |
| `rtw_adaptivity_dml` | uint | `0` | Adaptivity DML: `0` off, `1` on. |
| `rtw_adaptivity_dc_backoff` | uint | `2` | DC backoff for adaptivity (EDCCA, required by some regulators). |
| `rtw_adaptivity_th_l2h_ini` | int | `0` | Adaptivity threshold: TH_L2H_ini. |
| `rtw_adaptivity_th_edcca_hl_diff` | int | `0` | Adaptivity threshold: TH_EDCCA_HL_diff. |
| **Board and calibration (leave at default)** | | | |
| `rtw_rf_config` | int | `15` | RF path configuration; `15` reads it from the chip. |
| `rtw_special_rf_path` | int | `0` | Force a single RF path on two-path chips. |
| `rtw_antdiv_cfg` | int | `2` | Antenna diversity: `0` off, `1` on, `2` from the chip's calibration data. |
| `rtw_antdiv_type` | int | `0` | Antenna diversity type: `0` from the chip's calibration data. |
| `rtw_amplifier_type_2g` | uint | `0` | External amplifiers on the board: BIT3 2.4 GHz PA, BIT4 2.4 GHz LNA. |
| `rtw_amplifier_type_5g` | uint | `0` | External amplifiers on the board: BIT6 5 GHz PA, BIT7 5 GHz LNA. |
| `rtw_RFE_type` | uint | `64` (`0x40`) | RF front-end type of the board. |
| `rtw_GLNA_type` | uint | `0` | External LNA type on the board. |
| `rtw_TxBBSwing_2G` | uint | `255` (`0xFF`) | Transmit baseband swing, 2.4 GHz; `0xFF` uses the default. |
| `rtw_TxBBSwing_5G` | uint | `255` (`0xFF`) | Transmit baseband swing, 5 GHz; `0xFF` uses the default. |
| `rtw_pwrtrim_enable` | int | `0` | Transmit power trim from the chip's calibration data. |
| `rtw_OffEfuseMask` | uint | `0` | Efuse (calibration data) mask switch. |
| `rtw_FileMaskEfuse` | uint | `0` | Efuse (calibration data) mask taken from a file. |
| `rtw_pll_ref_clk_sel` | uint | `15` (`0xF`) | PLL reference clock; `0xF` uses the chip's own setting. |
| `rtw_notch_filter` | uint | `0` | Notch filter: `0` off, `1` on, `2` only for Wi-Fi Direct. |
| `rtw_load_phy_file` | int | `68` (`0x44`) | Which PHY parameter files to load from disk (bit map). |
| `rtw_decrypt_phy_file` | int | `0` | Decrypt the PHY parameter file: `1` on. |
| `rtw_phy_file_path` | charp | empty | Folder of the PHY parameter files. |
| **Test and internal (leave at default)** | | | |
| `rtw_mp_mode` | int | `0` | Factory test (MP) mode; leave at `0`. |
| `rtw_wifi_spec` | int | `0` | Wi-Fi certification test mode; leave at `0`. |
| `rtw_lbkmode` | int | `0` | Loopback test mode; leave at `0`. |
| `rtw_chip_version` | int | `0` | Internal; leave at `0`. |
| `rtw_rfintfs` | int | `2` | Internal; leave at `2`. |
| `rtw_low_power` | int | `0` | Internal; leave at `0`. |
| `rtw_fw_iol` | int | `1` | Firmware IO offload: `0` off, `1` on, `2` by USB speed. |
| `rtw_switch_usb3` | int | `0` | Switch the chip to USB 3.0; USB 3.0 chips only. |

## How it works

- Loads `/system/vendor/modules/8188eu.ko`, which creates `wlan0` whenever the dongle is plugged in.
- Writes a `wpa_supplicant` config from the settings and starts the system's `wpa_supplicant` on `wlan0`. Android's build of `wpa_supplicant` does not scan on its own at startup, so the script sends the first scan and repeats it while the link is idle.
- Gets an address with busybox `udhcpc`, which calls `wifi.sh` back on every lease event to set the address and routes.
- Android routes traffic per network and only knows the Ethernet network. The script adds its own routing table, a rule that sends replies from the Wi-Fi address out through `wlan0`, and a low-priority rule that lets Wi-Fi carry traffic when Ethernet is unplugged.
- Ethernet and Wi-Fi usually sit on the same subnet. The script sets `arp_ignore=1` and `arp_announce=2` so each interface answers only for its own address; otherwise Wi-Fi traffic can end up on the cable.
- A watchdog checks every 10 seconds and restarts whatever is missing: driver, `wpa_supplicant`, DHCP client, routing rules.
- At boot, Rigol's `/rigol/shell/start_rigol_app.sh` (run as root by init's `bootApp` service) calls `wifi.sh start` through the hook line.

Security note: once filled in, `wifi.sh` holds your Wi-Fi password in plain text. On the instrument it is readable by root only; on your PC, never commit or upload the filled-in copy.
