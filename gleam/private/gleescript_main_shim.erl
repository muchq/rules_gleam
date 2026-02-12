-module(gleescript_main_shim).
-export([main/1]).

main(_) ->
    io:setopts(standard_io, [binary, {encoding, utf8}]),
    io:setopts(standard_error, [{encoding, utf8}]),

    PackageNameStr = os:getenv("GLEAM_PACKAGE_NAME"),
    PackageName = list_to_atom(PackageNameStr),

    EntryModuleStr = os:getenv("GLEAM_ENTRY_MODULE"),
    EntryModule = list_to_atom(EntryModuleStr),

    EntryFunctionStr = os:getenv("GLEAM_ENTRY_FUNCTION"),
    EntryFunction = list_to_atom(EntryFunctionStr),

    % Try to start the application corresponding to the package name.
    case application:ensure_all_started(PackageName) of
        {ok, _} -> ok;
        {error, {not_found, _}} -> ok;
        Error -> io:format(standard_error, "Error starting application ~p: ~p~n", [PackageName, Error])
    end,

    EntryModule:EntryFunction().
