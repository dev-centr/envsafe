/**
 * Lossless .env document model.
 *
 * A document is a list of logical lines. Each line keeps its exact original
 * text and terminator, so serialising an unmodified document reproduces the
 * input byte for byte (minus a UTF-8 BOM, which envsafe never writes).
 */
module envsafe.dotenv;

import std.algorithm : canFind, all;
import std.array : appender;
import std.ascii : isAlpha, isDigit, isAlphaNum;
import std.string : startsWith, endsWith, indexOf, strip, toLower;

enum Kind { blank, comment, entry, invalid }

struct Line
{
    Kind kind;
    string text;      /// raw text without the final terminator (may contain inner newlines)
    string eol;       /// "\n", "\r\n", or "" at end of file
    size_t lineNo;    /// 1-based physical line where this logical line starts
    // entry parts; text == lead ~ key ~ sep ~ rawValue ~ tail
    string lead;      /// leading whitespace plus optional `export `
    string key;
    string sep;       /// whitespace, '=', whitespace
    string rawValue;  /// value token including any quotes
    string tail;      /// trailing whitespace and comment
    string error;     /// for invalid lines; never contains the line text
}

struct Document
{
    Line[] lines;
    bool hadBom;
    string defaultEol = "\n";

    /// Indices of entry lines with this key.
    size_t[] find(string key) const
    {
        size_t[] r;
        foreach (i, ref l; lines)
            if (l.kind == Kind.entry && l.key == key)
                r ~= i;
        return r;
    }

    string[] keys() const
    {
        string[] r;
        foreach (ref l; lines)
            if (l.kind == Kind.entry)
                r ~= l.key;
        return r;
    }

    string serialize() const
    {
        auto a = appender!string;
        foreach (ref l; lines)
        {
            a.put(l.text);
            a.put(l.eol);
        }
        return a.data;
    }
}

bool isValidKey(string k)
{
    if (k.length == 0 || !(isAlpha(k[0]) || k[0] == '_'))
        return false;
    return k.all!(c => isAlphaNum(c) || c == '_' || c == '.' || c == '-');
}

private bool isWs(char c) { return c == ' ' || c == '\t'; }

private struct Phys { string text; string eol; }

private Phys[] splitPhysical(string s)
{
    Phys[] r;
    size_t start = 0;
    for (size_t i = 0; i < s.length; i++)
    {
        if (s[i] == '\n')
        {
            size_t end = i;
            string eol = "\n";
            if (end > start && s[end - 1] == '\r')
            {
                end--;
                eol = "\r\n";
            }
            r ~= Phys(s[start .. end], eol);
            start = i + 1;
        }
    }
    if (start < s.length)
        r ~= Phys(s[start .. $], "");
    return r;
}

private enum PE { ok, needMore, bad }

/// Try to parse one logical entry. On PE.bad, l.error is set.
private PE parseEntry(string s, ref Line l)
{
    size_t i = 0;
    while (i < s.length && isWs(s[i])) i++;
    if (s[i .. $].startsWith("export") && s.length > i + 6 && isWs(s[i + 6]))
    {
        i += 6;
        while (i < s.length && isWs(s[i])) i++;
    }
    l.lead = s[0 .. i];
    size_t k = i;
    while (k < s.length && (isAlphaNum(s[k]) || s[k] == '_' || s[k] == '.' || s[k] == '-')) k++;
    l.key = s[i .. k];
    if (!isValidKey(l.key))
    {
        l.error = "invalid or missing key name";
        return PE.bad;
    }
    size_t j = k;
    while (j < s.length && isWs(s[j])) j++;
    if (j >= s.length || s[j] != '=')
    {
        l.error = "missing '=' after key";
        return PE.bad;
    }
    j++;
    while (j < s.length && isWs(s[j])) j++;
    l.sep = s[k .. j];
    size_t vend;
    if (j < s.length && (s[j] == '"' || s[j] == '\'' || s[j] == '`'))
    {
        const q = s[j];
        size_t m = j + 1;
        bool closed = false;
        while (m < s.length)
        {
            if (q == '"' && s[m] == '\\' && m + 1 < s.length) { m += 2; continue; }
            if (s[m] == q) { closed = true; break; }
            m++;
        }
        if (!closed)
            return PE.needMore;
        vend = m + 1;
        l.rawValue = s[j .. vend];
        l.tail = s[vend .. $];
        auto t = l.tail.strip;
        if (t.length && t[0] != '#')
        {
            l.error = "unexpected text after closing quote";
            return PE.bad;
        }
        return PE.ok;
    }
    // unquoted: ends at whitespace followed by '#', or end of line
    vend = s.length;
    for (size_t m = j; m < s.length; m++)
        if (s[m] == '#' && isWs(s[m - 1])) { vend = m; break; }
    while (vend > j && isWs(s[vend - 1])) vend--;
    l.rawValue = s[j .. vend];
    l.tail = s[vend .. $];
    if (l.rawValue.canFind('\r'))
    {
        l.error = "stray carriage return in value";
        return PE.bad;
    }
    return PE.ok;
}

Document parse(string input)
{
    Document d;
    if (input.startsWith("\xEF\xBB\xBF"))
    {
        d.hadBom = true;
        input = input[3 .. $];
    }
    auto ph = splitPhysical(input);
    foreach (p; ph)
        if (p.eol.length) { d.defaultEol = p.eol; break; }

    for (size_t i = 0; i < ph.length; i++)
    {
        Line l;
        l.lineNo = i + 1;
        auto st = ph[i].text.strip;
        if (st.length == 0)
        {
            l.kind = Kind.blank;
            l.text = ph[i].text;
            l.eol = ph[i].eol;
            d.lines ~= l;
            continue;
        }
        if (st[0] == '#')
        {
            l.kind = Kind.comment;
            l.text = ph[i].text;
            l.eol = ph[i].eol;
            d.lines ~= l;
            continue;
        }
        string acc = ph[i].text;
        string eol = ph[i].eol;
        size_t j = i;
        for (;;)
        {
            Line t = l;
            auto r = parseEntry(acc, t);
            if (r == PE.ok)
            {
                t.kind = Kind.entry;
                t.text = acc;
                t.eol = eol;
                d.lines ~= t;
                i = j;
                break;
            }
            if (r == PE.bad || j + 1 >= ph.length)
            {
                // fall back to the single physical line, marked invalid
                Line bad = l;
                bad.kind = Kind.invalid;
                bad.text = ph[i].text;
                bad.eol = ph[i].eol;
                bad.error = r == PE.bad ? t.error : "unterminated quoted value";
                if (r == PE.bad) { /* nothing */ }
                d.lines ~= bad;
                break;
            }
            j++;
            acc = acc ~ eol ~ ph[j].text;
            eol = ph[j].eol;
        }
    }
    return d;
}

/// Decoded value of an entry line.
string decodeValue(const ref Line l)
{
    auto v = l.rawValue;
    if (v.length >= 2 && (v[0] == '\'' || v[0] == '`') && v[$ - 1] == v[0])
        return v[1 .. $ - 1];
    if (v.length >= 2 && v[0] == '"' && v[$ - 1] == '"')
    {
        auto inner = v[1 .. $ - 1];
        auto a = appender!string;
        for (size_t i = 0; i < inner.length; i++)
        {
            if (inner[i] == '\\' && i + 1 < inner.length)
            {
                const c = inner[i + 1];
                switch (c)
                {
                    case 'n': a.put('\n'); i++; continue;
                    case 'r': a.put('\r'); i++; continue;
                    case 't': a.put('\t'); i++; continue;
                    case '"': a.put('"'); i++; continue;
                    case '\\': a.put('\\'); i++; continue;
                    default: break;
                }
            }
            a.put(inner[i]);
        }
        return a.data;
    }
    return v;
}

private bool safeUnquoted(string v)
{
    return v.all!(c => isAlphaNum(c) || "_./:@+,=%-~".canFind(c));
}

private string doubleQuote(string v)
{
    auto a = appender!string;
    a.put('"');
    foreach (c; v)
    {
        switch (c)
        {
            case '\\': a.put(`\\`); break;
            case '"': a.put(`\"`); break;
            case '\n': a.put(`\n`); break;
            case '\r': a.put(`\r`); break;
            default: a.put(c);
        }
    }
    a.put('"');
    return a.data;
}

/// Encode a value, keeping the existing quote style (0 = unquoted) when it can hold the value.
string encodeValue(string v, char style)
{
    if (style == '\'' && !v.canFind('\'') && !v.canFind('\n') && !v.canFind('\r'))
        return "'" ~ v ~ "'";
    if (style == 0 && safeUnquoted(v))
        return v;
    return doubleQuote(v);
}

private char quoteStyle(string raw)
{
    if (raw.length && (raw[0] == '"' || raw[0] == '\'' || raw[0] == '`'))
        return raw[0] == '`' ? '"' : raw[0];
    return 0;
}

struct Change
{
    enum Op { modified, added, removed }
    Op op;
    string key;
    size_t lineNo;
}

/// Set KEY to value on every occurrence, or append a new entry. Returns changes.
Change[] setValue(ref Document d, string key, string value, bool exportPrefix = false)
{
    assert(isValidKey(key));
    Change[] ch;
    foreach (idx; d.find(key))
    {
        auto l = &d.lines[idx];
        auto enc = encodeValue(value, quoteStyle(l.rawValue));
        if (enc == l.rawValue)
            continue;
        l.rawValue = enc;
        l.text = l.lead ~ l.key ~ l.sep ~ l.rawValue ~ l.tail;
        ch ~= Change(Change.Op.modified, key, l.lineNo);
    }
    if (d.find(key).length)
        return ch;
    Line n;
    n.kind = Kind.entry;
    n.lead = exportPrefix ? "export " : "";
    n.key = key;
    n.sep = "=";
    n.rawValue = encodeValue(value, 0);
    n.text = n.lead ~ n.key ~ n.sep ~ n.rawValue;
    if (d.lines.length && d.lines[$ - 1].eol == "")
    {
        d.lines[$ - 1].eol = d.defaultEol;
        n.eol = "";
    }
    else
        n.eol = d.defaultEol;
    size_t phys = 0;
    foreach (ref l; d.lines)
        phys += l.text.length ? 1 + l.text.count('\n') : 1;
    n.lineNo = phys + 1;
    d.lines ~= n;
    ch ~= Change(Change.Op.added, key, n.lineNo);
    return ch;
}

private size_t count(string s, char c)
{
    size_t n;
    foreach (x; s) if (x == c) n++;
    return n;
}

/// Remove every occurrence of KEY.
Change[] unsetKey(ref Document d, string key)
{
    Change[] ch;
    Line[] kept;
    foreach (ref l; d.lines)
    {
        if (l.kind == Kind.entry && l.key == key)
            ch ~= Change(Change.Op.removed, key, l.lineNo);
        else
            kept ~= l;
    }
    // removing the final line must not leave a dangling terminator change
    if (ch.length && kept.length && d.lines[$ - 1].eol == "" && kept[$ - 1].eol != "")
        if (d.lines[$ - 1].kind == Kind.entry && d.lines[$ - 1].key == key)
            kept[$ - 1].eol = "";
    d.lines = kept;
    return ch;
}

// ---------------------------------------------------------------- tests

unittest // byte-exact round trip
{
    string[] samples = [
        "",
        "A=1",
        "A=1\n",
        "# top comment\n\nA=1 # trailing\n  export B = \"two words\"\nC='single $x'\n\n",
        "A=1\r\nB=2\r\n# c\r\n",
        "MULTI=\"line1\nline2\"\nNEXT=x\n",
        "MIXED=1\r\nOTHER=2\n",
        "EMPTY=\nQ=\"\"\n",
        "not a valid line\nA=1\n",
    ];
    foreach (s; samples)
        assert(parse(s).serialize() == s, s);
}

unittest // parsing details
{
    auto d = parse("export API_KEY = \"a\\\"b\" # note\nU=plain value # c\nS='lit\\n'\n");
    assert(d.lines[0].kind == Kind.entry);
    assert(d.lines[0].key == "API_KEY");
    assert(d.lines[0].lead == "export ");
    assert(decodeValue(d.lines[0]) == "a\"b");
    assert(decodeValue(d.lines[1]) == "plain value");
    assert(d.lines[1].tail == " # c");
    assert(decodeValue(d.lines[2]) == `lit\n`);
    auto m = parse("M=\"x\ny\"\n");
    assert(m.lines.length == 1 && decodeValue(m.lines[0]) == "x\ny");
    auto bad = parse("=nokey\nNOEQ\nU=\"open\n");
    assert(bad.lines[0].kind == Kind.invalid);
    assert(bad.lines[1].kind == Kind.invalid);
    assert(bad.lines[2].kind == Kind.invalid);
}

unittest // BOM is dropped on write
{
    auto d = parse("\xEF\xBB\xBFA=1\n");
    assert(d.hadBom && d.serialize() == "A=1\n");
}

unittest // set preserves comments, order, quotes, export prefix and CRLF
{
    auto src = "# header\r\n\r\nexport A=\"old\" # keep me\r\nB='x'\r\nC=1\r\n";
    auto d = parse(src);
    auto ch = setValue(d, "A", "new value");
    assert(ch.length == 1 && ch[0].op == Change.Op.modified);
    setValue(d, "B", "y");
    setValue(d, "D", "added");
    assert(d.serialize() ==
        "# header\r\n\r\nexport A=\"new value\" # keep me\r\nB='y'\r\nC=1\r\nD=added\r\n");
}

unittest // no final newline is preserved when appending
{
    auto d = parse("A=1");
    setValue(d, "B", "2");
    assert(d.serialize() == "A=1\nB=2");
}

unittest // values needing quotes get double quotes and escapes
{
    auto d = parse("A=1\n");
    setValue(d, "A", "has \"quote\"\nand newline");
    assert(d.serialize() == "A=\"has \\\"quote\\\"\\nand newline\"\n");
    auto again = parse(d.serialize());
    assert(decodeValue(again.lines[0]) == "has \"quote\"\nand newline");
}

unittest // unset removes all occurrences and keeps the rest
{
    auto d = parse("# c\nA=1\nB=2\nA=3\n");
    auto ch = unsetKey(d, "A");
    assert(ch.length == 2);
    assert(d.serialize() == "# c\nB=2\n");
    auto e = parse("A=1\nB=2");
    unsetKey(e, "B");
    assert(e.serialize() == "A=1");
}
