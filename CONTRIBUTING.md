# Contributing to Embrace

Thank you for your interest in contributing to Embrace! This document explains
how to get involved and what we need from you so that contributions can be
accepted.

By participating in this project you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to Contribute

- **Report bugs** and request features via GitHub Issues. Please include the
  Embrace version, your OS, and clear reproduction steps.
- **Improve documentation** — fixes to the README, build notes, or `doc/` are
  very welcome.
- **Submit code** via pull requests (see below).

For security vulnerabilities, do **not** open a public issue — follow
[`SECURITY.md`](SECURITY.md) instead.

## Development Setup

Embrace is written in [Crystal](https://crystal-lang.org/) (`>= 1.20.0`) and
uses [crymble-ui](https://github.com/wolfgang371/crymbleui) (MIT) as its GUI
framework on top of SFML.

```sh
shards install
shards build embrace        # or: shards build --release embrace
./bin/embrace
```

If you are co-developing crymble-ui and Embrace, point at a local checkout via a
`shard.override.yml` (gitignored) — `shards install` then resolves crymble-ui
locally:

```yaml
dependencies:
  crymble-ui:
    path: /absolute/path/to/your/crymble-ui
```

Remove the override (and run `shards update crymble-ui`) to return to the pinned
GitHub version.

### Running the tests

The test suite must be run in **two separate groups**. Running the full suite
in a single `crystal spec` invocation can crash because the GUI specs spin up
their own fibers/event loop:

```sh
crystal spec spec/*.cr        # core / data-layer specs
crystal spec spec/gui/*.cr    # GUI specs
```

Please make sure both groups pass before opening a pull request, and add tests
for any behaviour you change or add.

### Coding style

Match the style of the surrounding code. Keep changes focused — unrelated
reformatting makes review harder.

## Pull Request Process

1. Fork the repository and create a topic branch from `master`.
2. Make your change, with tests, keeping commits focused and well-described.
3. Sign off your commits (see *Developer Certificate of Origin* below).
4. Open a pull request describing **what** changed and **why**.
5. Sign the Contributor License Agreement when the CLA bot prompts you (see
   below) — this is required before a PR can be merged.

A maintainer will review your PR. We may ask for changes; please don't take it
personally — review is how we keep the codebase healthy.

## Legal: CLA and DCO

Embrace is released under the [AGPL-3.0-only](LICENSE) **and** offered under a
separate [commercial license](LICENSE-COMMERCIAL.md) (open-core / dual-license
model). For this to work, the project maintainer must hold the rights to license
**every** contribution under both sets of terms. We therefore require two things
from contributors:

### 1. Contributor License Agreement (required)

Before your first contribution can be merged, you must agree to the
[Contributor License Agreement](CLA.md). This grants the maintainer the rights
needed to distribute your contribution under both the AGPL and the commercial
license, while **you retain copyright** to your work.

The agreement is handled automatically: when you open your first pull request, a
CLA-assistant bot will ask you to confirm the CLA by commenting on the PR. You
only need to do this once.

> A CLA — not just a DCO — is required, because the DCO alone does not grant the
> re-licensing rights the dual-license model depends on.

### 2. Developer Certificate of Origin (required)

In addition to the CLA, every commit must carry a `Signed-off-by` line
certifying the [Developer Certificate of Origin](https://developercertificate.org/).
Add it automatically with:

```sh
git commit -s
```

This produces a line like:

```
Signed-off-by: Your Name <you@example.com>
```

Use your real name and an email you can be reached at.

## License of Contributions

Unless explicitly stated otherwise, contributions you submit are licensed under
the AGPL-3.0-only, and — by accepting the CLA — you also grant the maintainer
the right to license your contribution under the commercial license described
in [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md).
