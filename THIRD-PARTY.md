# Third-party components

This project's own scripts, packaging, and build tooling are MIT-licensed (see LICENSE).
It distributes and/or builds several third-party components that remain under **their own
upstream licenses**. Nothing here relicenses them.

| Component | Used in | Upstream | License |
|---|---|---|---|
| BusyBox 1.31 (static) | `ax10-busybox`, boot bootstrap | https://busybox.net | GPL-2.0-only |
| Dropbear SSH | `ax10-dropbear`, boot lifeline | https://matt.ucc.asn.au/dropbear/ | MIT-style (see dropbear LICENSE) |
| rpcd (+ mod-luci) | `ax10-luci` | https://github.com/openwrt/rpcd | ISC |
| uhttpd | `ax10-luci` | https://github.com/openwrt/uhttpd | ISC |
| libubox / ubus | `ax10-luci` | https://git.openwrt.org | ISC |
| cgi-io | `ax10-luci` | https://github.com/openwrt/cgi-io | ISC |
| lucihttp | `ax10-luci` | https://github.com/jow-/lucihttp | ISC / Apache-2.0 |
| json-c 0.13 | `ax10-luci` | https://github.com/json-c/json-c | MIT |
| LuCI (Lua + web UI) | `ax10-luci` | https://github.com/openwrt/luci | Apache-2.0 |
| Entware opkg + loader | boot bootstrap (`opt.tar.gz`) | https://github.com/Entware/Entware | GPL-2.0 / various |
| GCC / binutils / glibc cross toolchain | `newstack` | https://gcc.gnu.org, https://www.gnu.org/software/libc/ | GPL-3.0 / LGPL-2.1 |

Prebuilt binaries checked into the package repos (and attached to Releases) are provided as a
convenience. The corresponding source and build recipes are referenced above and, where the
build is reproduced here, live in each package's `build/` directory and the `newstack` stack.

If you redistribute the GPL components (BusyBox, Entware, the toolchain), honour their source
requirements — links to the exact upstream versions are above and pinned in the build recipes.
