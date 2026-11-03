module envsafe.version_;

/// Product version; CI checks that the release tag matches.
enum productVersion = "0.1.0";

/// Build id stamped by CI into views/build-id.txt ("dev" for local builds).
enum buildId = () {
    import std.string : strip;
    return import("build-id.txt").strip;
}();

enum versionString = productVersion ~ " (build " ~ buildId ~ ")";
