-module(runtime_data).
-export([read/0]).

read() ->
    file:read_file(filename:join([
        os:getenv("TEST_SRCDIR"), os:getenv("TEST_WORKSPACE"),
        "runtime_data/settings.txt"
    ])).
