-- `fossci init`: creates the local store (.fossci/ with the ledger
-- database) in the current directory. Standalone for v0 -- the
-- Fossil-backed sync for schemas/ and extensions/ (doc/architecture.md,
-- "Fossil integration") lands in M1; until then, this just needs
-- somewhere on disk to keep the ledger.

paths = require("paths")
config = require("config")
ledger = require("ledger")
extension = require("extension")
auth = require("auth")

init = {}

function init.do_init(cmd_args, root)
    if root == nil then
        root = "."
    end
    if config.is_initialized(root) then
        print("Already initialized: " .. config.db_path(root))
        return
    end

    paths.create_dir_if_not_exists(config.store_dir(root))
    paths.create_dir_if_not_exists(config.schemas_dir(root))
    paths.create_dir_if_not_exists(config.extensions_dir(root))
    paths.create_dir_if_not_exists(config.views_dir(root))
    paths.create_dir_if_not_exists(config.templates_dir(root))

    db_path = config.db_path(root)
    ledger.init_schema(db_path)
    extension.init_schema(db_path)
    auth.init_schema(db_path)

    ok, err = auth.ensure_session_secret(root)
    if ok == nil then
        print("Warning: could not create session secret: " .. tostring(err))
    end

    print("Initialized store at " .. config.store_dir(root))
end

return init
