/// File reading and atomic writing.
module envsafe.fileio;

import std.file : exists, read, rename, remove, copy, getAttributes, setAttributes, isFile;
import std.path : dirName, baseName, buildPath, absolutePath;
import std.process : thisProcessID;
import std.random : uniform;
import std.conv : to;
import std.utf : validate, UTFException;
import std.stdio : File;

enum ReadResult { ok, missing, notUtf8, error }

ReadResult readEnvFile(string path, out string content)
{
    try
    {
        if (!exists(path))
            return ReadResult.missing;
        auto bytes = cast(string) read(path);
        try validate(bytes);
        catch (UTFException) return ReadResult.notUtf8;
        content = bytes;
        return ReadResult.ok;
    }
    catch (Exception)
        return ReadResult.error;
}

/// Write via a temp file in the same directory, then rename over the target.
bool atomicWrite(string path, string data, bool backup, out string why)
{
    auto abs = absolutePath(path);
    auto tmp = buildPath(dirName(abs), "." ~ baseName(abs) ~ ".envsafe-"
        ~ thisProcessID.to!string ~ "-" ~ uniform!uint.to!string ~ ".tmp");
    try
    {
        {
            auto f = File(tmp, "wb");
            f.rawWrite(data);
            f.flush();
            version (Posix)
            {
                import core.sys.posix.unistd : fsync;
                fsync(f.fileno);
            }
            f.close();
        }
        version (Posix)
        {
            if (exists(abs)) setAttributes(tmp, getAttributes(abs));
            else setAttributes(tmp, octal600);
        }
        if (backup && exists(abs))
            copy(abs, abs ~ ".bak");
        rename(tmp, abs);
        return true;
    }
    catch (Exception e)
    {
        why = e.msg;
        try { if (exists(tmp)) remove(tmp); } catch (Exception) {}
        return false;
    }
}

private enum octal600 = 0x180; // 0600
