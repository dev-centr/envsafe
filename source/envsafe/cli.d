/**
 * Command-line front end. All I/O goes through `Io` so tests can prove that
 * secret values never reach stdout or stderr.
 */
module envsafe.cli;

import envsafe.dotenv;
import envsafe.validate;
import envsafe.fileio;
import envsafe.version_;
import std.array : appender;
import std.conv : to;
import std.string : startsWith, endsWith;
import std.array : join;
import std.algorithm : canFind;
import std.format : format;

enum Exit { ok = 0, invalid = 1, usage = 2, io = 3 }

struct Io
{
    string delegate() readStdin;
    void delegate(string) out_;
    void delegate(string) err;
    string delegate(string) getEnv; /// returns null when unset
}

private struct Opts
{
    string file = ".env";
    bool dryRun, backup, json, verbose, showMasked, stdin_, strict, exportPrefix;
    string fromEnv, schema, comment, after, section;
    bool hasComment, withComment, onlyExisting, onlyNew;
    string[] positional;
    bool help, version_;
}

immutable usageText = `envsafe - edit .env files without exposing secret values

Usage:
  <producer> | envsafe set KEY --stdin [options]
  envsafe set KEY --from-env NAME [options]
  envsafe unset KEY [KEY...] [--with-comment] [options]
  envsafe list [--show-masked] [--json] [options]
  envsafe validate [--schema PATH] [--strict] [--json] [options]
  envsafe mcp          (MCP server over stdio for AI agents)
  envsafe --version | --help

Options:
  -f, --file PATH     .env file to use (default: .env)
  --stdin             read the value from standard input (one trailing newline is dropped)
  --from-env NAME     read the value from environment variable NAME
  --export            prefix a newly added key with 'export '
  --only-existing     set: fail if KEY is missing (update only)
  --only-new          set: fail if KEY exists (never overwrite)
  --comment TEXT      set: add or replace the comment block attached above KEY
  --after KEY2        set: place a new KEY after KEY2
  --section HEADER    set: place a new KEY at the end of the section headed by
                      the comment line HEADER (created at the end if missing)
  --with-comment      unset: also remove the comment block attached above KEY
  --dry-run           print a redacted diff; do not write
  --backup            keep the previous file as PATH.bak
  --show-masked       list: show whether each key has a value, masked
  --schema PATH       validate: registry (.adoc/.md table or .env.example)
  --strict            validate: keys missing from the schema are errors
  --json              machine-readable output
  -v, --verbose       extra detail (never values)

set is an upsert: it updates KEY in place, or adds it if missing.
Comments are kept byte-for-byte; list shows each key's attached comment.
Values are never accepted as command-line arguments and never printed.
Exit codes: 0 ok, 1 validation failed, 2 usage error, 3 file error.
`;

private string jsonStr(string s)
{
    auto a = appender!string;
    a.put('"');
    foreach (dchar c; s)
    {
        switch (c)
        {
            case '"': a.put(`\"`); break;
            case '\\': a.put(`\\`); break;
            case '\n': a.put(`\n`); break;
            case '\r': a.put(`\r`); break;
            case '\t': a.put(`\t`); break;
            default:
                if (c < 0x20) a.put(format("\\u%04x", cast(uint) c));
                else a.put(c);
        }
    }
    a.put('"');
    return a.data;
}

private bool parseOpts(string[] args, ref Opts o, ref string bad)
{
    for (size_t i = 0; i < args.length; i++)
    {
        auto a = args[i];
        string need()
        {
            if (i + 1 >= args.length) { bad = "option " ~ a ~ " needs a value"; return null; }
            return args[++i];
        }
        switch (a)
        {
            case "-f", "--file": o.file = need(); if (o.file is null) return false; break;
            case "--from-env": o.fromEnv = need(); if (o.fromEnv is null) return false; break;
            case "--schema": o.schema = need(); if (o.schema is null) return false; break;
            case "--comment": o.comment = need(); if (o.comment is null) return false; o.hasComment = true; break;
            case "--after": o.after = need(); if (o.after is null) return false; break;
            case "--section": o.section = need(); if (o.section is null) return false; break;
            case "--with-comment": o.withComment = true; break;
            case "--only-existing": o.onlyExisting = true; break;
            case "--only-new": o.onlyNew = true; break;
            case "--stdin": o.stdin_ = true; break;
            case "--dry-run": o.dryRun = true; break;
            case "--backup": o.backup = true; break;
            case "--json": o.json = true; break;
            case "-v", "--verbose": o.verbose = true; break;
            case "--show-masked": o.showMasked = true; break;
            case "--strict": o.strict = true; break;
            case "--export": o.exportPrefix = true; break;
            case "-h", "--help": o.help = true; break;
            case "--version": o.version_ = true; break;
            default:
                if (a.startsWith("-") && a.length > 1)
                {
                    // do not echo: a mistyped value could be a secret
                    bad = "unknown option (argument " ~ (i + 1).to!string ~ ")";
                    return false;
                }
                o.positional ~= a;
        }
    }
    return true;
}

int run(string[] args, Io io)
{
    if (args.length == 0)
    {
        io.err(usageText);
        return Exit.usage;
    }
    auto cmd = args[0];
    Opts o;
    string bad;
    if (cmd == "--help" || cmd == "-h" || cmd == "help") { io.out_(usageText); return Exit.ok; }
    if (cmd == "--version") { io.out_("envsafe " ~ versionString ~ "\n"); return Exit.ok; }
    if (!parseOpts(args[1 .. $], o, bad))
    {
        io.err("error: " ~ bad ~ "\n");
        return Exit.usage;
    }
    if (o.help) { io.out_(usageText); return Exit.ok; }
    switch (cmd)
    {
        case "set": return cmdSet(o, io);
        case "unset": return cmdUnset(o, io);
        case "list": return cmdList(o, io);
        case "validate": return cmdValidate(o, io);
        case "mcp":
            import envsafe.mcp : serve;
            return serve(io.getEnv);
        default:
            io.err("error: unknown command (try --help)\n");
            return Exit.usage;
    }
}

private bool load(const ref Opts o, Io io, bool mustExist, ref Document d)
{
    string content;
    auto r = readEnvFile(o.file, content);
    if (r == ReadResult.missing)
    {
        if (mustExist)
        {
            io.err("error: file not found: " ~ o.file ~ "\n");
            return false;
        }
        d = parse("");
        return true;
    }
    if (r == ReadResult.notUtf8)
    {
        io.err("error: file is not valid UTF-8: " ~ o.file ~ "\n");
        return false;
    }
    if (r != ReadResult.ok)
    {
        io.err("error: cannot read file: " ~ o.file ~ "\n");
        return false;
    }
    d = parse(content);
    return true;
}

private string redactedLine(const ref Line l)
{
    final switch (l.kind)
    {
        case Kind.entry: return l.lead ~ l.key ~ "=<redacted>";
        case Kind.comment: return "<comment>";
        case Kind.blank: return "";
        case Kind.invalid: return "<invalid line>";
    }
}

private void printDiff(const ref Opts o, Io io, const Change[] ch, const ref Document before, const ref Document after)
{
    auto a = appender!string;
    a.put("--- " ~ o.file ~ "\n+++ " ~ o.file ~ " (dry run, values redacted)\n");
    foreach (c; ch)
    {
        final switch (c.op)
        {
            case Change.Op.modified:
                a.put(format("@@ line %s: would update %s @@\n-%s=<redacted>\n+%s=<redacted>\n", c.lineNo, c.key, c.key, c.key));
                break;
            case Change.Op.added:
                a.put(format("@@ line %s: would add %s @@\n+%s=<redacted>\n", c.lineNo, c.key, c.key));
                break;
            case Change.Op.removed:
                a.put(format("@@ line %s: would remove %s @@\n-%s=<redacted>\n", c.lineNo, c.key, c.key));
                break;
            case Change.Op.commented:
                a.put(format("@@ line %s: would set comment above %s @@\n", c.lineNo, c.key));
                break;
        }
    }
    if (!ch.length)
        a.put("(no changes)\n");
    io.out_(a.data);
}

private int write(const ref Opts o, Io io, ref Document before, ref Document d, Change[] ch, string verb)
{
    if (o.dryRun)
    {
        printDiff(o, io, ch, before, d);
        return Exit.ok;
    }
    if (!ch.length && !before.hadBom)
    {
        io.out_("no changes: " ~ o.file ~ "\n");
        return Exit.ok;
    }
    string why;
    if (!atomicWrite(o.file, d.serialize(), o.backup, why))
    {
        io.err("error: write failed for " ~ o.file ~ ": " ~ why ~ "\n");
        return Exit.io;
    }
    string[] keys;
    foreach (c; ch) keys ~= c.key;
    io.out_(format("%s %s in %s%s\n", verb, ch.length ? keys[0] : "nothing",
        o.file, o.backup ? " (backup: " ~ o.file ~ ".bak)" : ""));
    if (o.verbose)
        foreach (c; ch)
            io.out_(format("  %s line %s: %s\n", c.op, c.lineNo, c.key));
    return Exit.ok;
}

private int cmdSet(ref Opts o, Io io)
{
    if (o.onlyExisting && o.onlyNew)
    {
        io.err("error: --only-existing and --only-new cannot be combined\n");
        return Exit.usage;
    }
    if (o.positional.length == 0)
    {
        io.err("error: set needs KEY\n");
        return Exit.usage;
    }
    if (o.positional.length > 1)
    {
        io.err("error: values are not accepted as arguments; pipe them with --stdin or use --from-env\n");
        return Exit.usage;
    }
    auto key = o.positional[0];
    if (!isValidKey(key))
    {
        io.err("error: invalid key name\n");
        return Exit.usage;
    }
    if (o.stdin_ == (o.fromEnv.length > 0))
    {
        io.err("error: set needs exactly one of --stdin or --from-env NAME\n");
        return Exit.usage;
    }
    string value;
    if (o.stdin_)
    {
        value = io.readStdin();
        if (value.endsWith("\r\n")) value = value[0 .. $ - 2];
        else if (value.endsWith("\n")) value = value[0 .. $ - 1];
    }
    else
    {
        value = io.getEnv(o.fromEnv);
        if (value is null)
        {
            io.err("error: environment variable is not set: " ~ o.fromEnv ~ "\n");
            return Exit.usage;
        }
    }
    if (o.hasComment && value.length && o.comment.canFind(value))
    {
        io.err("error: refusing a comment that contains the value\n");
        return Exit.usage;
    }
    Document d;
    if (!load(o, io, false, d))
        return Exit.io;
    auto exists_ = d.find(key).length > 0;
    if (o.onlyExisting && !exists_)
    {
        io.err("error: key not present (--only-existing): " ~ key ~ "\n");
        return Exit.invalid;
    }
    if (o.onlyNew && exists_)
    {
        io.err("error: key already present (--only-new): " ~ key ~ "\n");
        return Exit.invalid;
    }
    if (o.after.length && !d.find(o.after).length)
    {
        io.err("error: --after key not found: " ~ o.after ~ "\n");
        return Exit.usage;
    }
    auto before = d;
    before.lines = d.lines.dup;
    auto ch = setValue(d, key, value, o.exportPrefix, Placement(o.after, o.section));
    if (o.hasComment)
        ch ~= setComment(d, key, o.comment);
    return write(o, io, before, d, ch, exists_ ? "updated" : "added");
}

private int cmdUnset(ref Opts o, Io io)
{
    if (o.positional.length == 0)
    {
        io.err("error: unset needs at least one KEY\n");
        return Exit.usage;
    }
    Document d;
    if (!load(o, io, true, d))
        return Exit.io;
    auto before = d;
    before.lines = d.lines.dup;
    Change[] ch;
    foreach (k; o.positional)
    {
        if (!isValidKey(k))
        {
            io.err("error: invalid key name\n");
            return Exit.usage;
        }
        ch ~= unsetKey(d, k, o.withComment);
    }
    return write(o, io, before, d, ch, "removed");
}

private int cmdList(ref Opts o, Io io)
{
    Document d;
    if (!load(o, io, true, d))
        return Exit.io;
    auto a = appender!string;
    if (o.json)
    {
        string[] items;
        foreach (i, ref l; d.lines)
            if (l.kind == Kind.entry)
            {
                auto ic = inlineComment(l);
                items ~= format(`{"key":%s,"line":%s,"hasValue":%s,"comment":%s,"inlineComment":%s}`,
                    jsonStr(l.key), l.lineNo, decodeValue(l).length > 0,
                    jsonStr(attachedComment(d, i).join("\n")), ic is null ? "null" : jsonStr(ic));
            }
        a.put(format(`{"file":%s,"keys":[%s]}`, jsonStr(o.file), items.join(",")) ~ "\n");
    }
    else
    {
        foreach (i, ref l; d.lines)
        {
            if (l.kind != Kind.entry)
                continue;
            string line = o.showMasked ? l.key ~ "=" ~ (decodeValue(l).length ? "********" : "") : l.key;
            string[] notes = attachedComment(d, i);
            if (auto ic = inlineComment(l)) notes ~= ic;
            if (notes.length)
                line ~= "  # " ~ notes.join(" / ");
            a.put(line ~ "\n");
        }
    }
    io.out_(a.data);
    return Exit.ok;
}

private int cmdValidate(ref Opts o, Io io)
{
    Document d;
    if (!load(o, io, true, d))
        return Exit.io;
    Schema s;
    Schema* sp = null;
    if (o.schema.length)
    {
        string content;
        if (readEnvFile(o.schema, content) != ReadResult.ok)
        {
            io.err("error: cannot read schema: " ~ o.schema ~ "\n");
            return Exit.io;
        }
        s = loadSchema(o.schema, content);
        sp = &s;
    }
    auto issues = validate(d, sp, o.strict);
    bool failed = false;
    foreach (i; issues) if (i.error) failed = true;
    auto a = appender!string;
    if (o.json)
    {
        string[] items;
        foreach (i; issues)
            items ~= format(`{"severity":%s,"line":%s,"code":%s,"key":%s,"message":%s}`,
                jsonStr(i.error ? "error" : "warning"), i.lineNo, jsonStr(i.code), jsonStr(i.key), jsonStr(i.message));
        a.put(format(`{"file":%s,"ok":%s,"issues":[%s]}`, jsonStr(o.file), !failed, items.join(",")) ~ "\n");
        io.out_(a.data);
    }
    else
    {
        foreach (i; issues)
            a.put(format("%s:%s: %s: %s%s\n", o.file, i.lineNo, i.error ? "error" : "warning",
                i.key.length ? i.key ~ ": " : "", i.message));
        if (failed)
            io.err(a.data ~ "validation failed: " ~ o.file ~ "\n");
        else
            io.out_(a.data ~ "ok: " ~ o.file ~ "\n");
    }
    return failed ? Exit.invalid : Exit.ok;
}

// ---------------------------------------------------------------- tests

version (unittest)
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists, readText, fwrite = write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.algorithm : canFind;

    private struct Capture
    {
        string stdin_;
        string outText, errText;
        string[string] env;
        Io io()
        {
            Io r;
            r.readStdin = () => stdin_;
            r.out_ = (string s) { outText ~= s; };
            r.err = (string s) { errText ~= s; };
            r.getEnv = (string k) { auto p = k in env; return p ? *p : null; };
            return r;
        }
    }

    private string scratchDir(string name)
    {
        auto d = buildPath(tempDir, "envsafe-test-" ~ thisProcessID.to!string ~ "-" ~ name);
        if (exists(d)) rmdirRecurse(d);
        mkdirRecurse(d);
        return d;
    }
}

unittest // secret values never reach stdout or stderr
{
    enum secret = "S3CRET-sentinel-7f3a9c";
    auto dir = scratchDir("secret");
    scope (exit) rmdirRecurse(dir);
    auto f = buildPath(dir, ".env");
    fwrite(f, "# c\r\nOLD=" ~ secret ~ "x\r\n");

    Capture c;
    c.stdin_ = secret ~ "\n";
    c.env["SRC"] = secret;
    auto cmds = [
        ["set", "API_KEY", "--stdin", "-f", f, "--dry-run"],
        ["set", "API_KEY", "--stdin", "-f", f, "-v"],
        ["set", "OTHER", "--from-env", "SRC", "-f", f, "--backup"],
        ["set", "OLD", "--stdin", "-f", f, "--dry-run", "-v"],
        ["list", "-f", f],
        ["list", "-f", f, "--show-masked"],
        ["list", "-f", f, "--json"],
        ["validate", "-f", f],
        ["validate", "-f", f, "--json"],
        ["unset", "OLD", "-f", f, "--dry-run"],
        ["set", "K", secret, "-f", f], // value on argv must be refused without echo
        ["set", "K", "--stdin", secret, "-f", f],
        ["set", "K", "--bogus=" ~ secret, "-f", f],
    ];
    foreach (cmd; cmds)
        run(cmd, c.io());
    assert(!c.outText.canFind(secret), "secret leaked to stdout");
    assert(!c.errText.canFind(secret), "secret leaked to stderr");
    // the value did land in the file, and line endings stayed CRLF
    auto body_ = readText(f);
    assert(body_ == "# c\r\nOLD=" ~ secret ~ "x\r\nAPI_KEY=" ~ secret ~ "\r\nOTHER=" ~ secret ~ "\r\n", body_);
    assert(readText(f ~ ".bak") == "# c\r\nOLD=" ~ secret ~ "x\r\nAPI_KEY=" ~ secret ~ "\r\n");
}

unittest // dry run does not write; exit codes
{
    auto dir = scratchDir("dry");
    scope (exit) rmdirRecurse(dir);
    auto f = buildPath(dir, ".env");
    fwrite(f, "A=1\nA=2\n");
    Capture c;
    c.stdin_ = "v";
    assert(run(["set", "B", "--stdin", "-f", f, "--dry-run"], c.io()) == Exit.ok);
    assert(readText(f) == "A=1\nA=2\n");
    assert(c.outText.canFind("+B=<redacted>"));
    assert(run(["validate", "-f", f], c.io()) == Exit.invalid);
    assert(run(["list", "-f", buildPath(dir, "missing")], c.io()) == Exit.io);
    assert(run(["set", "B", "-f", f], c.io()) == Exit.usage);
    assert(!exists(f ~ ".bak"));
}

unittest // upsert by default; --only-existing / --only-new; dry-run wording
{
    auto dir = scratchDir("upsert");
    scope (exit) rmdirRecurse(dir);
    auto f = buildPath(dir, ".env");
    fwrite(f, "# == App ==\nA=1 # inline\n\n# == Mail ==\nM=1\n");
    Capture c;
    c.stdin_ = "2";
    assert(run(["set", "A", "--stdin", "-f", f, "--dry-run"], c.io()) == Exit.ok);
    assert(c.outText.canFind("would update A"));
    assert(run(["set", "NEW", "--stdin", "-f", f, "--dry-run"], c.io()) == Exit.ok);
    assert(c.outText.canFind("would add NEW"));
    assert(run(["set", "NEW", "--stdin", "-f", f, "--only-existing"], c.io()) == Exit.invalid);
    assert(run(["set", "A", "--stdin", "-f", f, "--only-new"], c.io()) == Exit.invalid);
    assert(readText(f) == "# == App ==\nA=1 # inline\n\n# == Mail ==\nM=1\n");
    assert(run(["set", "A", "--stdin", "-f", f, "--only-existing"], c.io()) == Exit.ok);
    assert(run(["set", "B", "--stdin", "-f", f, "--only-new", "--section", "# == App ==",
        "--comment", "bee"], c.io()) == Exit.ok);
    assert(readText(f) == "# == App ==\nA=2 # inline\n# bee\nB=2\n\n# == Mail ==\nM=1\n", readText(f));
    c.outText = null;
    assert(run(["list", "-f", f], c.io()) == Exit.ok);
    assert(c.outText == "A  # == App == / inline\nB  # bee\nM  # == Mail ==\n", c.outText);
    assert(run(["unset", "B", "-f", f, "--with-comment"], c.io()) == Exit.ok);
    assert(readText(f) == "# == App ==\nA=2 # inline\n\n# == Mail ==\nM=1\n");
    // a comment may not carry the secret
    c.stdin_ = "topsecretvalue";
    c.errText = null;
    assert(run(["set", "A", "--stdin", "-f", f, "--comment", "x topsecretvalue"], c.io()) == Exit.usage);
    assert(!c.errText.canFind("topsecretvalue"));
}
