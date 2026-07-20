if package.preload["config"] == nil then
    package.path = "src/?.lua;" .. package.path
end

config = require("config")

init = require("init")
do_init = init.do_init

schema = require("schema")
do_schema = schema.do_schema

entity = require("entity")
do_entity = entity.do_entity
do_extension = entity.do_extension

ledger = require("ledger")
do_ledger = ledger.do_ledger

view = require("view")
do_view = view.do_view

auth = require("auth")
do_user = auth.do_user

document = require("document")
do_document = document.do_document

knowledge = require("knowledge")
do_knowledge = knowledge.do_knowledge

cgi = require("cgi")

function main()
    -- Check if running in CGI environment
    gateway = os.getenv("GATEWAY_INTERFACE")
    method = os.getenv("REQUEST_METHOD")
    is_cgi = (gateway != nil and gateway != "") or (method != nil and method != "")

    if is_cgi then
        ok, err = pcall(cgi.handle_request)
        if not ok then
            io.write("Status: 500 Internal Server Error\r\n")
            io.write("Content-Type: text/plain\r\n\r\n")
            io.write("Internal Server Error: " .. tostring(err) .. "\n")
        end
        return
    end

    command_funcs = {
        ["init"] = do_init,
        ["schema"] = do_schema,
        ["entity"] = do_entity,
        ["ledger"] = do_ledger,
        ["extension"] = do_extension,
        ["view"] = do_view,
        ["user"] = do_user,
        ["document"] = do_document,
        ["knowledge"] = do_knowledge,
    }

    arg[-1] = "lua"
    command = arg[1]

    if command != nil then
        arg[0] = "platform " .. command
    else
        arg[0] = "platform"
    end

    if command == nil or command == "-h" or command == "--help" then
        print("Usage: platform <init|schema|entity|ledger|extension|view|user|document|knowledge> ...")
        return
    end

    func = command_funcs[command]
    if func == nil then
        print("'" .. command .. "' is not a valid command")
        return
    end

    cmd_args = {}
    for i = 2, #arg do
        table.insert(cmd_args, arg[i])
    end
    cmd_args[0] = arg[0]

    if command == "init" then
        func(cmd_args)
        return
    end

    if config.is_initialized(".") == false then
        print("Not initialized. Run 'platform init' first.")
        return
    end

    func(cmd_args, config.db_path("."))
end

main()
