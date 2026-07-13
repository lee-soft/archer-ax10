# archer-ax10

A self-assembling boot + package system for the **TP-Link Archer AX10** (Broadcom BCM963178,
ARMv7l, glibc 2.26, busybox-init, kernel 4.1) running TP-Link's OpenWrt-based firmware.

The router has a **read-only squashfs root and no writable persistence** except one
flash-stored hook. Instead of reflashing, this project turns that single hook into a
bootstrap: on every boot the router fetches a script from the internet, hardens the stock
firmware, then **rebuilds a modern userland from an `opkg` feed** — a real HTTPS `wget`, a
full busybox applet layer, an SSH server, a Broadcom wifi apply backend, and a modern **LuCI**
web UI — all supervised by busybox-init. Nothing but the hook is persisted; the whole stack
reassembles itself from packages each boot.

> This is my own router. The URLs default to my GitHub; override them and it's yours.

## How a boot works

```
openvpn "up" hook  (the ONE flash-persisted boot-exec, survives reboots)
        │  waits for WAN, then fetches over HTTPS
        ▼
boot.sh (this repo) ── fetched from GitHub Releases
        ├─ self-heal DDNS, disable TR-069/CWMP, stop TP-Link cloud/phone-home services
        ├─ set root password = the router's OWN web-GUI password (see "Password" below)
        ├─ start a lifeline dropbear on :2222
        ├─ bootstrap busybox 1.31 + a real HTTPS wget (stock 1.19 wget has no SSL)
        ├─ bootstrap opkg (static Entware + glibc loader tree in tmpfs)
        └─ opkg install ax10-busybox               ← from the GitHub Releases feed
                    │   default = opkg + a full userland only. Now: opkg install nyancat htop mc ...
                    ▼
        ax10-busybox ─ ~396 applets + box-wide HTTPS wget

   optional add-ons — opkg install them if you want them (deps pulled automatically):
        ax10-luci ─── modern LuCI 21.02 web UI on :8080  (pulls ax10-svc + ax10-wifi)
        ax10-dropbear ─ native SSH on :22                (pulls ax10-svc)
        ax10-svc ──── service manager (busybox-init respawn; this box has no procd)
        ax10-wifi ─── apply /etc/config/wireless to the Broadcom wl driver
```

A working `opkg` + userland is the base and stands on its own (see [ax10-opkg](../../../ax10-opkg));
LuCI, SSH-on-22, etc. are things you opt into, not things forced on every boot.

## Repository layout (umbrella + submodules)

| Repo | What it is |
|---|---|
| **archer-ax10** (this) | `boot.sh`, feed builder (`build-repo.sh`), optional CF mirror (`deploy-to-pages.sh`), docs, and the package repos as submodules under `repo-src/`. |
| [ax10-opkg](../../../ax10-opkg) | **The opkg bootstrap** — a working `opkg` + Entware userland on this RO-root router. Stands alone; no LuCI needed. |
| [ax10-svc](../../../ax10-svc) | Minimal service manager — registers foreground daemons with busybox-init `respawn`. |
| [ax10-busybox](../../../ax10-busybox) | Additive busybox 1.31 applet layer + the HTTPS `wget` override opkg needs. |
| [ax10-dropbear](../../../ax10-dropbear) | Dropbear SSH on :22, supervised by ax10-svc. |
| [ax10-wifi](../../../ax10-wifi) | Applies `/etc/config/wireless` to the Broadcom `wl` driver; standalone (no web UI needed). |
| [ax10-luci](../../../ax10-luci) | Modern LuCI web UI (cross-built 19.07 rpcd/uhttpd on the 2013 ubus stack). |
| [newstack](../../../newstack) | The shared glibc-2.26 ARM cross-build stack (toolchain + sysroot + ABI shims) that builds the glibc binaries. |

## The `opkg` feed (served from GitHub Releases)

**Each package repo builds and publishes its own `.ipk`** (its `build-ipk` workflow → that
repo's `ipk` release). From-source packages (e.g. `ax10-dropbear`) compile in CI and never
commit the binary; script/vendored packages pack their `data/`. The `build-feed` workflow here
downloads each package's `.ipk`, runs `index.sh` to build the `Packages(.gz)` index, and
publishes the index + all `.ipk`s + the boot bootstrap assets as a GitHub **Release**. The
router points `opkg` at:

```
src/gz ax10 https://github.com/lee-soft/archer-ax10/releases/latest/download
```

`opkg`/`wget` on this box has no CA bundle, so fetches use `-k` / a no-verify `ssl_client`;
GitHub's valid TLS + redirect to `objects.githubusercontent.com` works fine with that.

## Password (why it's not hardcoded)

The stock squashfs ships no `/etc/shadow` (root is passwordless/locked), so `boot.sh` must set
one for SSH. Rather than baking in a password, it **mirrors the router's own web-GUI admin
password**: TP-Link stores that AES-encrypted in `/etc/config/accountmgnt`, so `boot.sh` asks
the firmware's own decrypt routine (`luci.model.accountmgnt.get_localPassword`) for the
plaintext and hashes it into `/etc/shadow`. Change it in the web GUI and SSH + LuCI follow on
the next boot. A crypt hash of the default `admin` is the only fallback, used solely if that
decrypt path fails.

## Build pipeline

- `busybox` — independent static-musl cross-build (public toolchain) in `ax10-busybox`.
- `dropbear` + the LuCI stack — built with the **newstack** glibc-2.26 toolchain (packaged as
  a container image so CI, and anyone, can reproduce binaries for this router's architecture).
- The prebuilt binaries are vendored in the package repos so the feed builds immediately;
  the from-source CI reproduces them. See each package's `build/` and the `newstack` repo.

## Using it on your own router

1. Fork these repos (or change `lee-soft` in `boot.sh`'s `SRC`/`FEED` to your account).
2. Let CI publish the feed Release (or run `build-repo.sh` and upload the assets yourself).
3. Point your boot hook at your `boot.sh`. Override the source at runtime any time:
   `SRC=https://your.cdn/path sh /tmp/boot.sh`.

## License

MIT for this project's own code (see LICENSE). Bundled third-party binaries keep their own
licenses — see THIRD-PARTY.md.
