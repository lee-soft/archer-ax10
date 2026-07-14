#!/bin/sh
# ============================================================
# Runs ON THE ROUTER at boot, fetched by the openvpn up-hook AFTER WAN is up.
# boot.sh just BOOTSTRAPS opkg + ssh, then installs the ax10-* packages from the
# GitHub Releases feed (see $SRC/$FEED below). The LuCI / wifi / watchdog logic
# that used to live inline here is now in packages (ax10-luci -> ax10-svc + ax10-wifi;
# each daemon supervised by busybox-init respawn via ax10-svc). See the README.
# ============================================================
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# Where the router pulls boot assets + the opkg feed. Default: this project's GitHub
# Releases — the aggregated feed (Packages.gz + the *.ipk feed) plus the dropbear_vanilla
# :2222 lifeline seed. Override for a CDN or dev host, e.g.
#   SRC=https://archer-boot.pages.dev   or   SRC=http://<dev-host>:8088
SRC="${SRC:-https://github.com/lee-soft/archer-ax10/releases/latest/download}"
FEED="${FEED:-$SRC}"                          # opkg feed base (Packages.gz + *.ipk)
# The opkg payload has ONE canonical home: the ax10-opkg repo's "payload" release
# (install.sh + opt.tar.gz + busybox-armv7l). We fetch install.sh from there and let it
# pull its own opt.tar.gz/busybox — NOT duplicated into this feed. Override for dev/CDN.
OPKG_SRC="${OPKG_SRC:-https://github.com/lee-soft/ax10-opkg/releases/latest/download}"
PKGS="${PKGS:-ax10-busybox}"                  # installed once opkg is up. Default = opkg + the
                                              # full userland only (no web UI, no debloat). Opt-in extras:
                                              #   opkg install ax10-luci      # LuCI web UI on :8080
                                              #   opkg install ax10-debloat   # stop TP-Link cloud/phone-home junk
                                              # or bake them in, e.g. PKGS="ax10-busybox ax10-debloat ax10-luci"
GET="/usr/bin/curl -4 -L -k -fs"              # -4 -L -k = IPv4, follow redirects, skip cert (no CA bundle / pre-NTP clock)

# self-heal CGNAT DDNS into script mode
/sbin/uci set ddns.noip.ip_source=script
/sbin/uci commit ddns
/usr/sbin/ddns restart noip
touch /tmp/archer-boot-ran.txt
/usr/bin/curl -fs -m 10 http://api.ipify.org -o /tmp/current_public_ip.txt

# HARDENING / TP-Link debloat (CWMP, cloud phone-home, tdpServer/CVE-2023-1389, telnet,
# UPnP, ...) is now the ax10-debloat package — it also disarms the cron/monit keepalives
# that revive the junk within ~60s, which this inline block never did. It's OPT-IN: run
#   opkg install ax10-debloat            (tier 2, recommended)
# once opkg is up, or add ax10-debloat to PKGS below to harden on every boot.

# ----------------------------------------------------------------
# Root password = the router's OWN web-GUI admin password, so SSH + LuCI root
# login (rpcd $p$root -> /etc/shadow) MIRROR the TP-Link web UI: change it there
# and it carries through on the next boot. The stock squashfs ships NO /etc/shadow
# (root passwordless/locked), so a password must be set for dropbear to accept a
# login. TP-Link stores the web password AES-ENCRYPTED in /etc/config/accountmgnt
# (NOT nvram http_passwd, which is a stale 'admin' decoy) — so we ask the router's
# OWN decrypt routine (luci.model.accountmgnt.get_localPassword) for the plaintext,
# pipe it straight into cryptpw (never in argv/on disk), and write the hash. Nothing
# is hardcoded on Cloudflare. Lifeline fallback (the well-known default password
# "admin") is reached ONLY if lua/decrypt/crypt fail, so we can never lock out.
# ----------------------------------------------------------------
echo "Setting root password (mirroring the web-GUI admin password)..."
_wpw="$(/usr/bin/lua -e 'local ok,a=pcall(require,"luci.model.accountmgnt"); if ok and type(a.get_localPassword)=="function" then local p=a.get_localPassword(); if type(p)=="string" then io.write(p) end end' 2>/dev/null)"
_h=""
[ -n "$_wpw" ] && _h="$(printf '%s' "$_wpw" | /bin/busybox cryptpw -m md5 2>/dev/null)"
[ -z "$_h" ] && [ -n "$_wpw" ] && _h="$(/usr/bin/openssl passwd -1 "$_wpw" 2>/dev/null)"
if [ -n "$_h" ]; then
    printf 'root:%s:0:0:99999:7:::\n' "$_h" > /etc/shadow
else
    # Lifeline fallback — the well-known default password "admin" (this is a crypt
    # hash of "admin", not a personal secret). Only reached if the decrypt/crypt
    # path above fails. Change the password in the web GUI on first login.
    echo 'root:$1$Ax10boot$zooYD5Cu6tYQJk9Cd0SIL1:0:0:99999:7:::' > /etc/shadow
fi
unset _wpw _h

# SSH LIFELINE on :2222 (direct fetch+launch, so there's always a way in even if
# opkg/packages fail). ax10-dropbear provides a supervised :22 on-demand.
$GET -m 30 "$SRC/dropbear_vanilla" -o /tmp/dropbear_vanilla && chmod +x /tmp/dropbear_vanilla
echo "Starting dropbear SSH on :2222..."
(/tmp/dropbear_vanilla -p 2222 -R -E </dev/null >/dev/null 2>&1) &

# ============================================================
# opkg bootstrap — DELEGATED to ax10-opkg's install.sh (fetched from its OWN canonical
# release, $OPKG_SRC). That one script owns the whole opkg install (busybox+HTTPS wget,
# the /tmp/opt tree, the feed URL, the loader wrappers, and the PATH/env in /etc/profile),
# so a hand-run install and the boot path are the same code with no drift. It pulls its
# opt.tar.gz + busybox from $OPKG_SRC and points the opkg `ax10` feed at $FEED (this repo).
# See github.com/lee-soft/ax10-opkg.
# ============================================================
if $GET -m 30 "$OPKG_SRC/install.sh" -o /tmp/opkg-install.sh; then
    SRC="$OPKG_SRC" FEED="$FEED" GET="$GET -m 90" NO_UPDATE=1 sh /tmp/opkg-install.sh
    export PATH="/tmp/opt/wrappers:/tmp/wgetssl:/tmp/vanilla/bin:$PATH"

    # ========================================================
    # THE USERLAND — default ($PKGS) is just ax10-busybox: opkg + ~396 applets + a real
    # HTTPS wget. That alone is a fully working package manager — install anything from
    # the feed (nyancat, htop, mc, tmux, ...). The web UI is OPT-IN and pulls its own deps:
    #   opkg install ax10-luci        (-> ax10-svc + ax10-wifi; rpcd/uhttpd supervised via ax10-svc)
    # ========================================================
    if [ -x /tmp/opt/opkg ]; then
        /tmp/opt/opkg update >/dev/null 2>&1
        /tmp/opt/opkg install $PKGS >/tmp/opkg-boot.log 2>&1
    fi
fi
