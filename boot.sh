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
# Releases (Packages.gz, the *.ipk feed, and busybox-armv7l/opt.tar.gz/dropbear_vanilla
# all live there as release assets). Override for a CDN or dev host, e.g.
#   SRC=https://archer-boot.pages.dev   or   SRC=http://<dev-host>:8088
SRC="${SRC:-https://github.com/lee-soft/archer-ax10/releases/latest/download}"
FEED="${FEED:-$SRC}"                          # opkg feed base (Packages.gz + *.ipk)
GET="/usr/bin/curl -4 -L -k -fs"              # -4 -L -k = IPv4, follow redirects, skip cert (no CA bundle / pre-NTP clock)

# self-heal CGNAT DDNS into script mode
/sbin/uci set ddns.noip.ip_source=script
/sbin/uci commit ddns
/usr/sbin/ddns restart noip
touch /tmp/archer-boot-ran.txt
/usr/bin/curl -fs -m 10 http://api.ipify.org -o /tmp/current_public_ip.txt

# disable TR-069 / CWMP remote management
/sbin/uci set cwmp.info.enable='off'
/sbin/uci set cwmp.info.inform_enable='off'
/sbin/uci commit cwmp
/etc/init.d/cwmp stop

# ============================================================
# HARDENING — stop TP-Link cloud/phone-home + LAN-exposed junk. All FS is ramfs so
# the firmware restarts these every boot; re-stopping here is the persistence.
# ============================================================
for s in cloud_brd cloud_client cloud_https domain_login smart_home agile_config \
         wportal sync-server tdpServer tmpServer dropbear miniupnpd zzzzzzaconn-indicator; do
    [ -x /etc/init.d/$s ] && /etc/init.d/$s stop >/dev/null 2>&1
done
for p in cloud-brd cloud-client cloud-https tdpServer tmpServer miniupnpd conn-indicator sync-server; do
    killall $p >/dev/null 2>&1
done

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
# BOOTSTRAP: busybox 1.31 + a real HTTPS wget. opkg fetches via `wget`, and the
# stock busybox 1.19 wget has NO SSL — this busybox does (its ssl_client applet,
# no CA bundle / synced clock needed). This is the minimum opkg needs over https;
# the full 396-applet layer is then delivered by the ax10-busybox package.
# ============================================================
VBB=/tmp/vanilla/busybox
rm -rf /tmp/vanilla; mkdir -p /tmp/vanilla/bin
if $GET -m 30 "$SRC/busybox-armv7l" -o "$VBB"; then
    chmod +x "$VBB"
    mkdir -p /tmp/wgetssl
    ln -sf "$VBB" /tmp/wgetssl/wget
    ln -sf "$VBB" /tmp/wgetssl/ssl_client
    grep -q '/tmp/wgetssl' /etc/profile 2>/dev/null || echo 'export PATH="/tmp/wgetssl:$PATH"' >> /etc/profile
fi
export PATH="/tmp/wgetssl:/tmp/vanilla/bin:$PATH"

# ============================================================
# opkg bootstrap — static Entware opkg + glibc loader tree in tmpfs /tmp/opt.
# The `ax10` feed URL is (re)written to $FEED just below; the wget->real-wget /
# ax10-configure (deferred-postinst runner) plumbing rides along in opt.tar.gz.
# ============================================================
if $GET -m 90 "$SRC/opt.tar.gz" -o /tmp/opt.tgz; then
    rm -rf /tmp/opt; /bin/gzip -dc /tmp/opt.tgz | /bin/tar xf - -C /tmp
    mkdir -p /tmp/opt/tmp /tmp/opt/var/lock /tmp/opt/var/opkg-lists
    # Point the opkg feed at $FEED (keeps opt.tar.gz's baked opkg.conf generic/portable).
    if [ -f /tmp/opt/opkg.conf ]; then
        grep -q '^src/gz ax10' /tmp/opt/opkg.conf \
          && sed -i "s#^src/gz ax10 .*#src/gz ax10 $FEED#" /tmp/opt/opkg.conf \
          || echo "src/gz ax10 $FEED" >> /tmp/opt/opkg.conf
    fi
    [ -x /tmp/opt/opt-genwrappers.sh ] && /tmp/opt/opt-genwrappers.sh 2>/dev/null
    ln -sf /tmp/opt/opkg /tmp/vanilla/bin/opkg 2>/dev/null
    # put opkg (symlinked above) on interactive shells' PATH
    grep -q '/tmp/vanilla/bin' /etc/profile 2>/dev/null || echo 'export PATH="$PATH:/tmp/vanilla/bin"' >> /etc/profile
    # /root is on the RO squashfs -> tmpfs-mount it so TUI tools can write ~/.config
    grep -q ' /root ' /proc/mounts || { cp -a /root /tmp/.root-seed 2>/dev/null
        mount -t tmpfs tmpfs /root 2>/dev/null && cp -a /tmp/.root-seed/. /root/ 2>/dev/null; rm -rf /tmp/.root-seed; }
    grep -q '/tmp/opt/wrappers' /etc/profile 2>/dev/null || echo 'export PATH="/tmp/opt/wrappers:$PATH"' >> /etc/profile
    grep -q 'TERMINFO=/tmp/opt' /etc/profile 2>/dev/null || echo 'export TERMINFO=/tmp/opt/share/terminfo' >> /etc/profile
    grep -q 'LC_CTYPE=en_US' /etc/profile 2>/dev/null || printf 'export LOCPATH=/tmp/opt/usr/lib/locale\nexport LC_CTYPE=en_US.UTF-8\n' >> /etc/profile

    # ========================================================
    # THE STACK — now just packages. `opkg install ax10-luci` pulls ax10-svc +
    # ax10-wifi; ax10-busybox adds the full applet layer. rpcd / uhttpd / wifiwatch
    # are all supervised by busybox-init respawn (via ax10-svc) — no more inline
    # LuCI/wifi/webwatch blocks, no custom watchdog.
    # ========================================================
    /tmp/opt/opkg update >/dev/null 2>&1
    /tmp/opt/opkg install ax10-busybox ax10-luci >/tmp/opkg-boot.log 2>&1
fi
