# Embrace

[![CI](https://github.com/holistic3fficientsolutions/embrace/actions/workflows/ci.yml/badge.svg)](https://github.com/holistic3fficientsolutions/embrace/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/holistic3fficientsolutions/embrace)](https://github.com/holistic3fficientsolutions/embrace/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/holistic3fficientsolutions/embrace/total)](https://github.com/holistic3fficientsolutions/embrace/releases)
[![Crystal](https://img.shields.io/badge/made%20with-Crystal-black?logo=crystal&logoColor=white)](https://crystal-lang.org/)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0--only-blue)](LICENSE)

**A sovereign, local-first tool for structured data — lighter than a
spreadsheet, more powerful than a database, with built-in time travel.**

Embrace fills a gap that, as of mid-2026, no mainstream office or open-source
suite covers: the structured-data niche occupied so far mostly by proprietary
tools such as Airtable, Microsoft Access or Microsoft Lists (and similar). It
runs entirely on your own machine, stores data in an open
file format, and treats your data the way version-control treats source code —
every change is a commit you can branch, diff, and travel back through.

> **Embrace 2.0** is the first open-source (AGPL) release of a tool developed
> over several years. The proprietary 1.x line preceded it; 2.0 opens the core.

## Why Embrace

- **Editable perspectives ("shapes").** View and edit the same underlying data
  through different structural lenses without duplicating it.
- **Data version control.** Commits, branches and time-travel — applied to
  *data*, not just code. See what changed, when, and roll back safely.
- **Structural refactoring with stable identity.** Reorganise tables and fields
  while references and history stay intact.
- **Low entry barrier.** Start like a spreadsheet; grow into a relational,
  versioned model without a migration project.
- **Open format & interop.** Native `.embrace` files, XLSX import/export, and clipboard (TSV) copy/paste.
- **Local-first & private.** Your data never has to leave your machine. No
  cloud account required.

## Download

Pre-built binaries are attached to each
[GitHub Release](https://github.com/holistic3fficientsolutions/embrace/releases)
and mirrored at **[h3o.de](https://h3o.de)**. Both are self-contained: there is
nothing to install alongside them.

**Windows** — `embrace-windows-x64.exe`, statically linked. Download and run.

**Linux** — `embrace-linux-x86_64.AppImage`, which bundles SFML/CSFML and the
other non-system libraries it needs (host graphics libraries such as `libGL`
come from the system, per the AppImage convention):

```sh
chmod +x embrace-linux-x86_64.AppImage
./embrace-linux-x86_64.AppImage
```

The AppImage needs `libfuse2`; on systems that ship only fuse3, run it with
`--appimage-extract-and-run`.

## Build from Source

Embrace is written in [Crystal](https://crystal-lang.org/) and uses
[crymble-ui](https://github.com/wolfgang371/crymbleui) (MIT) as its GUI
framework, rendered with SFML.

**Requirements**

- Crystal `>= 1.20.0`
- On Linux, the X11 and graphics runtime libraries your distribution already
  ships (`libX11`, `libXcursor`, `libXrandr`, `libXi`, `libfreetype`, `libudev`,
  …). You do **not** need system SFML packages: crymble-ui vendors SFML 3 /
  CSFML 3, and `shards install` brings them in with it.

**Build**

```sh
shards install                  # fetches crymble-ui and its vendored SFML/CSFML
source setup.sh                 # puts those libraries on the build and run paths
shards build embrace            # or: shards build --release embrace
./bin/embrace
```

`setup.sh` has to be sourced **after** `shards install`, because it delegates to
`lib/crymble-ui/setup.sh` — the GUI library owns the vendored libraries and is the
single source of truth for the build environment. Source it in any shell that
builds **or runs** the binary: a local build links against those libraries rather
than bundling them, so without it `./bin/embrace` cannot find
`libcsfml-graphics.so`. (Bundling is exactly what the AppImage does for end users.)

Linux is the primary build target and is what CI exercises.

**Windows.** crymble-ui ships the SFML 3 / CSFML 3 static libs it needs. From an
MSVC "x64 Native Tools" shell, after `shards install --skip-postinstall`,
**`tools\win-build.bat`** produces `bin\embrace.exe` with the application icon
embedded (via a standard `.rc` resource — no third-party post-processing).
A polished Windows build guide is in progress.

## License

Embrace is free software, licensed under the
**[GNU Affero General Public License v3.0](LICENSE)** (AGPL-3.0-only).

A **commercial dual license** is available for organisations that cannot meet
the AGPL's obligations (e.g. embedding Embrace in a closed-source product or
offering it as a hosted service). Contact **wolfgang.mayerle@h3o.de** or see
[h3o.de](https://h3o.de) for terms.

## Contributing

Contributions are welcome! Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for
the development setup, test, and pull-request process, and
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) before participating.

Note that Embrace uses a dual-license (open-core) model, so contributions
require signing a [Contributor License Agreement](CLA.md) — the process is
automated via a bot on your first pull request.

To report a security issue, see [`SECURITY.md`](SECURITY.md).

## Trademarks

Airtable, Microsoft Access and Microsoft Lists are trademarks of their respective
owners. They are referenced here only for honest comparison and identification —
Embrace is an independent project, not affiliated with or endorsed by them.
