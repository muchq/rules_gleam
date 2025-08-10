{application, standalone_app, [
    {vsn, "1.0.0"},
    {applications, [gleam_stdlib,
                    gleeunit]},
    {description, "A standalone Gleam application using Bazel"},
    {modules, [app,
               standalone_app@@main]},
    {registered, []}
]}.
