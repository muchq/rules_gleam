-module(escript_builder).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

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
            % file:list_dir/1 does not guarantee any particular order (it reflects whatever
            % order the underlying filesystem happens to return directory entries in, which can
            % differ between a from-scratch build and a rebuild of the same sources) -- sort so
            % the resulting escript's zip archive has a deterministic entry order.
            {ok, Files} = file:list_dir(Path),
            lists:flatmap(fun(File) ->
                Full = filename:join(Path, File),
                process_path(Full)
            end, lists:sort(Files));
        false ->
            BaseName = filename:basename(Path),
            IsBeamOrApp = filename:extension(Path) == ".beam" orelse filename:extension(Path) == ".app",
            % Check if file contains "@@"
            NotInternal = string:str(BaseName, "@@") == 0,
            if
                IsBeamOrApp andalso NotInternal ->
                    Bin = read_file(Path),
                    [{BaseName, Bin, archive_file_info(Bin)}];
                true ->
                    []
            end
    end.

read_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Bin.

% escript:create/2's {archive, Files, _} accepts {Name, Bin} or {Name, Bin, FileInfo}; without
% an explicit FileInfo, the zip archive it builds stamps each entry with the current wall-clock
% time (when this escript_builder run happens to execute), not anything about the input files --
% two otherwise-identical builds run even a couple of seconds apart get a byte-different escript
% as a result. Pin every field to a fixed value instead.
archive_file_info(Bin) ->
    FixedTime = {{1980, 1, 1}, {0, 0, 0}},
    #file_info{
        size = byte_size(Bin),
        type = regular,
        access = read_write,
        atime = FixedTime,
        mtime = FixedTime,
        ctime = FixedTime,
        mode = 8#100644,
        links = 1,
        major_device = 0,
        minor_device = 0,
        inode = 0,
        uid = 0,
        gid = 0
    }.
