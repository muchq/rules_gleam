-module(runtime_data).
-export([read/0]).

read() ->
    file:read_file(filename:join([
        os:getenv("GLEAM_RUNFILES_DIR"), "runtime_data/settings.txt"
    ])).
