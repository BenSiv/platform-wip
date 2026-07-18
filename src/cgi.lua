db = require("db")
config = require("config")
schema = require("schema")
entity = require("entity")
ledger = require("ledger")
view = require("view")
template = require("template")
html = require("html")
json = require("dkjson")
paths = require("paths")
auth = require("auth")
document = require("document")
agent = require("agent")

cgi = {}

-- The baseline capability every gated route (other than /login,
-- /logout, and the login form's own POST) requires. Real session/login
-- machinery lives in auth.lua -- see cgi.handle_request's session
-- verification block below.
REQUIRED_CAPABILITY = "i"

-- Rows per /browse page. A flat, fixed page size rather than a
-- user-configurable one -- simple, and every entity type here is a
-- plain projected SQL table so COUNT/LIMIT/OFFSET are cheap regardless
-- of size.
BROWSE_PAGE_SIZE = 100

function cgi.has_capability(capabilities, letter)
    if capabilities == nil or capabilities == "" then
        return false
    end
    return string.find(capabilities, letter, 1, true) != nil
end

-- Luam's and/or require boolean operands, so plain "value or default"
-- nil-coalescing (fine in stock Lua) errors here whenever value is a
-- truthy non-boolean (e.g. any real env var/query value) -- exactly the
-- normal-success case, not just an edge case.
function default_value(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

-- Collapses entity.create/update's issues list into one human-readable
-- string, for a plain-form page (document-edit) that has nowhere to
-- show per-field errors the way the JS-driven registration table does.
function issues_to_message(issues)
    if issues == nil or #issues == 0 then
        return "Could not save."
    end
    parts = {}
    for _, issue in ipairs(issues) do
        if issue.severity == "error" then
            table.insert(parts, tostring(issue.message))
        end
    end
    if #parts == 0 then
        return "Could not save."
    end
    return table.concat(parts, "; ")
end

function parse_query(query_str)
    params = {}
    if query_str == nil then return params end
    for k, v in string.gmatch(query_str, "([^&=]+)=([^&=]*)") do
        -- simple url decoding for basic params
        decoded_v = string.gsub(string.gsub(v, "+", " "), "%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end)
        params[k] = decoded_v
    end
    return params
end

-- Filters/reorders a schema layout's fields to a comma-separated
-- allowlist, e.g. "?columns=lab_name,volume_ul" -- lets one embedded
-- registration table show only a curated subset of a schema's fields,
-- in a chosen order.
function filter_layout_columns(layout, columns_param)
    if columns_param == nil or columns_param == "" then
        return layout
    end
    by_name = {}
    for _, field in ipairs(layout.fields) do
        by_name[field.name] = field
    end
    filtered_fields = {}
    for wanted_name in string.gmatch(columns_param, "[^,]+") do
        field = by_name[wanted_name]
        if field != nil then
            table.insert(filtered_fields, field)
        end
    end
    if #filtered_fields == 0 then
        return layout
    end
    return {name = layout.name, fields = filtered_fields}
end

-- The `entry` query param is the embedding notebook entry's identifier,
-- whatever the client sent. Optional.
function source_from_params(params)
    source = {}
    if params.entry != nil and params.entry != "" then
        source.notebook_entry_id = params.entry
    end
    return source
end

-- `extra_headers` is an optional list of raw "Name: value" header
-- lines (used for Set-Cookie, which can't be folded into a single
-- header the way Content-Type/Content-Length are).
function print_response(status, content_type, body, extra_headers)
    io.write("Status: " .. status .. "\r\n")
    io.write("Content-Type: " .. content_type .. "\r\n")
    if extra_headers != nil then
        for _, header_line in ipairs(extra_headers) do
            io.write(header_line .. "\r\n")
        end
    end
    io.write("Content-Length: " .. string.len(body) .. "\r\n")
    io.write("\r\n")
    io.write(body)
end

-- Parses the raw "k1=v1; k2=v2" HTTP_COOKIE env var into a table.
function parse_cookies(cookie_header)
    cookies = {}
    if cookie_header == nil then
        return cookies
    end
    for pair in string.gmatch(cookie_header, "([^;]+)") do
        key, value = string.match(pair, "%s*([^=]+)=(.*)")
        if key != nil then
            cookies[key] = value
        end
    end
    return cookies
end

-- Builds one Set-Cookie header line. `max_age_seconds == nil` means a
-- session cookie (cleared on browser close, not just on expiry) --
-- used for CSRF, which is meant to live only as long as the login
-- session cookie it accompanies is being actively used, not persist as
-- its own independent lifetime. Marks Secure automatically whenever
-- the request itself arrived over HTTPS (HTTPS env var, the same
-- signal most CGI-hosting web servers set) rather than hardcoding it,
-- since a hardcoded Secure would silently break local plain-HTTP
-- testing/dev.
function set_cookie_header(name, value, max_age_seconds, http_only)
    parts = {name .. "=" .. value, "Path=/", "SameSite=Lax"}
    if max_age_seconds != nil then
        table.insert(parts, "Max-Age=" .. tostring(max_age_seconds))
    end
    if http_only == true then
        table.insert(parts, "HttpOnly")
    end
    https = os.getenv("HTTPS")
    if https != nil and https != "" then
        table.insert(parts, "Secure")
    end
    return "Set-Cookie: " .. table.concat(parts, "; ")
end

function clear_cookie_header(name)
    return "Set-Cookie: " .. name .. "=; Path=/; Max-Age=0"
end

-- Double-submit CSRF check for authenticated, state-changing POST
-- routes. The token travels as a custom request header (arrives as
-- HTTP_X_CSRF_TOKEN via the standard CGI header<->env-var mapping),
-- set client-side by JS reading its own non-HttpOnly csrf cookie --
-- see html.lua's getCsrfToken() helper.
-- Checks the double-submit CSRF token, from either a request header
-- (JS fetch() callers, e.g. /api/submit -- see html.lua's
-- getCsrfToken()) or a hidden form field (a plain HTML <form> POST,
-- e.g. the /admin/users pages below, has no way to attach a custom
-- header at all). `form_token` is only read if the header is absent.
function require_csrf(cookies, form_token)
    submitted = os.getenv("HTTP_X_CSRF_TOKEN")
    if submitted == nil or submitted == "" then
        submitted = form_token
    end
    return auth.verify_csrf(cookies.csrf, submitted)
end

function handle_autocomplete(db_path, params)
    ref_type = params.type
    query_str = default_value(params.query, "")
    if ref_type == nil or ref_type == "" then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type"}))
    end
    if not schema.valid_name_syntax(ref_type) then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
    end

    if not db.table_exists(db_path, ref_type) then
        return print_response("200 OK", "application/json", "[]")
    end

    cols = db.get_columns(db_path, ref_type)
    if #cols == 0 then
        return print_response("200 OK", "application/json", "[]")
    end

    search_cols = {}
    for _, col in ipairs(cols) do
        if col == "id" or col == "name" or col == "title" or col == "label" or col == "lot_number" then
            table.insert(search_cols, col)
        end
    end
    if #search_cols == 0 then
        table.insert(search_cols, cols[1])
    end

    where = {}
    for _, col in ipairs(search_cols) do
        table.insert(where, col .. " LIKE " .. db.quote("%" .. query_str .. "%"))
    end

    has_name = false
    for _, col in ipairs(cols) do
        if col == "name" then has_name = true end
    end

    q = nil
    if has_name then
        q = "SELECT id, name FROM " .. ref_type
    else
        text_col = "id"
        for _, col in ipairs(cols) do
            if col != "id" and col != "created_at" and col != "created_by" and col != "updated_at" and col != "updated_by" and col != "last_event_id" then
                text_col = col
                break
            end
        end
        q = "SELECT id, " .. text_col .. " AS name FROM " .. ref_type
    end

    if #where > 0 then
        q = q .. " WHERE " .. table.concat(where, " OR ")
    end
    q = q .. " LIMIT 15;"

    rows = db.query(db_path, q)
    result = default_value(rows, {})
    return print_response("200 OK", "application/json", json.encode(result))
end

-- Backs the entity-reference hover preview (render_reference_value's
-- data popover-src, html.lua) -- a few key fields of the referenced
-- row, fetched lazily on hover rather than shown by default on every
-- reference column.
function handle_preview(db_path, params)
    entity_type = params.type
    entity_id = tonumber(params.entity_id)
    if entity_type == nil or entity_type == "" or entity_id == nil then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
    end
    if not schema.valid_name_syntax(entity_type) then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
    end
    if not db.table_exists(db_path, entity_type) then
        return print_response("200 OK", "application/json", json.encode({html = "Unknown entity type."}))
    end

    rows = db.query(db_path, "SELECT * FROM " .. entity_type .. " WHERE id = " .. db.quote(entity_id) .. ";")
    if rows == nil or rows[1] == nil then
        return print_response("200 OK", "application/json", json.encode({html = "Not found."}))
    end
    row = rows[1]

    title = own_row_label(db_path, entity_type, row)
    if title == nil then
        title = entity_type .. " #" .. tostring(entity_id)
    end

    entity_layout, layout_err = schema.layout(db_path, entity_type)
    fields = {}
    if entity_layout != nil then
        fields = entity_layout.fields
    end

    field_lines = ""
    shown = 0
    for _, field in ipairs(fields) do
        if shown < 5 then
            value = row[field.name]
            if value != nil and tostring(value) != "" then
                display_value = tostring(value)
                if field.type == "reference" and field.ref_entity_type != nil then
                    ref_label = entity_display_label(db_path, field.ref_entity_type, value)
                    if ref_label != nil then
                        display_value = ref_label
                    end
                end
                field_lines = field_lines .. "<div><strong>" .. html_escape(field.label) .. ":</strong> " ..
                    html_escape(display_value) .. "</div>"
                shown = shown + 1
            end
        end
    end
    if field_lines == "" then
        field_lines = "<div style=\"color:#94a3b8;\">No fields to show.</div>"
    end

    preview_html = "<strong>" .. html_escape(title) .. "</strong>" ..
        "<hr style=\"margin:6px 0;border:none;border-top:1px solid #e2e8f0;\">" ..
        field_lines
    return print_response("200 OK", "application/json", json.encode({html = preview_html}))
end

-- `/login`: GET renders the form, POST verifies credentials (via
-- auth.login, which checks bcrypt + archived_at) and issues the two
-- cookies a session needs -- the HttpOnly signed session cookie and a
-- readable-by-JS CSRF token -- before redirecting to "/". Deliberately
-- not gated behind the session-verification block below (it runs
-- before that block in handle_request) since an unauthenticated caller
-- reaching /login is the expected case, not an error.
function handle_login(root, db_path, method, nonce)
    if method == "POST" then
        body = io.read("*all")
        form = parse_query(body)
        cap, login_err = auth.login(db_path, form.login, form.password)
        if cap == nil then
            return print_response("401 Unauthorized", "text/html", html.render_login("Invalid login or password.", nonce))
        end

        session_cookie, cookie_err = auth.issue_session_cookie(root, form.login)
        if session_cookie == nil then
            return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(cookie_err) .. "</h3>")
        end
        csrf_token, csrf_err = auth.generate_csrf_token()
        if csrf_token == nil then
            return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(csrf_err) .. "</h3>")
        end

        return print_response("302 Found", "text/plain", "", {
            "Location: /",
            set_cookie_header("session", session_cookie, SESSION_TTL_SECONDS, true),
            set_cookie_header("csrf", csrf_token, nil, false)
        })
    end

    return print_response("200 OK", "text/html", html.render_login(nil, nonce))
end

function cgi.handle_request()
    path_info = default_value(os.getenv("PATH_INFO"), "/register")
    query_string = default_value(os.getenv("QUERY_STRING"), "")
    method = default_value(os.getenv("REQUEST_METHOD"), "GET")
    params = parse_query(query_string)
    cookies = parse_cookies(os.getenv("HTTP_COOKIE"))

    root = config.find_root()
    db_path = config.db_path(root)

    -- Auto-initialize or sync database schemas on request. Directory
    -- creation is naturally tied to "does this deployment look
    -- bootstrapped yet" (only needed once), but every schema/table init
    -- call below is idempotent (CREATE TABLE IF NOT EXISTS, INSERT OR
    -- IGNORE) and runs unconditionally every request instead, matching
    -- schema.sync_all's own already-established pattern just below --
    -- otherwise a store initialized before some built-in schema existed
    -- would never pick it up (a real, if latent, gap this closes for
    -- auth/document both, not just newly-added ones going forward).
    if not config.is_initialized(root) then
        paths.create_dir_if_not_exists(config.store_dir(root))
        paths.create_dir_if_not_exists(config.schemas_dir(root))
        paths.create_dir_if_not_exists(config.extensions_dir(root))
        paths.create_dir_if_not_exists(config.views_dir(root))
        paths.create_dir_if_not_exists(config.templates_dir(root))
    end
    ledger.init_schema(db_path)
    auth.init_schema(db_path)
    document.init_schema(db_path)
    agent.init_schema(db_path)
    secret_ok, secret_err = auth.ensure_session_secret(root)
    if secret_ok == nil then
        return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(secret_err) .. "</h3>")
    end
    schema.sync_all(db_path, root)

    nonce = auth.generate_nonce()

    if path_info == "/login" then
        return handle_login(root, db_path, method, nonce)
    end

    -- Real session verification, replacing the old Phase 0
    -- AUTH_USER/AUTH_CAPABILITIES/AUTH_NONCE env-var stub. Capabilities
    -- are looked up fresh from the user table on every request rather
    -- than trusted from the cookie itself -- see auth.lua's own header
    -- comment for why.
    user = nil
    session_login = auth.verify_session_cookie(root, cookies.session)
    if session_login != nil then
        candidate = auth.get_user(db_path, session_login)
        if candidate != nil and (candidate.archived_at == nil or candidate.archived_at == "") then
            user = candidate
        end
    end

    if user == nil then
        return print_response("302 Found", "text/plain", "", {"Location: /login"})
    end

    capabilities = user.cap
    author = user.login

    if path_info == "/logout" then
        return print_response("302 Found", "text/plain", "", {
            "Location: /login",
            clear_cookie_header("session"),
            clear_cookie_header("csrf")
        })
    end

    if not cgi.has_capability(capabilities, REQUIRED_CAPABILITY) then
        return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires check-in capability</h3>")
    end

    if path_info == "/register" then
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'type' parameter</h3>")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Invalid 'type' parameter</h3>")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        layout = filter_layout_columns(layout, params.columns)
        layout_json = json.encode(layout)

        body = html.render(entity_type, layout_json, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/browse" then
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'type' parameter</h3>")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Invalid 'type' parameter</h3>")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end

        page = tonumber(params.page)
        if page == nil or page < 1 then
            page = 1
        end
        total = entity.count(db_path, entity_type)
        offset = (page - 1) * BROWSE_PAGE_SIZE
        rows = entity.list(db_path, entity_type, BROWSE_PAGE_SIZE, offset)
        body = html.render_browse(db_path, entity_type, layout, rows, page, BROWSE_PAGE_SIZE, total, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/" or path_info == "" then
        entity_types = schema.list(db_path)
        for _, row in ipairs(entity_types) do
            row.count = entity.count(db_path, row.name)
        end
        table.sort(entity_types, function(a, b)
            if a.count != b.count then
                return a.count > b.count
            end
            return a.name < b.name
        end)
        edges = schema.relationships(db_path)
        show_sql_widget = cgi.has_capability(capabilities, "s") or cgi.has_capability(capabilities, "a")
        body = html.render_index(entity_types, edges, show_sql_widget, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/detail" then
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'type' or 'entity_id' parameter</h3>")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Invalid 'type' parameter</h3>")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end

        row = entity.get(db_path, entity_type, entity_id)
        if row == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: no such " .. html_escape(entity_type) .. " #" .. tostring(entity_id) .. "</h3>")
        end

        history = ledger.history(db_path, entity_id)
        body = html.render_detail(db_path, entity_type, layout, row, history, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/view" then
        view_name = params.view_name
        if view_name == nil or view_name == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'view_name' parameter</h3>")
        end

        views_dir = config.views_dir(root)
        view_def, err = view.load(views_dir, view_name)
        if view_def == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        if view.is_approved(db_path, view_def) == false then
            return print_response("403 Forbidden", "text/html", "<h3>Error: view '" .. html_escape(view_name) .. "' is not approved</h3>")
        end

        param_value = nil
        if view_def.param != nil then
            param_value = params[view_def.param.name]
        end

        rows, err = view.run(db_path, view_def, param_value)
        if rows == nil then
            return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        body = html.render_view(view_def, rows, param_value)
        return print_response("200 OK", "text/html", body)
    end

    -- Documents (src/document.lua): a real parent_id tree, not a
    -- name-is-identity wiki page. `can_create`/`can_edit` are always
    -- true here -- the baseline "i" capability check above already
    -- gates every route in this file, and (matching /api/submit and
    -- /api/update, which also only require "i") creating/editing a
    -- document doesn't need anything beyond that today. Threaded
    -- through as an explicit parameter, not hardcoded in html.lua,
    -- so a future capability tier (e.g. a read-only viewer role) has
    -- somewhere to plug in without changing html.lua at all.
    if path_info == "/documents" then
        rows = document.all_active(db_path)
        body = html.render_document_tree(rows, true, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/document" then
        entity_id = tonumber(params.entity_id)
        if entity_id == nil then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'entity_id' parameter</h3>")
        end
        doc = entity.get(db_path, "document", entity_id)
        if doc == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: no such page #" .. tostring(entity_id) .. "</h3>")
        end
        rendered_html = document.render_html(db_path, doc.content)
        breadcrumbs = document.breadcrumbs(db_path, entity_id)
        children = document.children(db_path, entity_id)
        backlinks = document.backlinks(db_path, entity_id)
        body = html.render_document(doc, rendered_html, breadcrumbs, children, backlinks, true, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/document-edit" then
        doc = nil
        entity_id = tonumber(params.entity_id)
        if entity_id != nil then
            doc = entity.get(db_path, "document", entity_id)
            if doc == nil then
                return print_response("404 Not Found", "text/html", "<h3>Error: no such page #" .. tostring(entity_id) .. "</h3>")
            end
        end
        parent_id = nil
        if doc != nil then
            parent_id = doc.parent_id
        end
        parent_options_html = html.document_parent_options(document.all_active(db_path), parent_id, entity_id)
        body = html.render_document_edit(doc, parent_options_html, default_value(cookies.csrf, ""), nil, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/document-save" and method == "POST" then
        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end

        entity_id = tonumber(form.entity_id)
        parent_id = nil
        if form.parent_id != nil and form.parent_id != "" then
            parent_id = tonumber(form.parent_id)
        end

        if entity_id != nil and document.would_create_cycle(db_path, entity_id, parent_id) then
            doc = entity.get(db_path, "document", entity_id)
            parent_options_html = html.document_parent_options(document.all_active(db_path), parent_id, entity_id)
            body = html.render_document_edit(doc, parent_options_html, default_value(cookies.csrf, ""),
                "Can't move a page underneath its own sub-page.", nonce)
            return print_response("200 OK", "text/html", body)
        end

        saved_id = nil
        issues = nil
        if entity_id != nil then
            saved_id, issues = document.update_page(db_path, author, entity_id, form.title, parent_id, form.content,
                source_from_params(params))
        else
            saved_id, issues = document.create_page(db_path, author, form.title, parent_id, form.content,
                source_from_params(params))
        end

        if saved_id == nil then
            doc = nil
            if entity_id != nil then
                doc = entity.get(db_path, "document", entity_id)
            end
            parent_options_html = html.document_parent_options(document.all_active(db_path), parent_id, entity_id)
            body = html.render_document_edit(doc, parent_options_html, default_value(cookies.csrf, ""),
                issues_to_message(issues), nonce)
            return print_response("200 OK", "text/html", body)
        end

        return print_response("302 Found", "text/plain", "", {"Location: document?entity_id=" .. tostring(saved_id)})
    end

    if path_info == "/sql" then
        -- Setup or Admin only -- this runs arbitrary (SELECT-only)
        -- SQL an authenticated user typed themselves, so gating it
        -- behind the baseline "i" capability every other route uses
        -- would be far too permissive.
        if cgi.has_capability(capabilities, "s") == false and cgi.has_capability(capabilities, "a") == false then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end

        sql_text = params.q
        column_names = nil
        rows = nil
        sql_err = nil
        ref_columns = {}
        if sql_text == nil then
            sql_text = "SELECT * FROM sample LIMIT 20;"
        elseif sql_text != "" then
            column_names, rows, sql_err = view.run_adhoc(db_path, sql_text)
            from_table = view.guess_from_table(sql_text)
            ref_columns = view.reference_columns(db_path, view.guess_tables(sql_text))
            if from_table != nil and schema.is_registered(db_path, from_table) then
                ref_columns["id"] = from_table
            end
        end
        body = html.render_sql(db_path, sql_text, column_names, rows, sql_err, ref_columns, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/admin-users" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        users = auth.list_users(db_path, true)
        body = html.render_admin_users(users, default_value(cookies.csrf, ""), nil, false)
        return print_response("200 OK", "text/html", body)
    end

    -- Flat, single-segment names (not "/admin/users/create" etc) --
    -- deliberately, not just for consistency with every other route
    -- here: every relative link/form-action this app renders resolves
    -- against the CURRENT page's own directory, and this whole family
    -- of routes needs to link to each other and back to /admin-users.
    -- A flat namespace makes that trivial (every route is a sibling of
    -- every other); a nested one requires "../"-style relative math
    -- that's easy to get wrong -- exactly the bug class just fixed
    -- elsewhere in this file's own links.
    is_admin_user_action = path_info == "/admin-users-create" or
        path_info == "/admin-users-capabilities" or
        path_info == "/admin-users-password" or
        path_info == "/admin-users-archive" or
        path_info == "/admin-users-unarchive"
    if is_admin_user_action and method == "POST" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end

        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            users = auth.list_users(db_path, true)
            body = html.render_admin_users(users, default_value(cookies.csrf, ""), "CSRF check failed.", true)
            return print_response("403 Forbidden", "text/html", body)
        end

        ok = nil
        err = nil

        if path_info == "/admin-users-create" then
            ok, err = auth.create_user(db_path, form.login, form.password, form.cap)
        elseif path_info == "/admin-users-capabilities" then
            ok, err = auth.set_capabilities(db_path, form.login, form.cap)
        elseif path_info == "/admin-users-password" then
            ok, err = auth.set_password(db_path, form.login, form.password)
        elseif path_info == "/admin-users-archive" then
            ok, err = auth.archive_user(db_path, form.login)
        elseif path_info == "/admin-users-unarchive" then
            ok, err = auth.unarchive_user(db_path, form.login)
        end

        if ok == nil then
            users = auth.list_users(db_path, true)
            body = html.render_admin_users(users, default_value(cookies.csrf, ""), tostring(err), true)
            return print_response("200 OK", "text/html", body)
        end
        return print_response("302 Found", "text/plain", "", {"Location: admin-users"})
    end

    -- Chat/agent (src/agent.lua). AGENT_MODEL is configurable the same
    -- way VERTEX_PROJECT/VERTEX_REGION/AGENT_PROVIDER are -- an env
    -- var, not hardcoded, since a real model name is a deployment
    -- choice, not something this generic platform should assume.
    AGENT_DEFAULT_MODEL = "gemini-2.5-flash"

    if path_info == "/chat" then
        session_id = params.session_id
        sessions = agent.list_sessions(db_path, author)
        session = nil
        messages = {}
        pending = nil
        if session_id != nil and session_id != "" then
            session = agent.get_session(db_path, session_id, author)
            if session == nil then
                return print_response("404 Not Found", "text/html", "<h3>Error: no such chat session</h3>")
            end
            messages = agent.all_messages(db_path, session_id)
            pending = agent.latest_pending(db_path, session_id)
        end
        body = html.render_chat(sessions, session, messages, pending, default_value(cookies.csrf, ""), nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/chat-start" and method == "POST" then
        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end
        new_session_id, err = agent.create_session(db_path, author, form.title)
        if new_session_id == nil then
            return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        return print_response("302 Found", "text/plain", "", {"Location: chat?session_id=" .. new_session_id})
    end

    if path_info == "/chat-message" and method == "POST" then
        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end
        session = agent.get_session(db_path, form.session_id, author)
        if session == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: no such chat session</h3>")
        end
        model = default_value(os.getenv("AGENT_MODEL"), AGENT_DEFAULT_MODEL)
        agent.run_turn(db_path, form.session_id, author, nil, model, form.message)
        return print_response("302 Found", "text/plain", "", {"Location: chat?session_id=" .. form.session_id})
    end

    if path_info == "/chat-approve" and method == "POST" then
        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end
        model = default_value(os.getenv("AGENT_MODEL"), AGENT_DEFAULT_MODEL)
        agent.approve_pending(db_path, tonumber(form.pending_id), author, nil, model)
        return print_response("302 Found", "text/plain", "", {"Location: chat?session_id=" .. form.session_id})
    end

    if path_info == "/chat-deny" and method == "POST" then
        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end
        model = default_value(os.getenv("AGENT_MODEL"), AGENT_DEFAULT_MODEL)
        agent.deny_pending(db_path, tonumber(form.pending_id), author, nil, model)
        return print_response("302 Found", "text/plain", "", {"Location: chat?session_id=" .. form.session_id})
    end

    if path_info == "/templates" then
        templates_dir = config.templates_dir(root)
        body = html.render_templates_list(template.all(templates_dir))
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/template" then
        template_name = params.template_name
        if template_name == nil or template_name == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'template_name' parameter</h3>")
        end

        templates_dir = config.templates_dir(root)
        template_def, err = template.load(templates_dir, template_name)
        if template_def == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end

        rendered = template.render(template_def)
        body = html.render_template(template_def, rendered, nonce)
        return print_response("200 OK", "text/html", body)
    end

    if path_info == "/api/autocomplete" then
        return handle_autocomplete(db_path, params)
    end

    if path_info == "/api/preview" then
        return handle_preview(db_path, params)
    end

    if path_info == "/api/document-preview" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        input = io.read("*all")
        body_data, _, err = json.decode(input)
        if body_data == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        rendered = document.render_html(db_path, body_data.content)
        return print_response("200 OK", "application/json", json.encode({html = rendered}))
    end

    if path_info == "/api/validate" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        input = io.read("*all")
        rows_values, _, err = json.decode(input)
        if rows_values == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        batch_issues = entity.validate_batch(db_path, entity_type, rows_values)
        return print_response("200 OK", "application/json", json.encode(batch_issues))
    end

    if path_info == "/api/submit" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        input = io.read("*all")
        rows_values, _, err = json.decode(input)
        if rows_values == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end

        created_ids, batch_issues = entity.create_batch(db_path, entity_type, rows_values, author, source_from_params(params))
        response = {
            issues = batch_issues
        }
        if created_ids != nil then
            response.created_ids = created_ids
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/update" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        input = io.read("*all")
        values, _, err = json.decode(input)
        if values == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end

        updated_id, issues = entity.update(db_path, entity_type, entity_id, values, author, source_from_params(params))
        response = {
            issues = issues
        }
        if updated_id != nil then
            response.updated_id = updated_id
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/archive" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end

        archived_id, issues = entity.archive(db_path, entity_type, entity_id, author, source_from_params(params))
        response = {issues = issues}
        if archived_id != nil then
            response.archived_id = archived_id
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/unarchive" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end

        unarchived_id, issues = entity.unarchive(db_path, entity_type, entity_id, author, source_from_params(params))
        response = {issues = issues}
        if unarchived_id != nil then
            response.unarchived_id = unarchived_id
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    return print_response("404 Not Found", "text/plain", "Not Found")
end

return cgi
