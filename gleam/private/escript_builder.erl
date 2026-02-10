-module(escript_builder).
-export([main/1]).

main([OutFile, PackageName, EntryModule, EntryFunction | Files]) ->
    % Read files
    ArchiveFiles = lists:flatmap(fun(Path) ->
        process_path(Path)
    end, Files),

    % EmuArgs
    % We need to pass the environment variables
    EmuArgs = lists:flatten(io_lib:format(
        "-escript main gleescript_main_shim "
        "-env GLEAM_PACKAGE_NAME ~s "
        "-env GLEAM_ENTRY_MODULE ~s "
        "-env GLEAM_ENTRY_FUNCTION ~s",
        [PackageName, EntryModule, EntryFunction]
    )),

    % Create escript
    ok = escript:create(OutFile, [
        shebang,
        {comment, ""},
        {emu_args, EmuArgs},
        {archive, ArchiveFiles, []}
    ]),

    % Make executable
    ok = file:change_mode(OutFile, 8#00777),
    ok.

process_path(Path) ->
    case filelib:is_dir(Path) of
        true ->
            {ok, Files} = file:list_dir(Path),
            lists:flatmap(fun(File) ->
                Full = filename:join(Path, File),
                process_path(Full)
            end, Files);
        false ->
            BaseName = filename:basename(Path),
            IsBeamOrApp = filename:extension(Path) == ".beam" orelse filename:extension(Path) == ".app",
            % Check if file contains "@@"
            NotInternal = string:str(BaseName, "@@") == 0,
            if
                IsBeamOrApp andalso NotInternal ->
                    [{BaseName, read_file(Path)}];
                true ->
                    []
            end
    end.

read_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Bin.
