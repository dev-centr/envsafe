<a id="readme-top"></a>

<div align="center">

<a href="https://github.com/dev-centr/envsafe/releases/latest"><img src="https://img.shields.io/github/v/release/dev-centr/envsafe?style=for-the-badge" alt="Latest release"></a>
<a href="https://github.com/dev-centr/envsafe/issues"><img src="https://img.shields.io/github/issues/dev-centr/envsafe?style=for-the-badge" alt="Issues"></a>
<a href="https://github.com/dev-centr/envsafe/blob/main/LICENSE"><img src="https://img.shields.io/github/license/dev-centr/envsafe?style=for-the-badge" alt="License"></a>

<h1>envsafe</h1>

<p>Edit <code>.env</code> files from scripts and AI agents without ever putting a secret on the command line or in the output.</p>

<p>
<a href="https://docs.devcentr.org"><strong>Explore the docs »</strong></a>
·
<a href="https://github.com/dev-centr/envsafe/releases">Download</a>
·
<a href="https://github.com/dev-centr/envsafe/issues">Report a bug</a>
</p>

</div>

## Contents

- [Why](#why)
- [Install](#install)
- [Usage](#usage)
- [Schema files](#schema-files)
- [Library use](#library-use)
- [Built with](#built-with)
- [Changelog](#changelog)
- [License](#license)

## Why

Agents and scripts often need to add or rotate a key in a `.env` file. The usual ways (`echo KEY=value >> .env`, `sed -i`) put the value in shell history, process lists and logs, and they mangle comments, quotes and line endings. envsafe:

- takes values only from a pipe (`--stdin`) or another environment variable (`--from-env`), never from argv;
- never prints a value: `list` shows names, `--dry-run` shows a redacted diff, errors name keys and lines only;
- keeps every untouched line byte-for-byte (comments, blank lines, order, quoting, `export`, CRLF or LF);
- writes atomically (temp file in the same folder, then rename), keeps a `.bak` only with `--backup`, and never writes a BOM.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Install

- **Windows:** download `envsafe-<version>-windows-x64.msi` from [Releases](https://github.com/dev-centr/envsafe/releases) and run it. It installs to `Program Files\envsafe` and adds that folder to PATH (open a new terminal afterwards).
- **Linux / macOS:** download the `.tar.gz` for your platform, unpack it, and put `envsafe` somewhere on PATH.
- **From source:** install [LDC](https://github.com/ldc-developers/ldc) and run `dub build -b release` (binary in `bin/`).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Usage

```sh
# add or update a key; the value comes from a pipe
op read "op://vault/api/key" | envsafe set API_KEY --stdin
# or copy it from another environment variable
envsafe set API_KEY --from-env CI_API_KEY -f .env.local

# preview a change with values redacted
printf '%s' "$NEW" | envsafe set API_KEY --stdin --dry-run

envsafe unset OLD_KEY OTHER_KEY --backup
envsafe list                      # names only
envsafe list --show-masked        # NAME=******** or NAME= when empty
envsafe validate --schema docs/environment-variables.adoc --strict
```

| Command | What it does |
| --- | --- |
| `set KEY --stdin \| --from-env NAME` | Updates every occurrence of `KEY` (keeping its quote style when possible) or appends it. One trailing newline from stdin is dropped. `--export` prefixes a new key with `export `. |
| `unset KEY...` | Removes every occurrence of each key. |
| `list` | Key names in file order. `--show-masked` adds a masked marker; `--json` gives `{key, line, hasValue}`. |
| `validate` | Syntax errors, duplicate keys, and (with `--schema`) unknown, missing or empty required keys. `--strict` makes unknown keys errors. |

Common options: `-f, --file PATH` (default `.env`), `--dry-run`, `--backup`, `--json`, `-v, --verbose`, `--version`, `--help`.

Exit codes: `0` ok, `1` validation failed, `2` usage error, `3` file error.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Schema files

`--schema` accepts either:

- an env-names registry table in AsciiDoc (`environment-variables.adoc`) or Markdown (`ENV-VARIABLES.md`): the first column holds `` `NAME` `` and the third column says `Yes` when the key is required;
- a dotenv-style file such as `.env.example`: every entry is a known key, and an entry whose trailing comment contains `required` is required.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Library use

The `library` DUB configuration exposes the parser and editor (`import envsafe;`): `parse`, `Document.serialize`, `setValue`, `unsetKey`, `validate`, `loadSchema`, and `atomicWrite`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Built with

- **Language and build:** [D](https://dlang.org) with [LDC](https://github.com/ldc-developers/ldc) and [DUB](https://dub.pm)
- **Packaging:** [WiX Toolset v5](https://wixtoolset.org) (MSI), GitHub Actions

## Changelog

See [CHANGELOG.adoc](CHANGELOG.adoc).

## License

MIT. See [LICENSE](LICENSE).

<p align="right">(<a href="#readme-top">back to top</a>)</p>
