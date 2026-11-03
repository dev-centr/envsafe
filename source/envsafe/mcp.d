/**
 * `envsafe mcp`: a Model Context Protocol server over stdio (newline-delimited
 * JSON-RPC 2.0). Each tool call is translated into the same code path as the
 * CLI, so the redaction guarantees are shared. `set` never takes a value in its
 * arguments: it reads it from an environment variable or a file.
 */
module envsafe.mcp;

import envsafe.cli;
import envsafe.fileio;
import envsafe.version_;
import std.json;
import std.string : strip, endsWith;

private immutable toolsJson = `[
 {"name":"envsafe_set","description":"Upsert KEY in a .env file (update in place, or add it). The value is never passed as an argument: it is read from an environment variable of the server (from_env) or from a file (from_file). Output never contains the value. Use dry_run for a redacted diff.",
  "inputSchema":{"type":"object","properties":{
   "key":{"type":"string"},
   "from_env":{"type":"string","description":"Name of an environment variable holding the value"},
   "from_file":{"type":"string","description":"Path of a file whose contents are the value (one trailing newline dropped)"},
   "file":{"type":"string","description":"Path of the .env file (default .env)"},
   "export":{"type":"boolean"},"dry_run":{"type":"boolean"},"backup":{"type":"boolean"},
   "only_existing":{"type":"boolean","description":"Fail if the key is missing"},
   "only_new":{"type":"boolean","description":"Fail if the key exists; never overwrite"},
   "comment":{"type":"string","description":"Add or replace the comment block above the key (must not contain the value)"},
   "after":{"type":"string","description":"Place a new key after this key"},
   "section":{"type":"string","description":"Place a new key at the end of the section headed by this comment line"}},
   "required":["key"]}},
 {"name":"envsafe_unset","description":"Remove keys from a .env file. Use dry_run for a redacted diff.",
  "inputSchema":{"type":"object","properties":{
   "keys":{"type":"array","items":{"type":"string"}},
   "with_comment":{"type":"boolean","description":"Also remove the comment block attached above each key"},
   "file":{"type":"string"},"dry_run":{"type":"boolean"},"backup":{"type":"boolean"}},
   "required":["keys"]}},
 {"name":"envsafe_list","description":"List key names in a .env file (never values). show_masked marks which keys have a value.",
  "inputSchema":{"type":"object","properties":{"file":{"type":"string"},"show_masked":{"type":"boolean"}}}},
 {"name":"envsafe_validate","description":"Validate a .env file: syntax, duplicate keys, and optionally a schema/registry (.adoc/.md table or .env.example).",
  "inputSchema":{"type":"object","properties":{"file":{"type":"string"},"schema":{"type":"string"},"strict":{"type":"boolean"}}}}
]`;

private JSONValue rpcResult(JSONValue id, JSONValue result)
{
    JSONValue r = ["jsonrpc": JSONValue("2.0")];
    r["id"] = id;
    r["result"] = result;
    return r;
}

private JSONValue rpcError(JSONValue id, int code, string msg)
{
    JSONValue r = ["jsonrpc": JSONValue("2.0")];
    r["id"] = id;
    JSONValue e = ["message": JSONValue(msg)];
    e["code"] = code;
    r["error"] = e;
    return r;
}

private string str(JSONValue a, string k)
{
    if (a.type == JSONType.object)
        if (auto p = k in a.object)
            if (p.type == JSONType.string)
                return p.str;
    return null;
}

private bool flag(JSONValue a, string k)
{
    if (a.type == JSONType.object)
        if (auto p = k in a.object)
            return p.type == JSONType.true_;
    return false;
}

private JSONValue toolText(string text, bool isError)
{
    JSONValue item = ["type": JSONValue("text"), "text": JSONValue(text)];
    JSONValue r = ["content": JSONValue([item])];
    r["isError"] = isError;
    return r;
}

private JSONValue callTool(string name, JSONValue a, string delegate(string) getEnv)
{
    string[] args;
    string stdinData;
    void common()
    {
        if (auto f = str(a, "file")) args ~= ["-f", f];
        if (flag(a, "dry_run")) args ~= "--dry-run";
        if (flag(a, "backup")) args ~= "--backup";
    }
    switch (name)
    {
        case "envsafe_set":
            auto key = str(a, "key");
            if (key is null) return toolText("error: key is required", true);
            args = ["set", key];
            auto fe = str(a, "from_env"), ff = str(a, "from_file");
            if ((fe !is null) == (ff !is null))
                return toolText("error: give exactly one of from_env or from_file (values are never accepted inline)", true);
            if (fe !is null) args ~= ["--from-env", fe];
            else
            {
                if (readEnvFile(ff, stdinData) != ReadResult.ok)
                    return toolText("error: cannot read from_file: " ~ ff, true);
                args ~= "--stdin";
            }
            if (flag(a, "export")) args ~= "--export";
            if (flag(a, "only_existing")) args ~= "--only-existing";
            if (flag(a, "only_new")) args ~= "--only-new";
            if (auto cm = str(a, "comment")) args ~= ["--comment", cm];
            if (auto af = str(a, "after")) args ~= ["--after", af];
            if (auto se = str(a, "section")) args ~= ["--section", se];
            common();
            break;
        case "envsafe_unset":
            args = ["unset"];
            if (a.type == JSONType.object && "keys" in a.object && a["keys"].type == JSONType.array)
                foreach (k; a["keys"].array)
                    if (k.type == JSONType.string) args ~= k.str;
            if (args.length == 1) return toolText("error: keys is required", true);
            if (flag(a, "with_comment")) args ~= "--with-comment";
            common();
            break;
        case "envsafe_list":
            args = ["list"];
            if (auto f = str(a, "file")) args ~= ["-f", f];
            if (flag(a, "show_masked")) args ~= "--show-masked";
            break;
        case "envsafe_validate":
            args = ["validate"];
            if (auto f = str(a, "file")) args ~= ["-f", f];
            if (auto s = str(a, "schema")) args ~= ["--schema", s];
            if (flag(a, "strict")) args ~= "--strict";
            break;
        default:
            return JSONValue(null);
    }
    string outText, errText;
    Io io;
    io.readStdin = () => stdinData;
    io.out_ = (string s) { outText ~= s; };
    io.err = (string s) { errText ~= s; };
    io.getEnv = getEnv;
    auto code = run(args, io);
    return toolText((outText ~ errText).strip, code != 0);
}

/// Handle one JSON-RPC message; returns the response line, or null for notifications.
string handleMessage(string line, string delegate(string) getEnv)
{
    JSONValue msg;
    try msg = parseJSON(line);
    catch (Exception)
        return rpcError(JSONValue(null), -32700, "parse error").toString;
    if (msg.type != JSONType.object || "method" !in msg.object)
        return null;
    auto isRequest = ("id" in msg.object) !is null;
    auto id = isRequest ? msg["id"] : JSONValue(null);
    auto method = msg["method"].type == JSONType.string ? msg["method"].str : "";
    auto params = ("params" in msg.object) ? msg["params"] : JSONValue((JSONValue[string]).init);
    if (!isRequest)
        return null; // notifications (initialized, cancelled) need no reply
    switch (method)
    {
        case "initialize":
            auto pv = str(params, "protocolVersion");
            JSONValue r = ["protocolVersion": JSONValue(pv.length ? pv : "2025-06-18")];
            r["capabilities"] = parseJSON(`{"tools":{"listChanged":false}}`);
            r["serverInfo"] = parseJSON(`{"name":"envsafe"}`);
            r["serverInfo"]["version"] = productVersion;
            r["instructions"] = "Edit .env files without exposing values. envsafe_set reads values from an environment variable or file, never from arguments. Output never contains values.";
            return rpcResult(id, r).toString;
        case "ping":
            return rpcResult(id, parseJSON("{}")).toString;
        case "tools/list":
            JSONValue r = ["tools": parseJSON(toolsJson)];
            return rpcResult(id, r).toString;
        case "tools/call":
            auto name = str(params, "name");
            auto args = (params.type == JSONType.object && "arguments" in params.object)
                ? params["arguments"] : parseJSON("{}");
            auto res = callTool(name, args, getEnv);
            if (res.type == JSONType.null_)
                return rpcError(id, -32602, "unknown tool").toString;
            return rpcResult(id, res).toString;
        default:
            return rpcError(id, -32601, "method not found").toString;
    }
}

/// Serve MCP over stdio until EOF.
int serve(string delegate(string) getEnv)
{
    import std.stdio : stdin, stdout;
    foreach (line; stdin.byLineCopy)
    {
        auto l = line.strip;
        if (!l.length) continue;
        auto resp = handleMessage(l, getEnv);
        if (resp !is null)
        {
            stdout.write(resp, "\n");
            stdout.flush();
        }
    }
    return 0;
}

unittest
{
    import std.file : tempDir, write, readText, remove, exists;
    import std.path : buildPath;
    import std.algorithm : canFind;
    enum secret = "MCP-secret-sentinel-91be";
    string delegate(string) env = (string k) => k == "SRC" ? secret : null;
    auto f = buildPath(tempDir, "envsafe-mcp-test.env");
    auto vf = buildPath(tempDir, "envsafe-mcp-test.value");
    write(f, "# c\nA=1\n");
    write(vf, secret ~ "\n");
    scope (exit) { remove(f); remove(vf); if (exists(f ~ ".bak")) remove(f ~ ".bak"); }
    string all;
    string call(string tool, string argsJson)
    {
        auto r = handleMessage(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"` ~ tool
            ~ `","arguments":` ~ argsJson ~ `}}`, env);
        all ~= r;
        return r;
    }
    auto fj = JSONValue(f).toString;
    assert(handleMessage(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`, env)
        .canFind(`"protocolVersion":"2025-06-18"`));
    assert(handleMessage(`{"jsonrpc":"2.0","method":"notifications/initialized"}`, env) is null);
    assert(handleMessage(`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`, env).canFind("envsafe_set"));
    assert(call("envsafe_set", `{"key":"K","from_env":"SRC","dry_run":true,"file":` ~ fj ~ `}`).canFind("<redacted>"));
    call("envsafe_set", `{"key":"K","from_env":"SRC","file":` ~ fj ~ `}`);
    call("envsafe_set", `{"key":"F","from_file":` ~ JSONValue(vf).toString ~ `,"file":` ~ fj ~ `}`);
    assert(call("envsafe_set", `{"key":"K","from_env":"SRC","only_new":true,"file":` ~ fj ~ `}`).canFind(`"isError":true`));
    assert(call("envsafe_set", `{"key":"Z","from_env":"SRC","only_existing":true,"file":` ~ fj ~ `}`).canFind(`"isError":true`));
    assert(call("envsafe_set", `{"key":"A","from_env":"SRC","dry_run":true,"file":` ~ fj ~ `}`).canFind("would update A"));
    assert(call("envsafe_set", `{"key":"X","value":"inline","file":` ~ fj ~ `}`).canFind(`"isError":true`));
    assert(call("envsafe_list", `{"show_masked":true,"file":` ~ fj ~ `}`).canFind("K=********"));
    call("envsafe_validate", `{"file":` ~ fj ~ `}`);
    call("envsafe_unset", `{"keys":["A"],"dry_run":true,"file":` ~ fj ~ `}`);
    assert(!all.canFind(secret), "secret leaked into MCP output");
    assert(readText(f) == "# c\nA=1\nK=" ~ secret ~ "\nF=" ~ secret ~ "\n");
}
