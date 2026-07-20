-- `platform init`: creates the local store (.store/, holding the
-- database) plus the schemas/extensions/views/templates directories in
-- the current directory.

paths = require("paths")
config = require("config")
ledger = require("ledger")
extension = require("extension")
auth = require("auth")
document = require("document")
knowledge = require("knowledge")
agent = require("agent")

init = {}

-- config.db_path returns either a SQLite file path (a string) or a
-- MariaDB connection descriptor (a table) -- this is the one place
-- that needs a human-readable label for either shape, since ".." can't
-- concatenate a table the way it can a path string.
function describe_db_target(target)
    if type(target) == "table" then
        return target.host .. ":" .. tostring(target.port) .. "/" .. tostring(target.database)
    end
    return target
end

function init.do_init(cmd_args, root)
    if root == nil then
        root = "."
    end
    if config.is_initialized(root) then
        print("Already initialized: " .. describe_db_target(config.db_path(root)))
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
    document.init_schema(db_path)
    knowledge.init_schema(db_path)
    agent.init_schema(db_path)

    ok, err = auth.ensure_session_secret(root)
    if ok == nil then
        print("Warning: could not create session secret: " .. tostring(err))
    end

    print("Initialized store at " .. config.store_dir(root))
end

return init
