/// Validation of a .env document against syntax rules and an optional registry.
module envsafe.validate;

import envsafe.dotenv;
import std.algorithm : canFind;
import std.string : strip, split, toLower, endsWith, indexOf;
import std.conv : to;

struct Issue
{
    bool error;      /// false = warning
    size_t lineNo;   /// 0 when not tied to a line
    string code;
    string key;      /// may be empty; never a value
    string message;  /// never contains a value
}

struct SchemaKey { string name; bool required; }

struct Schema
{
    SchemaKey[] keys;
    bool has(string k) const { foreach (s; keys) if (s.name == k) return true; return false; }
}

/// Load a registry: an env-names-registry AsciiDoc/Markdown table, or a dotenv-style
/// file such as `.env.example` (an entry whose comment contains `required` is required).
Schema loadSchema(string path, string content)
{
    Schema s;
    auto lower = path.toLower;
    if (lower.endsWith(".adoc") || lower.endsWith(".md"))
    {
        string[] cells;
        foreach (raw; content.split('\n'))
        {
            auto line = raw.strip;
            if (!line.length || line[0] != '|' || line.startsWithTable)
                continue;
            foreach (c; line[1 .. $].split('|'))
                cells ~= c.strip;
        }
        foreach (i, c; cells)
        {
            if (c.length > 2 && c[0] == '`' && c[$ - 1] == '`' && isValidKey(c[1 .. $ - 1]))
            {
                bool req = i + 2 < cells.length && cells[i + 2].toLower == "yes";
                s.keys ~= SchemaKey(c[1 .. $ - 1], req);
            }
        }
        return s;
    }
    auto d = parse(content);
    foreach (ref l; d.lines)
        if (l.kind == Kind.entry)
            s.keys ~= SchemaKey(l.key, l.tail.toLower.canFind("required"));
    return s;
}

private bool startsWithTable(string l) { return l.length >= 4 && l[0 .. 4] == "|==="; }

Issue[] validate(const ref Document d, const Schema* schema, bool strict)
{
    Issue[] r;
    if (d.hadBom)
        r ~= Issue(false, 1, "bom", "", "file starts with a UTF-8 BOM; envsafe writes files without one");
    size_t[string] firstSeen;
    foreach (ref l; d.lines)
    {
        if (l.kind == Kind.invalid)
        {
            r ~= Issue(true, l.lineNo, "syntax", "", l.error);
            continue;
        }
        if (l.kind != Kind.entry)
            continue;
        if (auto p = l.key in firstSeen)
            r ~= Issue(true, l.lineNo, "duplicate", l.key,
                "duplicate key (first defined on line " ~ (*p).to!string ~ ")");
        else
            firstSeen[l.key] = l.lineNo;
        if (schema !is null && !schema.has(l.key))
            r ~= Issue(strict, l.lineNo, "unknown", l.key, "key is not in the schema/registry");
    }
    if (schema !is null)
    {
        foreach (sk; schema.keys)
        {
            if (!sk.required)
                continue;
            auto idx = d.find(sk.name);
            if (!idx.length)
                r ~= Issue(true, 0, "missing", sk.name, "required key is missing");
            else if (decodeValue(d.lines[idx[$ - 1]]).length == 0)
                r ~= Issue(true, d.lines[idx[$ - 1]].lineNo, "empty", sk.name, "required key has an empty value");
        }
    }
    return r;
}

unittest
{
    auto d = parse("A=1\nA=2\nbad line\nX=\n");
    auto issues = validate(d, null, false);
    assert(issues.length == 2);
    assert(issues[0].code == "duplicate" && issues[0].lineNo == 2);
    assert(issues[1].code == "syntax" && issues[1].lineNo == 3);
}

unittest
{
    auto adoc = "[cols=\"2,3,1,2,3\",options=\"header\"]\n|===\n| Variable | Purpose | Required | If unset | Source\n\n"
        ~ "| `API_KEY`\n| Signs requests.\n| Yes\n| 503\n| Vendor\n\n| `DEBUG`\n| Logs.\n| No\n| off\n| local\n|===\n";
    auto s = loadSchema("docs/environment-variables.adoc", adoc);
    assert(s.keys.length == 2 && s.keys[0].required && !s.keys[1].required);
    auto md = "| Variable | Purpose | Required | If unset | Source |\n| --- | --- | --- | --- | --- |\n| `TOKEN` | t | Yes | x | y |\n";
    auto m = loadSchema("ENV-VARIABLES.md", md);
    assert(m.keys.length == 1 && m.keys[0].name == "TOKEN" && m.keys[0].required);
    auto d = parse("DEBUG=1\nEXTRA=2\n");
    auto issues = validate(d, &s, false);
    assert(issues.length == 2);
    assert(!issues[0].error && issues[0].code == "unknown");
    assert(issues[1].error && issues[1].code == "missing" && issues[1].key == "API_KEY");
    auto ex = loadSchema(".env.example", "A= # required\nB=\n");
    assert(ex.keys.length == 2 && ex.keys[0].required && !ex.keys[1].required);
}
