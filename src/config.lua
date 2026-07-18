-- Resolves the store location: a `.store/` directory (renamed once the
-- project itself has a name) holding the ledger database, alongside
-- `schemas/`/`extensions/`/`views/`/`templates/` directories.
--
-- Root resolution no longer walks up looking for a Fossil checkout
-- marker (`.fslckout`/`_FOSSIL_`) -- there is no Fossil checkout to
-- find. `DOCUMENT_ROOT` is a standard CGI env var most web servers set
-- natively (not Fossil-specific, even though Fossil's own /ext relay
-- also happened to set it), so it's kept as the CGI-mode signal; CLI
-- mode still just uses the current directory. No more "which of two
-- possibly-different root markers wins" -- there's exactly one root
-- now, matching the single-SQLite-file storage consolidation this
-- migration is also doing.

paths = require("paths")

config = {}

STORE_DIR = ".store"
DB_FILE = "store.db"
SESSION_SECRET_FILE = "session_secret"

function config.find_root()
    root = os.getenv("DOCUMENT_ROOT")
    if root != nil and root != "" then
        return string.gsub(root, "\\", "/")
    end
    return "."
end

function config.store_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, STORE_DIR)
end

function config.db_path(root)
    return paths.joinpath(config.store_dir(root), DB_FILE)
end

function config.schemas_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "schemas")
end

function config.extensions_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "extensions")
end

function config.views_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "views")
end

function config.templates_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "templates")
end

function config.session_secret_path(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(config.store_dir(root), SESSION_SECRET_FILE)
end

function config.is_initialized(root)
    return paths.file_exists(config.db_path(root))
end

return config
