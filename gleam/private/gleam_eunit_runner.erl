%% Runs a Gleam package's tests via EUnit, the same way gleeunit:main/0 does
%% (reusing gleeunit_ffi:find_files/2 for test-module discovery so behavior
%% stays identical to `gleam test`), but adds two things gleeunit's own
%% zero-argument API doesn't expose:
%%
%%   - a JUnit/XML report (via the eunit_surefire report handler that ships
%%     with OTP's eunit application) written to the directory named by the
%%     GLEAM_EUNIT_XML_DIR environment variable, if set
%%   - filtering by the TESTBRIDGE_TEST_ONLY environment variable that
%%     `bazel test --test_filter=` sets, at module (i.e. test-file)
%%     granularity
-module(gleam_eunit_runner).

-export([main/0, main/1]).

main() ->
    main([]).

main(_Args) ->
    TestFiles = gleeunit_ffi:find_files(<<"**/*.{erl,gleam}">>, <<"test">>),
    AllModules = lists:map(fun to_module_atom/1, TestFiles),
    Modules = filter_modules(AllModules),
    Result = eunit:test(Modules, build_options()),
    Code = case Result of
        ok -> 0;
        _ -> 1
    end,
    erlang:halt(Code).

%% Mirrors gleam_to_erlang_module_name/1 in gleeunit's own gleeunit.gleam:
%% ".gleam" files keep their full path (with "/" replaced by "@"); ".erl"
%% files are referenced by bare module name (Erlang modules aren't
%% namespaced by directory).
to_module_atom(PathBin) ->
    Path = binary_to_list(PathBin),
    case strip_suffix(Path, ".gleam") of
        {ok, NoExt} ->
            list_to_atom(slashes_to_at(NoExt));
        error ->
            Base = filename:basename(Path),
            case strip_suffix(Base, ".erl") of
                {ok, NoExt} -> list_to_atom(NoExt);
                error -> list_to_atom(Base)
            end
    end.

strip_suffix(Str, Suffix) ->
    case lists:suffix(Suffix, Str) of
        true -> {ok, lists:sublist(Str, length(Str) - length(Suffix))};
        false -> error
    end.

slashes_to_at(Str) ->
    lists:map(fun($/) -> $@; (C) -> C end, Str).

filter_modules(Modules) ->
    case os:getenv("TESTBRIDGE_TEST_ONLY") of
        false -> Modules;
        "" -> Modules;
        Filter -> lists:filter(fun(Mod) -> contains(atom_to_list(Mod), Filter) end, Modules)
    end.

contains(Str, Sub) ->
    string:str(Str, Sub) =/= 0.

%% eunit_tty always runs (it sends the completion signal eunit:test/2 waits
%% on), so it's silenced with no_tty and gleeunit_progress is added as the
%% visible reporter, matching gleeunit:main/0's own terminal output exactly.
%% eunit:test/2 supports any number of {report, Spec} options simultaneously
%% (see eunit:listeners/1), so adding eunit_surefire alongside
%% gleeunit_progress runs both in the same test pass -- no need to run the
%% suite twice to get both human-readable output and a machine-readable one.
build_options() ->
    Base = [
        verbose,
        no_tty,
        {report, {gleeunit_progress, [{colored, true}]}},
        {scale_timeouts, 10}
    ],
    case os:getenv("GLEAM_EUNIT_XML_DIR") of
        false -> Base;
        "" -> Base;
        Dir -> Base ++ [{report, {eunit_surefire, [{dir, Dir}]}}]
    end.
