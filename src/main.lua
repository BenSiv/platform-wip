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

-- Required explicitly here (not left to load transitively via cgi's
-- own require) even though knowledge.lua already depends on agent.lua
-- for its own reasons -- knowledge.lua can't require agent.lua back
-- itself (agent.lua requires knowledge.lua; a real circular require,
-- not just an ordering nuisance), so the one thing that needs both --
-- `platform knowledge review`, task #87 -- is dispatched from here
-- instead of inside knowledge.do_knowledge.
agent = require("agent")

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

    db_path = config.db_path(".")

    -- task #87: dispatched here, not inside knowledge.do_knowledge --
    -- see the require("agent") comment above for why.
    if command == "knowledge" and cmd_args[1] == "review" then
        session_id, result = agent.run_knowledge_review(db_path, os.getenv("USER"), agent.default_model())
        if session_id == nil then
            print("Error: " .. tostring(result))
            return
        end
        print("Review session: " .. tostring(session_id))
        print("Status: " .. tostring(result.status))
        if result.status == "pending_approval" then
            print("Proposed: " .. tostring(result.tool) .. "." .. tostring(result.method) ..
                " (pending action #" .. tostring(result.pending_id) .. ") -- approve/deny from the chat UI")
        else
            print(tostring(result.message))
        end
        return
    end

    func(cmd_args, db_path)
end

main()
