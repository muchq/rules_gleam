-module(runtime_assets).
-export([check/0]).

check() ->
    {ok, <<"bundled asset\n">>} = file:read_file(
        filename:join(code:priv_dir(runtime_assets), "message.txt")),
    Root = os:getenv("GLEAM_RUNFILES_DIR"),
    {ok, [{message, "bundled config"}]} = file:consult(filename:join(
        Root, "test/integration/release_runtime/assets/settings.config")),
    ok.
