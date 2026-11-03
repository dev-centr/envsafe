module app;

import envsafe.cli;
import std.stdio : stdin, stdout, stderr;
import std.process : environment;

int main(string[] args)
{
    Io io;
    io.readStdin = () {
        import std.array : appender;
        auto a = appender!string;
        foreach (ubyte[] chunk; stdin.byChunk(4096))
            a.put(cast(const(char)[]) chunk);
        return a.data;
    };
    io.out_ = (string s) { stdout.write(s); stdout.flush(); };
    io.err = (string s) { stderr.write(s); stderr.flush(); };
    io.getEnv = (string k) => environment.get(k, null);
    return run(args[1 .. $], io);
}
