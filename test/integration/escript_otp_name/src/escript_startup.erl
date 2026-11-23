-module(escript_startup).
-behaviour(application).
-export([main/0, start/2, stop/1]).

start(_, _) ->
    ok = application:set_env(escript_app, started, true),
    {ok, spawn(fun() -> receive stop -> ok end end)}.

stop(_) -> ok.

main() ->
    {ok, true} = application:get_env(escript_app, started),
    io:format("application started~n").
