-module(release_fixture).
-behaviour(application).
-export([main/0, start/2, stop/1]).

main() ->
    case init:get_plain_arguments() of
        [] -> io:format("no arguments~n");
        ["check", "two words", "", "quote'\"", "*", "--flag", "+S", "line\nbreak"] ->
            ok = runtime_assets:check(),
            ExpectedCwd = os:getenv("EXPECTED_CWD"),
            {ok, ExpectedCwd} = file:get_cwd(),
            2 = erlang:system_info(schedulers_online),
            {ok, _} = application:ensure_all_started(ssl),
            io:format("arguments, VM flags, config and assets OK~n");
        ["fail"] ->
            io:format(standard_error, "deliberate startup failure~n", []),
            erlang:halt(23);
        ["serve"] ->
            ok = runtime_assets:check(),
            ok = application:load({application, fixture_server, [
                {vsn, "1.0.0"}, {modules, [?MODULE]},
                {applications, [kernel, stdlib]}, {mod, {?MODULE, []}}
            ]}),
            ok = application:start(fixture_server),
            io:format("ready~n"),
            receive never -> ok end
    end.

start(_Type, _Args) ->
    Pid = spawn_link(fun() ->
        process_flag(trap_exit, true),
        receive {'EXIT', _, shutdown} -> ok end
    end),
    {ok, Pid}.

stop(_State) ->
    io:format("graceful shutdown~n"),
    ok.
