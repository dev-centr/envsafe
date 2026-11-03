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
- [Comments and placement](#comments-and-placement)
- [MCP server](#mcp-server)
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

- **macOS:** `brew install dev-centr/tap/envsafe`. Or download `envsafe-<version>-macos-universal.pkg` (or `-macos-arm64.pkg`) from [Releases](https://github.com/dev-centr/envsafe/releases) and run it; it installs to `/usr/local/bin`. The `.pkg` is not signed yet, so right-click it and choose **Open** the first time.
- **Linux (Homebrew):** `brew install dev-centr/tap/envsafe`.
- **Debian / Ubuntu:** download `envsafe_<version>_amd64.deb` (or `_arm64.deb`) and run `sudo apt install ./envsafe_<version>_amd64.deb`.
- **Fedora / RHEL / openSUSE:** download `envsafe-<version>-1.x86_64.rpm` (or `.aarch64.rpm`) and run `sudo dnf install ./envsafe-<version>-1.x86_64.rpm`.
- **Windows:** download `envsafe-<version>-windows-x64.msi` from [Releases](https://github.com/dev-centr/envsafe/releases) and run it. It installs to `Program Files\envsafe` and adds that folder to PATH (open a new terminal afterwards).
- **Packagers:** each release also carries the bare binary as `.tar.gz` (Linux x64/arm64, macOS) and `.zip` (Windows), plus `SHA256SUMS.txt`.
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
| `set KEY --stdin \| --from-env NAME` | Upsert: updates every occurrence of `KEY` in place (keeping its quote style and inline comment) or adds it. `--only-existing` fails if the key is missing; `--only-new` fails if it exists and never overwrites. One trailing newline from stdin is dropped. `--export` prefixes a new key with `export `. Dry runs say *would add* or *would update*. |
| `unset KEY...` | Removes every occurrence of each key. The comment block above it stays unless `--with-comment`. |
| `list` | Key names in file order, each with its attached and inline comment. `--show-masked` adds a masked marker; `--json` gives `{key, line, hasValue, comment, inlineComment}`. |
| `mcp` | Runs an MCP server over stdio (see below). |
| `validate` | Syntax errors, duplicate keys, and (with `--schema`) unknown, missing or empty required keys. `--strict` makes unknown keys errors. |

Common options: `-f, --file PATH` (default `.env`), `--dry-run`, `--backup`, `--json`, `-v, --verbose`, `--version`, `--help`.

Exit codes: `0` ok, `1` validation failed, `2` usage error, `3` file error.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Comments and placement

Comments are for humans and are never treated as secret. Every full-line comment, inline comment (`KEY=val # note`), blank line and section header is kept byte-for-byte. The comment lines directly above a key (no blank line between) are that key's *attached comment*.

```sh
# add or replace the attached comment
printf '%s' "$TOKEN" | envsafe set GITHUB_TOKEN --stdin --comment "Fine-grained PAT, repo read only"
# place a new key after another key, or at the end of a section
printf '%s' "$V" | envsafe set SMTP_PASS --stdin --after SMTP_USER
printf '%s' "$V" | envsafe set SMTP_PASS --stdin --section "# == Mail =="
# remove a key together with its attached comment
envsafe unset OLD_KEY --with-comment
```

`--section` matches a comment line exactly; a new key goes after the last line of that section (the section ends at a blank line followed by another comment). If the header is missing it is created at the end of the file. envsafe refuses a `--comment` that contains the value being set.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## MCP server

`envsafe mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io) over stdio, so agents can call it as tools:

| Tool | Arguments |
| --- | --- |
| `envsafe_set` | `key`, exactly one of `from_env` (name of an environment variable visible to the server) or `from_file` (path whose contents are the value); optional `file`, `only_existing`, `only_new`, `comment`, `after`, `section`, `export`, `dry_run`, `backup` |
| `envsafe_unset` | `keys`, optional `file`, `with_comment`, `dry_run`, `backup` |
| `envsafe_list` | optional `file`, `show_masked` |
| `envsafe_validate` | optional `file`, `schema`, `strict` |

There is no inline `value` argument: tool arguments pass through the model's context, so values must come from the server's environment or a file. Responses never contain values; `dry_run` returns the redacted diff. Relative `file` paths resolve against the server's working directory, so prefer absolute paths.

**Cursor** (`~/.cursor/mcp.json` or the project's `.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "envsafe": { "command": "envsafe", "args": ["mcp"] }
  }
}
```

**Claude Code:**

```sh
claude mcp add envsafe -- envsafe mcp
```

**Grok Bot and other MCP clients:** add a custom stdio server with command `envsafe` and arguments `mcp` (same shape as the Cursor JSON above). To hand the server a secret, set it in the server's `env` block or point `from_file` at a file the client writes.

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
