#!/usr/bin/env julia
using PkgServer, Sockets, Logging, LoggingExtras, Dates, FilesystemDatastructures, Gzip_jll

# Accept optional environment-based arguments
# Eventually, do this via Pkg preferences
const pkgserver = get(ENV, "JULIA_PKG_SERVER", "http://0.0.0.0:8000")
try
    m = match(r"(https?://)?(.+):(\d+)", pkgserver)
    global host = m.captures[2]
    global port = parse(Int, m.captures[3])
catch
    @warn("Invalid JULIA_PKG_SERVER setting, ignoring and using default of 0.0.0.0:8000!")
    global host = "0.0.0.0"
    global port = 8000
end

const storage_root = get(ENV, "JULIA_PKG_SERVER_STORAGE_ROOT", "/tmp/pkgserver")
const storage_servers = strip.(split(get(ENV, "JULIA_PKG_SERVER_STORAGE_SERVERS", "https://us-east.storage.juliahub.com,https://kr.storage.juliahub.com"), ","))
const log_dir = get(ENV, "JULIA_PKG_SERVER_LOGS_DIR", joinpath(storage_root, "logs"))
const flavorless = get(ENV, "JULIA_PKG_SERVER_FLAVORLESS", "false")
const registry_update_period = parse(Float64, get(ENV, "JULIA_PKG_SERVER_REGISTRY_UPDATE_PERIOD", "1"))

dotflavors = [
    ".eager",
    ".conservative",
]
if lowercase(flavorless) == "true"
    dotflavors = [""]
end

mkpath(storage_root)
mkpath(log_dir)

# Set up logging
const date_format = dateformat"yyyy-mm-dd HH:MM:SS"
timestamp_logger(logger) = TransformerLogger(logger) do log
    merge(log, (; message = "[$(Dates.format(now(), date_format))] $(log.message)"))
end

const compress_logs = get(ENV, "JULIA_PKG_SERVER_COMPRESS_LOGS", "true") in ("True", "TRUE", "true")

# Keep 10 days of logs
let fc = NFileCache(log_dir, 10*24, DiscardLRU(); predicate = x -> endswith(x, r"pkgserver\.log(\.gz)?"))
    global function postrotate(file)
        # Compress logfile and add to filecache
        gzip() do gz
            run(`$(gz) $(file)`)
        end
        add!(fc, file * ".gz")
    end
end

global_logger(TeeLogger(
    timestamp_logger(
        MinLevelLogger(
            DatetimeRotatingFileLogger(
                log_dir,
                string(raw"yyyy-mm-dd-HH-\p\k\g\s\e\r\v\e\r.\l\o\g");
                rotation_callback = compress_logs ? postrotate : identity,
            ),
            Logging.Info,
        ),
    ),
    current_logger(),
))

PkgServer.start(;
    listen_addr=Sockets.InetAddr(host, port),
    storage_root,
    storage_servers,
    dotflavors,
    registry_update_period,
)
