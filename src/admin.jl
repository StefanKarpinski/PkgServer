import Logging, LoggingExtras, URIs

# The `/admin` endpoint is enabled by `htpasswd` and requires a password file and the
# `htpasswd` binary. Without any of these `/admin` is disabled. The path to the password
# file is passed to `PkgServer.start` using the keyword argument `password_file`. The
# password file and users should be created with `htpasswd`. As an example, the following
# creates an `admin` user with password `hunter2`:
#
#     htpasswd -c -b -B .htpasswd admin hunter2
#
# ************************************************************************************
# *                                IMPORTANT                                         *
# * The /admin endpoint must only be configured if the server is secured with HTTPS. *
# * PkgServer itself only uses HTTP, so this has to be configured externally with    *
# * e.g. a TLS terminating reverse proxy.                                            *
# *                                IMPORTANT                                         *
# ************************************************************************************

function simple_http_response(http::HTTP.Stream, s::Int, msg::Union{String,Nothing}=nothing)
    HTTP.setstatus(http, s)
    if msg === nothing
        HTTP.setheader(http, "Content-Length" => "0")
        HTTP.startwrite(http)
    else
        HTTP.setheader(http, "Content-Type" => "text/plain")
        HTTP.setheader(http, "Content-Length" => string(sizeof(msg)))
        HTTP.startwrite(http)
        write(http, msg)
    end
    return nothing
end

function invalid_auth(http)
    msg = "Invalid Authorization header, invalid user, or invalid password.\n"
    HTTP.setheader(http, "WWW-Authenticate" => "Basic")
    return simple_http_response(http, 401, msg)
end

# Matches the base64 encoded data in "Basic <base64 data>"
const basic_auth_regex = r"(?<=^Basic )(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{4})$"
const userinfo_regex = r"^(?<username>.+?):(?<password>.+)$"


const admin_lock = ReentrantLock()

function handle_admin(http::HTTP.Stream)
    # If no /admin is disabled tell the user
    if config.password_file === nothing
        msg = "The /admin endpoint is disabled for this server " *
              "(either no password file given or no `htpasswd` binary found)."
        return simple_http_response(http, 404, msg)
    end
    # Check the Authorization header and extract username and password
    auth = HTTP.header(http, "Authorization", "")
    m = match(basic_auth_regex, auth)
    m === nothing && return invalid_auth(http)
    userinfo = String(Base64.base64decode(m.match::AbstractString))
    m = match(userinfo_regex, userinfo)
    m === nothing && return invalid_auth(http)
    # We have a username and password, ask htpasswd if they are valid
    htpasswd_stderr, htpasswd_stdin = Pipe(), Pipe()
    cmd = pipeline(
        `htpasswd -iv $(config.password_file::String) $(m["username"]::AbstractString)`;
        stdin=htpasswd_stdin, stderr=htpasswd_stderr,
    )
    proc = run(cmd; wait=false)
    stderr_read_task= @async readchomp(htpasswd_stderr)
    write(htpasswd_stdin, m["password"]::AbstractString)
    close(htpasswd_stdin)
    if !success(proc)
        close(htpasswd_stderr)
        msg = fetch(stderr_read_task)
        @warn "/admin: failed login attempt: $(msg)"
        return invalid_auth(http)
    end
    # All good, open sesame!
    return @lock admin_lock handle_admin_authenticated(http)
end

admin_debug_level::Logging.LogLevel= Logging.Info
original_logger::Union{Logging.AbstractLogger, Nothing} = nothing

# If we end up here then the request is authenticated
function handle_admin_authenticated(http::HTTP.Stream)
    method = http.message.method
    uri = URIs.URI(http.message.target)
    if uri.path == "/admin" && method == "GET"
        admin_help = """
        Welcome to the /admin endpoint of the package server.
        The following admin tasks are currently implemented:

        # `GET /admin`

        Fetch this message.

        # `GET /admin/logging`

        Return the current logging state.

        # `POST /admin/logging`

        Change the logging state (enabling/disabling debug logging).
        **Body parameters**
         - `level` (required): `debug` or `info`.
        """
        return simple_http_response(http, 200, admin_help)
    elseif uri.path == "/admin/logging" && method == "GET"
        levelstr = admin_debug_level == Logging.Debug ? "debug" : "info"
        data = Dict("level" => levelstr)
        return serve_json(http, data)
    elseif uri.path == "/admin/logging" && method == "POST"
        body = JSON3.read(http)
        if get(body, "level", nothing) == "debug"
            if admin_debug_level == Logging.Info
                @debug "/admin: changing log state from info to debug"
                # Augment the original logger with a logger that passes through
                # debug-level messages
                debug_logger = LoggingExtras.TeeLogger(
                    LoggingExtras.EarlyFilteredLogger(
                        function(log)
                            return log._module == @__MODULE__() &&
                                   Logging.Debug <= log.level < Logging.Info
                        end,
                        Logging.SimpleLogger(stderr, Logging.BelowMinLevel),
                    ),
                    Logging.global_logger(),
                )
                global original_logger = Logging.global_logger(debug_logger)
                global admin_debug_level = Logging.Debug
            else
                # Debugging already enabled, do nothing
                @debug "/admin: log state already debug"
                @assert admin_debug_level == Logging.Debug
            end
            return simple_http_response(http, 200)
        elseif get(body, "level", nothing) == "info"
            # Disable the extra debug logger by resetting the original logger
            if original_logger !== nothing
                @debug "/admin: changing log state from debug to info"
                Logging.global_logger(original_logger)
                global original_logger = nothing
                global admin_debug_level = Logging.Info
            else
                # Debugging already disabled, do nothing
                @debug "/admin: log state already info"
                @assert admin_debug_level == Logging.Info
            end
            return simple_http_response(http, 200)
        else
            # TODO: Better error handling overall
            return simple_http_response(http, 400)
        end
    else
        msg = "Unknown /admin endpoint.\n"
        simple_http_response(http, 404, msg)
    end
    return
end