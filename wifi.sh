#!/system/bin/sh
## @file wifi.sh
## @brief Run a TP-Link TL-WN725N v3 (RTL8188EUS) USB Wi-Fi dongle on a Rigol DM858 / DG900 outside Android's Wi-Fi framework.
## @note Commands: start, run, stop, status, install, uninstall - see README.md.
##       udhcpc calls this file back with deconfig, bound, renew, leasefail or nak.

#& Settings
WIFI_SSID='YOUR_SSID'         # network name to join
WIFI_PSK='YOUR_PASSWORD'      # WPA2 passphrase; empty joins an open network
WIFI_HOSTNAME='DM858'         # name sent to the DHCP server; empty sends none
DRIVER_ARGS=''                # extra 8188eu module parameters, e.g. rtw_power_mgnt=0

#& Paths
WIFI_IFACE='wlan0'                                     # station interface the 8188eu driver creates
DRIVER_NAME='8188eu'                                   # module name as /proc/modules lists it
DRIVER_PATH='/system/vendor/modules/8188eu.ko'         # RTL8188EUS driver shipped in the firmware
BASE_DIR='/data/local/wifi'                            # install dir: this script, its log and pid files
SUPPLICANT_DIR="$BASE_DIR/supplicant"                  # wpa_supplicant config and control socket
SUPPLICANT_CONF="$SUPPLICANT_DIR/wpa_supplicant.conf"  # config generated from the settings
LOOP_PID_FILE="$BASE_DIR/wifi.pid"                     # pid of the watchdog
DHCP_PID_FILE="$BASE_DIR/udhcpc.pid"                   # pid of the DHCP client
LOG_FILE="$BASE_DIR/wifi.log"                          # event log
LOG_MAX_BYTES=262144                                   # log size that rotates it to wifi.log.old
POLL_SECONDS=10                                        # watchdog period
HOOK_TARGET='/rigol/shell/start_rigol_app.sh'          # Rigol boot script that init runs as root at every boot
HOOK_BACKUP="$BASE_DIR/start_rigol_app.sh.orig"        # copy of the boot script taken by install
#? netd numbers its per-interface tables from 1000 up and its legacy tables 97 to 99, so 200 never collides with Android's routing.
ROUTE_TABLE=200                                        # policy routing table for the Wi-Fi link
#? 9000 sits ahead of every netd rule, so replies from the Wi-Fi address leave through wlan0 even while Ethernet is the default network.
RULE_PREF_SOURCE=9000                                  # rule priority for traffic sourced from the Wi-Fi address
#? 31000 sits just before netd's unreachable rule at 32000, so wlan0 only carries traffic no Ethernet rule claims.
RULE_PREF_FALLBACK=31000                               # rule priority for traffic nothing else routes
SELF="$(readlink -f "$0")"                             # absolute path udhcpc and the boot hook call
HOOK_LINE="[ -f $SELF ] && /system/bin/sh $SELF start > /dev/null 2>&1 &  # start the USB Wi-Fi watchdog (rigol_wifi)"  # line install adds to HOOK_TARGET

#& Private Functions

## @brief Append a timestamped line to LOG_FILE, rotating it to LOG_FILE.old past LOG_MAX_BYTES.
## @param $* Message text.
wifi_log() {
    #- Rotate an oversized log
    if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -gt "$LOG_MAX_BYTES" ]; then  # log past its size cap
        mv -f "$LOG_FILE" "$LOG_FILE.old"                                                  # keep the previous generation
    fi

    #- Append the entry
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"  # timestamped event line
}

## @brief Print the pid of every process named $1 whose command line contains $2.
## @param $1 Program name as pidof matches it.
## @param $2 Fixed string the command line must contain.
wifi_find_pids() {
    #? Filtering by program name first keeps shells whose argv carries the same string out of the result.
    local pid                                                         # candidate process
    for pid in $(pidof "$1"); do                                      # every process running the program
        grep -q -F "$2" "/proc/$pid/cmdline" 2>/dev/null || continue  # skip other command lines
        echo "$pid"                                                   # report the pid
    done
}

## @brief Print the pid stored in a pid file when that process is alive and still the expected program.
## @param $1 Pid file path.
## @param $2 Fixed string the process command line must contain.
## @return 0 when the process runs, 1 otherwise.
wifi_read_live_pid() {
    #? Pid files survive a reboot, so a recorded pid can belong to an unrelated process until the command line confirms it.
    #? The calling shell carries this script's command line too, so its own pid and its parent's never count as the recorded process.
    local pid                                                      # pid recorded in the file
    pid="$(cat "$1" 2>/dev/null)"                                  # read the recorded pid
    [ -n "$pid" ] || return 1                                      # no pid recorded
    [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ] || return 1        # stale pid now naming this call or its parent
    grep -q -F "$2" "/proc/$pid/cmdline" 2>/dev/null || return 1  # dead, or reused by another program
    echo "$pid"                                                    # report the live pid
}

## @brief Send a wpa_cli command to this script's wpa_supplicant.
## @param $@ wpa_cli command and its arguments.
wifi_wpa_cli() {
    wpa_cli -p "$SUPPLICANT_DIR" -i "$WIFI_IFACE" "$@" 2>/dev/null  # talk to the control socket in SUPPLICANT_DIR
}

## @brief Print the wpa_state reported by wpa_supplicant, empty when it does not answer.
wifi_supplicant_state() {
    wifi_wpa_cli status | sed -n 's/^wpa_state=//p'  # extract the state field
}

## @brief Print the IPv4 address of WIFI_IFACE in CIDR form, empty when it has none.
wifi_current_address() {
    ip -4 addr show dev "$WIFI_IFACE" 2>/dev/null | sed -n 's/^ *inet \([0-9./]*\) .*/\1/p' | head -n 1  # first inet entry
}

## @brief Make each interface answer ARP only for its own addresses, or restore the kernel default.
## @param $1 1 applies the policy, 0 restores the kernel default.
wifi_set_arp_policy() {
    #? When Ethernet and Wi-Fi share a subnet, eth0 answers ARP for the Wi-Fi address by default and the traffic never touches wlan0.
    echo "$1" > /proc/sys/net/ipv4/conf/all/arp_ignore                # reply only on the interface owning the address
    echo "$(($1 * 2))" > /proc/sys/net/ipv4/conf/all/arp_announce     # source ARP requests from the outgoing interface
}

## @brief Write SUPPLICANT_CONF from the settings, owned by the wifi user.
wifi_write_supplicant_conf() {
    #- Prepare the wifi-owned dir
    #? wpa_supplicant drops to the wifi user after start, so its config and socket dir must be wifi-owned.
    mkdir -p "$SUPPLICANT_DIR"         # config and control socket home
    chown wifi:wifi "$SUPPLICANT_DIR"  # hand the dir to the wifi user
    chmod 770 "$SUPPLICANT_DIR"        # keep other users out

    #- Generate the config
    {
        printf 'ctrl_interface=%s\n' "$SUPPLICANT_DIR"  # control socket for wpa_cli
        printf 'update_config=0\n'                      # never rewrite the generated file
        printf 'network={\n'                            # network block start
        printf '\tssid="%s"\n' "$WIFI_SSID"             # network name
        printf '\tscan_ssid=1\n'                        # probe by name so a hidden network joins too
        if [ -n "$WIFI_PSK" ]; then                     # protected network
            printf '\tpsk="%s"\n' "$WIFI_PSK"           # WPA2 passphrase
        else
            printf '\tkey_mgmt=NONE\n'                  # open network
        fi
        printf '}\n'                                    # network block end
    } > "$SUPPLICANT_CONF"                              # replace the previous config
    chown wifi:wifi "$SUPPLICANT_CONF"                  # readable by wpa_supplicant after its drop to wifi
    chmod 600 "$SUPPLICANT_CONF"                        # passphrase stays private
}

## @brief Start wpa_supplicant on WIFI_IFACE, replacing any other instance bound to it, and trigger the first scan.
## @return 0 when wpa_supplicant starts, 1 otherwise.
wifi_start_supplicant() {
    #- Free the interface from other supplicants
    local pid                                                      # foreign instance
    for pid in $(wifi_find_pids wpa_supplicant "$WIFI_IFACE"); do  # every supplicant naming the interface
        wifi_log "stopping foreign wpa_supplicant pid $pid"        # record the takeover
        kill "$pid"                                                # release the interface
        sleep 1                                                    # let it close its sockets
    done

    #- Launch with a fresh config
    wifi_write_supplicant_conf                                                                   # config from the settings
    rm -f "$SUPPLICANT_DIR/$WIFI_IFACE"                                                          # drop a socket left by a killed instance
    if ! /system/bin/wpa_supplicant -B -i "$WIFI_IFACE" -D nl80211 -c "$SUPPLICANT_CONF"; then  # daemonize on the interface
        wifi_log "wpa_supplicant failed to start, see: logcat -d -s wpa_supplicant"              # record the failure
        return 1                                                                                 # report the failure
    fi
    wifi_log "wpa_supplicant started for '$WIFI_SSID'"  # record the launch

    #- Trigger the first scan
    #? Android's wpa_supplicant build skips the startup scan and waits for the framework, which never drives it here.
    sleep 2                        # give the control socket time to appear
    wifi_wpa_cli scan > /dev/null  # start network selection
    return 0                       # supplicant running
}

## @brief Stop every wpa_supplicant running SUPPLICANT_CONF.
wifi_stop_supplicant() {
    local pid                                                           # running instance
    for pid in $(wifi_find_pids wpa_supplicant "$SUPPLICANT_CONF"); do  # every instance on the generated config
        kill "$pid"                                                     # end it
        wifi_log "wpa_supplicant pid $pid stopped"                      # record the stop
    done
}

## @brief Start udhcpc on WIFI_IFACE with this script as its event handler.
wifi_start_dhcp() {
    busybox udhcpc -i "$WIFI_IFACE" -s "$SELF" -p "$DHCP_PID_FILE" -b -R -A 5 ${WIFI_HOSTNAME:+-H "$WIFI_HOSTNAME"} > /dev/null 2>&1  # background client, retries every 5 s, releases on exit
    wifi_log "dhcp client started"                                                                                                       # record the launch
}

## @brief Stop the DHCP client recorded in DHCP_PID_FILE.
wifi_stop_dhcp() {
    local pid                                                         # running client
    pid="$(wifi_read_live_pid "$DHCP_PID_FILE" udhcpc)" || return 0  # nothing to stop
    kill "$pid"                                                       # end it; -R releases the lease
    rm -f "$DHCP_PID_FILE"                                            # forget the pid
    wifi_log "dhcp client stopped"                                    # record the stop
}

## @brief Give WIFI_IFACE the leased IPv4 address and no other.
## @param $1 Address in CIDR form, e.g. 192.168.xxx.xxx/16.
wifi_set_address() {
    [ "$(wifi_current_address)" = "$1" ] && return 0  # address already in place
    ip -4 addr flush dev "$WIFI_IFACE"                 # drop a previous lease
    ip addr add "$1" dev "$WIFI_IFACE"                 # assign the new lease
}

## @brief Fill ROUTE_TABLE with the on-link subnet and the gateway of the current lease.
## @param $1 Wi-Fi IPv4 address.
## @param $2 Gateway address; empty skips the default route.
## @return 0 on success, 1 when the kernel has no subnet route for WIFI_IFACE yet.
wifi_set_routes() {
    #- Find the subnet the kernel derived from the address
    local subnet                                                                                                                    # on-link subnet in CIDR form
    subnet="$(ip -4 route show table main dev "$WIFI_IFACE" proto kernel scope link | sed -n 's/^\([0-9./]*\) .*/\1/p' | head -n 1)"  # connected route the address created
    if [ -z "$subnet" ]; then                                       # address not applied yet
        wifi_log "no subnet route on $WIFI_IFACE, routing skipped"  # record the gap
        return 1                                                    # report the failure
    fi

    #- Rebuild the table
    ip route flush table "$ROUTE_TABLE" 2>/dev/null                                      # drop routes from an older lease
    ip route add "$subnet" dev "$WIFI_IFACE" src "$1" table "$ROUTE_TABLE"               # reach the local subnet over Wi-Fi
    [ -n "$2" ] && ip route add default via "$2" dev "$WIFI_IFACE" table "$ROUTE_TABLE"  # reach everything else through the gateway
    return 0                                                                             # table ready
}

## @brief Point traffic at ROUTE_TABLE: everything sourced from the Wi-Fi address, plus whatever no other rule routes.
## @param $1 Wi-Fi IPv4 address.
wifi_set_rules() {
    wifi_clear_rules                                                      # drop rules from an older lease
    ip rule add from "$1" lookup "$ROUTE_TABLE" pref "$RULE_PREF_SOURCE"  # replies from the Wi-Fi address leave via wlan0
    ip rule add lookup "$ROUTE_TABLE" pref "$RULE_PREF_FALLBACK"          # Wi-Fi carries traffic Ethernet does not claim
}

## @brief Remove the rules wifi_set_rules() adds.
wifi_clear_rules() {
    while ip rule del pref "$RULE_PREF_SOURCE" 2>/dev/null; do :; done    # every source rule
    while ip rule del pref "$RULE_PREF_FALLBACK" 2>/dev/null; do :; done  # every fallback rule
}

## @brief Apply a udhcpc event to WIFI_IFACE.
## @param $1 udhcpc event: deconfig, bound, renew, leasefail or nak.
## @note udhcpc passes the lease in the environment as ip, mask and router.
wifi_on_dhcp_event() {
    case "$1" in                                                           # dispatch on the udhcpc event
        bound | renew)                                                     # lease granted or extended
            wifi_set_address "$ip/$mask"                                   # assign the leased address
            wifi_set_routes "$ip" "${router%% *}" && wifi_set_rules "$ip"  # Wi-Fi routes and rules for the first gateway offered
            [ "$1" = bound ] && wifi_log "dhcp: $ip/$mask via ${router%% *}"  # record a new lease
            ;;
        deconfig)                                            # lease lost or client starting over
            wifi_clear_rules                                 # stop steering traffic to Wi-Fi
            ip route flush table "$ROUTE_TABLE" 2>/dev/null  # drop the Wi-Fi routes
            ip -4 addr flush dev "$WIFI_IFACE" 2>/dev/null   # drop the address
            ;;
        leasefail | nak)          # server refused or did not answer
            wifi_log "dhcp: $1"   # record the refusal
            ;;
    esac
}

## @brief Reject settings wpa_supplicant cannot use, and a script file udhcpc cannot execute.
## @return 0 when the setup is usable, 1 after printing and logging the problem.
wifi_check_settings() {
    #- Find the first unusable setting
    local problem=''                                                                             # what blocks the start
    if [ -z "$WIFI_SSID" ] || [ "$WIFI_SSID" = YOUR_SSID ]; then                                 # empty or placeholder name
        problem="set WIFI_SSID at the top of $SELF"                                              # name the fix
    elif [ "$WIFI_PSK" = YOUR_PASSWORD ]; then                                                   # placeholder passphrase
        problem="set WIFI_PSK at the top of $SELF, or empty it for an open network"              # name the fix
    elif [ -n "$WIFI_PSK" ] && { [ "${#WIFI_PSK}" -lt 8 ] || [ "${#WIFI_PSK}" -gt 63 ]; }; then  # outside the WPA2 passphrase range
        problem="WIFI_PSK must be 8 to 63 characters"                                            # name the limit
    elif [ ! -x "$SELF" ]; then                                                                  # udhcpc cannot run the callback
        problem="make the script executable: chmod 700 $SELF"                                    # name the fix
    fi

    #- Report it
    [ -z "$problem" ] && return 0     # setup usable
    echo "$problem" >&2               # tell the caller
    wifi_log "not started: $problem"  # trace for a boot-time start, whose output is discarded
    return 1                          # refuse to start
}

## @brief Keep the Wi-Fi link up until killed: load the driver, run wpa_supplicant and udhcpc, and repair them every POLL_SECONDS.
## @return 1 when another watchdog runs or the settings are unusable; otherwise it never returns.
wifi_run() {
    #^ Startup
    #- Refuse a second watchdog
    local pid                                                            # running watchdog
    if pid="$(wifi_read_live_pid "$LOOP_PID_FILE" "${SELF##*/}")"; then  # another watchdog alive
        echo "already running (pid $pid)" >&2                            # report it
        return 1                                                         # leave the running one alone
    fi

    #- Refuse unusable settings
    wifi_check_settings || return 1  # stop before touching the network

    #- Claim the pid file
    #? umask 077 only covers new files, and a new BASE_DIR would block the wifi user on its way to SUPPLICANT_DIR.
    mkdir -p "$BASE_DIR"                                                         # state dir for log and pid files
    chmod 711 "$BASE_DIR"                                                        # wifi user passes through to SUPPLICANT_DIR
    chmod 600 "$LOG_FILE" "$LOG_FILE.old" "$LOOP_PID_FILE" "$DHCP_PID_FILE" 2>/dev/null  # tighten state files from an older install
    echo "$$" > "$LOOP_PID_FILE"          # mark this watchdog as running
    wifi_log "watchdog started (pid $$)"  # record the start

    #- Apply the ARP policy
    wifi_set_arp_policy 1  # keep Wi-Fi traffic on wlan0

    #^ Watchdog
    local last_state=''    # link state logged last
    local state            # link state on this pass
    local address          # Wi-Fi address on this pass
    local driver_failed=0  # 1 while insmod keeps failing
    while true; do         # until stop kills the watchdog
        #- Load the driver
        if ! grep -q "^$DRIVER_NAME " /proc/modules; then                  # driver not loaded
            if insmod "$DRIVER_PATH" $DRIVER_ARGS; then                    # load with the configured parameters
                wifi_log "driver $DRIVER_NAME loaded"                      # record the load
                driver_failed=0                                            # a later failure logs again
            elif [ "$driver_failed" = 0 ]; then                            # first failure in a row
                wifi_log "driver $DRIVER_NAME failed to load, see: dmesg"  # record the failure once
                driver_failed=1                                            # silence the repeats
            fi
        fi

        #- Wait for the dongle
        if [ ! -d "/sys/class/net/$WIFI_IFACE" ]; then                         # dongle unplugged
            if [ "$last_state" != NO_DONGLE ]; then                            # first pass without it
                wifi_log "waiting for $WIFI_IFACE, is the dongle plugged in?"  # record the wait
                wifi_stop_dhcp                                                 # client lost its interface
                wifi_stop_supplicant                                           # supplicant lost its interface
                last_state=NO_DONGLE                                           # log the wait once
            fi
            sleep "$POLL_SECONDS"  # check again later
            continue               # skip the link checks
        fi

        #- Keep the link services running
        ip link set "$WIFI_IFACE" up                                                           # interface up for scanning
        [ -n "$(wifi_find_pids wpa_supplicant "$SUPPLICANT_CONF")" ] || wifi_start_supplicant  # restart a missing supplicant
        wifi_read_live_pid "$DHCP_PID_FILE" udhcpc > /dev/null || wifi_start_dhcp              # restart a missing DHCP client

        #- Kick an idle supplicant
        state="$(wifi_supplicant_state)"                               # current wpa_state
        case "$state" in                                               # act on an idle state
            DISCONNECTED | INACTIVE) wifi_wpa_cli scan > /dev/null ;;  # rescan instead of waiting for Android
        esac
        if [ "$state" != "$last_state" ]; then                         # state changed since the last pass
            wifi_log "link: ${state:-no answer from wpa_supplicant}"   # record the transition
            last_state="$state"                                        # log each state once
        fi

        #- Restore rules netd flushed
        address="$(wifi_current_address)"                                        # current lease address
        if [ -n "$address" ] && ! ip rule | grep -q "^$RULE_PREF_SOURCE:"; then  # address present, rule gone
            wifi_set_rules "${address%/*}"                                       # re-add the Wi-Fi rules
            wifi_log "routing rules restored"                                    # record the repair
        fi

        sleep "$POLL_SECONDS"  # next pass
    done
}

## @brief Rewrite HOOK_TARGET in place from a filtered copy, keeping its owner and mode, and roll back if the result is incomplete or bash rejects it.
## @param $1 Edit to apply: hook inserts HOOK_LINE after the shebang, strip removes every hook line.
## @return 0 when the edited HOOK_TARGET passes every check, 1 when the edit is refused or rolled back.
wifi_edit_hook_target() {
    #- Snapshot the current content
    local line                                      # boot script line being copied
    local first=1                                   # 1 until the shebang line is copied
    local copied=0                                  # lines written to the edited copy
    local tmp="$BASE_DIR/start_rigol_app.sh.new"    # edited copy
    local prev="$BASE_DIR/start_rigol_app.sh.prev"  # pre-edit copy for rollback
    cp -p "$HOOK_TARGET" "$prev" || return 1        # content to restore on failure

    #- Build the edited copy
    while IFS= read -r line || [ -n "$line" ]; do     # every line, including an unterminated last one
        case "$1:$line" in                            # edit mode and line together
            strip:*"$SELF start"*) continue ;;        # drop an existing hook line
        esac
        printf '%s\n' "$line"                         # copy the line unchanged
        copied=$((copied + 1))                        # count it
        if [ "$1" = hook ] && [ "$first" = 1 ]; then  # right after the shebang
            printf '%s\n' "$HOOK_LINE"                # start Wi-Fi before the Rigol app
            copied=$((copied + 1))                    # count it
        fi
        first=0                                       # shebang copied
    done < "$HOOK_TARGET" > "$tmp"                    # boot script in, edited copy out

    #- Refuse an incomplete copy
    #? A full disk truncates the copy without an error, and a boot script cut at a line boundary still passes bash -n.
    if [ "$copied" = 0 ] || [ "$(wc -l < "$tmp" 2>/dev/null)" != "$copied" ]; then  # nothing copied, or fewer lines landed than were written
        rm -f "$tmp" "$prev"                                                        # discard the edit
        echo "edited copy is incomplete, boot script left unchanged" >&2            # report the refusal
        return 1                                                                    # report the failure
    fi

    #- Replace the content in place, roll back on failure
    #? cat into the original keeps its owner and its 777 mode, and bootApp.sh needs the execute bit to start the Rigol app.
    if ! cat "$tmp" > "$HOOK_TARGET" || ! /system/bin/bash -n "$HOOK_TARGET"; then  # write failed or bash rejects the result
        cat "$prev" > "$HOOK_TARGET"                                               # restore the pre-edit content
        rm -f "$tmp"                                                               # drop the edited copy
        echo "boot script edit failed, previous content restored from $prev" >&2   # report the rollback
        return 1                                                                   # report the failure
    fi
    rm -f "$tmp" "$prev"  # edit accepted
    return 0              # boot script valid
}

#& Commands

## @brief Start the watchdog detached from the caller's session unless one already runs.
## @return 0 when a watchdog runs or was started, 1 when the settings are unusable.
wifi_cmd_start() {
    #- Refuse a second watchdog
    local pid                                                            # running watchdog
    if pid="$(wifi_read_live_pid "$LOOP_PID_FILE" "${SELF##*/}")"; then  # watchdog alive
        echo "already running (pid $pid)"                                # report it
        return 0                                                         # nothing to do
    fi

    #- Refuse unusable settings
    wifi_check_settings || return 1  # report the problem here, not only in the detached watchdog

    #- Detach the watchdog
    #? setsid keeps the watchdog alive after the adb shell or boot script that started it exits.
    setsid /system/bin/sh "$SELF" run < /dev/null > /dev/null 2>&1 &  # watchdog in its own session
    echo "started, log: $LOG_FILE"                                    # report the launch
}

## @brief Stop the watchdog, wpa_supplicant and udhcpc, remove the address and rules, and unload the driver.
wifi_cmd_stop() {
    #- Stop the watchdog first so it restarts nothing
    local pid                                                            # running watchdog
    if pid="$(wifi_read_live_pid "$LOOP_PID_FILE" "${SELF##*/}")"; then  # watchdog alive
        kill "$pid"                                                      # end it
    fi
    rm -f "$LOOP_PID_FILE"  # forget the pid

    #- Stop the link services
    wifi_stop_dhcp        # release the lease
    wifi_stop_supplicant  # leave the network
    sleep 1               # let both exit

    #- Undo the network changes
    wifi_clear_rules                                 # stop steering traffic to Wi-Fi
    ip route flush table "$ROUTE_TABLE" 2>/dev/null  # drop the Wi-Fi routes
    ip -4 addr flush dev "$WIFI_IFACE" 2>/dev/null   # drop the address
    ip link set "$WIFI_IFACE" down 2>/dev/null       # interface down
    wifi_set_arp_policy 0                            # kernel default ARP behavior
    rmmod "$DRIVER_NAME" 2>/dev/null                 # unload the driver
    rm -f "$SUPPLICANT_CONF"                         # drop the passphrase copy
    wifi_log "stopped"                               # record the stop
    echo "stopped"                                   # report it
}

## @brief Print watchdog, driver, link, address, DHCP and routing state, then the log tail.
wifi_cmd_status() {
    #- Processes and driver
    local pid  # pid lookups
    if pid="$(wifi_read_live_pid "$LOOP_PID_FILE" "${SELF##*/}")"; then echo "watchdog:  running (pid $pid)"; else echo "watchdog:  not running"; fi  # watchdog
    if grep -q "^$DRIVER_NAME " /proc/modules; then echo "driver:    $DRIVER_NAME loaded"; else echo "driver:    $DRIVER_NAME not loaded"; fi        # module
    if pid="$(wifi_read_live_pid "$DHCP_PID_FILE" udhcpc)"; then echo "dhcp:      running (pid $pid)"; else echo "dhcp:      not running"; fi      # DHCP client

    #- Link
    if [ -d "/sys/class/net/$WIFI_IFACE" ]; then                                                     # dongle present
        echo "interface: $WIFI_IFACE $(cat "/sys/class/net/$WIFI_IFACE/operstate")"                  # kernel link state
        echo "link:      $(wifi_supplicant_state) $(wifi_wpa_cli status | sed -n 's/^ssid=//p')"     # wpa_state and joined network
        echo "signal:    $(wifi_wpa_cli signal_poll | sed -n 's/^RSSI=//p') dBm"                     # received signal strength
        echo "address:   $(wifi_current_address)"                                                    # leased address
    else
        echo "interface: $WIFI_IFACE missing, is the dongle plugged in?"  # dongle absent
    fi

    #- Routing and log
    echo "rules:"                                                       # policy rules header
    ip rule | grep -E "^($RULE_PREF_SOURCE|$RULE_PREF_FALLBACK):"       # Wi-Fi rules in place
    if grep -q -F "$SELF start" "$HOOK_TARGET" 2>/dev/null; then echo "boot hook: installed"; else echo "boot hook: not installed"; fi  # autostart state
    echo "log:"                                                         # log header
    tail -n 5 "$LOG_FILE" 2>/dev/null                                   # latest events
}

## @brief Add the boot hook to HOOK_TARGET after backing it up.
## @return 0 when the hook is in place, 1 when HOOK_TARGET is missing or the edit failed.
wifi_cmd_install() {
    #- Require the Rigol boot script
    if [ ! -f "$HOOK_TARGET" ]; then                        # firmware without the Rigol boot script
        echo "$HOOK_TARGET not found, nothing to hook" >&2  # name the problem
        return 1                                            # refuse the install
    fi

    #- Skip a second install
    if grep -q -F "$SELF start" "$HOOK_TARGET"; then        # hook already present
        echo "boot hook already installed in $HOOK_TARGET"  # report it
        return 0                                            # nothing to do
    fi

    #- Back up and edit the boot script
    cp -p "$HOOK_TARGET" "$HOOK_BACKUP"                               # pristine copy for a manual restore
    wifi_edit_hook_target hook || return 1                            # insert the hook line
    echo "boot hook installed in $HOOK_TARGET, backup: $HOOK_BACKUP"  # report the result
}

## @brief Remove the boot hook from HOOK_TARGET and stop Wi-Fi.
## @return 1 when the boot script edit failed, otherwise the result of wifi_cmd_stop().
wifi_cmd_uninstall() {
    #- Remove the hook line
    if grep -q -F "$SELF start" "$HOOK_TARGET"; then  # hook present
        wifi_edit_hook_target strip || return 1       # drop the hook line
        echo "boot hook removed from $HOOK_TARGET"    # report the removal
    else
        echo "boot hook not installed"                # nothing to remove
    fi

    #- Stop Wi-Fi
    wifi_cmd_stop  # tear the link down
}

#& Entry Point
if [ "$(id -u)" != 0 ]; then                    # driver, routing and boot script are root-only
    echo "${SELF##*/} must run as root" >&2     # name the requirement
    exit 1                                      # refuse to run
fi
umask 077                                       # log, pid and temp files stay private to root
case "$1" in                                                          # dispatch the command
    start) wifi_cmd_start ;;                                          # detached watchdog
    run) wifi_run ;;                                                  # watchdog in the foreground
    stop) wifi_cmd_stop ;;                                            # tear everything down
    status) wifi_cmd_status ;;                                        # report the state
    install) wifi_cmd_install ;;                                      # start at every boot
    uninstall) wifi_cmd_uninstall ;;                                  # stop starting at boot
    deconfig | bound | renew | leasefail | nak) wifi_on_dhcp_event "$1" ;;  # udhcpc callback
    *)                                                                # anything else
        echo "usage: ${SELF##*/} start|run|stop|status|install|uninstall" >&2  # list the commands
        exit 2                                                        # report misuse
        ;;
esac
