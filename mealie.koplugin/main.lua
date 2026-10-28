--[[--
Mealie client for KOReader.

Browse (meal plan, categories, tags, cookbooks, A-Z), search and read recipes
from a self-hosted Mealie server. A recipe is rendered into a small local HTML
page (large type, ingredients, numbered steps) and opened in KOReader's reader;
while it is open the device can be kept awake so it doesn't sleep mid-cook.

Mealie REST API (verified against Mealie v3.29.0 source):
  GET  /api/recipes?page&perPage&orderBy&orderDirection&search&categories&tags&cookbook
  GET  /api/recipes/<id>                         full recipe (slug or id; we always use the id)
  GET  /api/organizers/categories?perPage=-1     all categories
  GET  /api/organizers/tags?perPage=-1           all tags
  GET  /api/households/cookbooks?perPage=-1      cookbooks
  GET  /api/households/mealplans/today           today's meal plan entries
  GET  /api/media/recipes/<id>/images/min-original.webp   recipe photo
  POST /api/auth/token (form)                    optional login -> short-lived session token
  POST /api/users/api-tokens                     ... used once to mint a long-lived API token
Auth: "Authorization: Bearer <API token>". Optional Cloudflare Access headers.

@module koplugin.Mealie
--]]--

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+$") or "."
local TLS = dofile(PLUGIN_DIR .. "/tls.lua")
local Render = dofile(PLUGIN_DIR .. "/render.lua")
local KeepAwake = dofile(PLUGIN_DIR .. "/keepawake.lua")
local BUNDLED_CA = PLUGIN_DIR .. "/cacert.pem"

local DEFAULT_PAGE_SIZE = 50
local MAX_RESTORE_ITEMS = 300
local MAX_JSON_BYTES = 8 * 1024 * 1024   -- a recipe page or list is a few KB; refuse anything absurd
local MAX_IMAGE_BYTES = 4 * 1024 * 1024
local DEFAULT_AWAKE_HOURS = 3
local AUTOSTART_FILE = "/tmp/mealie.autostart"
local AUTOSTART_MAX_AGE = 120
local TOKEN_NAME = "KOReader"

-- Module-level: survives KOReader switching between reader and file manager.
local session = { pending = nil }

local Mealie = WidgetContainer:extend{
    name = "mealie",
    is_doc_only = false,
}
Mealie.KeepAwake = KeepAwake -- exposed for tests

---------------------------------------------------------------------------
-- Validation helpers
---------------------------------------------------------------------------

-- Mealie ids are UUIDs. Anything else from the server is rejected before it
-- can reach a URL path or a file name.
local function isUuid(s)
    return type(s) == "string"
        and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end
Mealie.isUuid = isUuid

local function text(v, fallback)
    if type(v) == "string" and v:match("%S") then
        return v
    end
    if type(v) == "number" then
        return tostring(v)
    end
    return fallback
end

local function samePath(a, b)
    if not a or not b then
        return false
    end
    if a == b then
        return true
    end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil.realpath then
        local ra, rb = ffiutil.realpath(a), ffiutil.realpath(b)
        return ra ~= nil and ra == rb
    end
    return false
end

local function itemIndex(menu, item)
    for i, it in ipairs(menu.item_table or {}) do
        if it == item then
            return i
        end
    end
    return 1
end

-- KOReader's sinks enforce socketutil's total timeout (LuaSec's wrapped socket
-- has no total timeout of its own); fall back to plain ltn12 on old builds.
-- Create them *after* socketutil:set_timeout(), which they read.
local function timedTableSink(t)
    if socketutil.table_sink then
        return (socketutil.table_sink(t))
    end
    return ltn12.sink.table(t)
end

local function timedFileSink(fh)
    if socketutil.file_sink then
        return (socketutil.file_sink(fh))
    end
    return ltn12.sink.file(fh)
end

-- An ltn12 sink that aborts once more than `limit` bytes arrive.
local function cappedSink(inner, limit)
    local total = 0
    return function(chunk, err)
        if chunk then
            total = total + #chunk
            if total > limit then
                return nil, "response too large"
            end
        end
        return inner(chunk, err)
    end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function Mealie:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/mealie.lua")
    self.menus = {}
    KeepAwake.deps.persist = function(value)
        self.settings:saveSetting("keepawake_active", value or nil)
        self.settings:flush()
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    local doc_file = self.ui.document and self.ui.document.file
    if doc_file and self:isRecipeFile(doc_file) then
        -- A recipe is being read: keep the device awake if enabled.
        if self:get("keep_awake", true) then
            KeepAwake.start(self:get("awake_hours", DEFAULT_AWAKE_HOURS) * 3600)
            UIManager.event_hook:registerWidget("InputEvent", self)
            self.started_keepawake = true
        end
    else
        -- Not reading a recipe: make sure nothing is left on, including after a crash.
        KeepAwake.stop()
        KeepAwake.cleanupStale(self:get("keepawake_active", false))
    end

    if self:consumeAutostart() then
        session.pending = nil
        UIManager:nextTick(function()
            self:showHome()
        end)
        return
    end
    if not self.ui.document and session.pending then
        local pending = session.pending
        session.pending = nil
        local lastfile = G_reader_settings:readSetting("lastfile")
        if self:get("return_to_list", true) and samePath(lastfile, pending.path) then
            UIManager:nextTick(function()
                self:restoreLocation(pending)
            end)
        end
    end
end

function Mealie:onInputEvent()
    KeepAwake.touch()
end

function Mealie:onCloseDocument()
    if self.started_keepawake then
        KeepAwake.stop()
        self.started_keepawake = false
    end
end

function Mealie:onCloseWidget()
    if self.started_keepawake then
        KeepAwake.stop()
        self.started_keepawake = false
    end
end

function Mealie:consumeAutostart(path)
    path = path or AUTOSTART_FILE
    local fh = io.open(path, "r")
    if not fh then
        return false
    end
    local stamp = tonumber((fh:read("*l") or ""):match("%d+"))
    fh:close()
    os.remove(path)
    return stamp ~= nil and math.abs(os.time() - stamp) <= AUTOSTART_MAX_AGE
end

function Mealie:onDispatcherRegisterActions()
    Dispatcher:registerAction("mealie_open", {
        category = "none", event = "ShowMealie", title = _("Mealie recipes"), general = true,
    })
end

function Mealie:onShowMealie()
    self:showHome()
    return true
end

function Mealie:addToMainMenu(menu_items)
    menu_items.mealie = {
        text = _("Mealie recipes"),
        sorting_hint = "tools",
        callback = function()
            self:showHome()
        end,
    }
end

---------------------------------------------------------------------------
-- Settings helpers
---------------------------------------------------------------------------

function Mealie:get(key, default)
    local value = self.settings:readSetting(key)
    if value == nil then
        return default
    end
    return value
end

function Mealie:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Mealie:getBaseUrl()
    local base = self:get("server_url", "")
    if base == "" then
        return nil
    end
    if not base:match("^%a+://") then
        base = "https://" .. base
    end
    return (base:gsub("/+$", ""))
end

-- The recipe folder path, without creating it.
function Mealie:recipeDirPath()
    local dir = self:get("recipe_dir")
    if not dir or dir == "" then
        local home = G_reader_settings:readSetting("home_dir") or "/mnt/us/documents"
        dir = home .. "/Mealie"
    end
    return (dir:gsub("/+$", ""))
end

-- The recipe folder, created on first use (once per path, not on every call).
function Mealie:getRecipeDir()
    local dir = self:recipeDirPath()
    if self._made_dir ~= dir then
        util.makePath(dir .. "/")
        self._made_dir = dir
    end
    return dir
end

-- Recipe pages are always "<recipe dir>/<uuid>.html".
function Mealie:isRecipeFile(path)
    if type(path) ~= "string" then
        return false
    end
    local dir, name = path:match("^(.*)/([^/]+)%.html$")
    return dir ~= nil and isUuid(name) and samePath(dir, self:recipeDirPath())
end

---------------------------------------------------------------------------
-- HTTP / API (same guard rails as the Paperless plugin, see SECURITY.md)
---------------------------------------------------------------------------

function Mealie:buildHeaders(extra, token)
    local headers = {
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
    }
    token = token or self:get("token", "")
    if token ~= "" then
        headers["Authorization"] = "Bearer " .. token
    end
    local cf_id, cf_secret = self:get("cf_client_id", ""), self:get("cf_client_secret", "")
    if cf_id ~= "" and cf_secret ~= "" then
        headers["CF-Access-Client-Id"] = cf_id
        headers["CF-Access-Client-Secret"] = cf_secret
    end
    for k, v in pairs(extra or {}) do
        headers[k] = v
    end
    return headers
end

-- Plain http is only allowed to loopback/private IPv4 literals and *.local hosts.
local function isLocalHost(host)
    host = (host or ""):lower()
    if host == "localhost" or host:match("%.local$") then
        return true
    end
    local a, b = host:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if not a then
        return false
    end
    return a == 10 or a == 127 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
end

function Mealie:checkedBaseUrl()
    local base = self:getBaseUrl()
    if not base then
        return nil, _("Set the Mealie server URL first (Settings).")
    end
    local scheme, host = base:match("^(%a+)://([^/:]+)")
    scheme = scheme and scheme:lower()
    if scheme == "https" then
        return base
    end
    if scheme == "http" and isLocalHost(host) then
        return base
    end
    return nil, _("Refusing to connect: use an https:// server URL. Plain http is only allowed to local network IP addresses, because it would send your token unencrypted.")
end

function Mealie:getCaFile()
    local custom = self:get("ca_file", "")
    return custom ~= "" and custom or BUNDLED_CA
end

-- All HTTP goes through here: redirects are never followed (they would forward
-- the Authorization and Cloudflare headers), and https verifies chain + hostname.
function Mealie:httpRequest(reqt)
    reqt.redirect = false
    if reqt.url:lower():match("^https://") then
        local cafile = self:getCaFile()
        if not lfs.attributes(cafile, "mode") then
            return T(_("CA certificate file not found: %1"), cafile), nil, nil
        end
        reqt.create = TLS.create(cafile)
    end
    -- Never route through KOReader's global HTTP proxy (Settings > Network):
    -- LuaSocket sends the full request, token included, to the proxy in clear
    -- for http URLs, and can't tunnel https. Mealie is reached directly.
    local saved_proxy = http.PROXY
    http.PROXY = nil
    reqt.proxy = nil
    local results = { pcall(http.request, reqt) }
    http.PROXY = saved_proxy
    if not results[1] then
        return tostring(results[2]), nil, nil
    end
    return socket.skip(1, unpack(results, 2, table.maxn(results)))
end

function Mealie:describeError(code, status, headers)
    if type(code) ~= "number" then
        local msg = tostring(code or status or "unreachable")
        if msg:find("CA certificate file not found", 1, true) then
            return msg
        end
        if msg:find("response too large", 1, true) then
            return _("The server sent an unexpectedly large response; it was discarded.")
        end
        local timeout_msg = socketutil.describe_error and socketutil.describe_error(msg,
            socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        if timeout_msg then
            return timeout_msg
        end
        if msg:find("certificate", 1, true) then
            return T(_("Secure connection refused: %1\n\nThe server's TLS certificate is not trusted or does not match the server name. Nothing was sent. If the server uses a private CA, set a custom CA file in Settings."), msg)
        end
        return T(_("Network error: %1"), msg)
    end
    if code >= 300 and code < 400 then
        local location = headers and (headers["location"] or headers["Location"]) or "?"
        return T(_("Server redirected (HTTP %1) to:\n%2\n\nThe plugin does not follow redirects. Check the server URL, or a proxy/login page in front of Mealie."), tostring(code), tostring(location))
    end
    local known = {
        [401] = _("Authentication failed (401). Check the API token."),
        [403] = _("Access denied (403). The user may lack permission, or a proxy such as Cloudflare Access rejected the request."),
        [404] = _("Not found (404). Check the server URL, or the item no longer exists."),
    }
    return known[code] or T(_("Server returned HTTP %1."), tostring(code))
end

function Mealie:showError(message)
    UIManager:show(InfoMessage:new{ text = message })
end

-- Low-level JSON request. Returns decoded value, or nil + error message (+ code).
function Mealie:requestJson(method, path, opts)
    opts = opts or {}
    local base, base_err = self:checkedBaseUrl()
    if not base then
        return nil, base_err
    end
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local reqt = {
        url = base .. path,
        method = method,
        headers = opts.headers or self:buildHeaders(),
        sink = cappedSink(timedTableSink(sink), MAX_JSON_BYTES),
    }
    if opts.body then
        reqt.source = ltn12.source.string(opts.body)
    end
    local code, resp_headers, status = self:httpRequest(reqt)
    socketutil:reset_timeout()
    if code ~= (opts.expect or 200) then
        return nil, self:describeError(code, status, resp_headers), code
    end
    local ok, data = pcall(JSON.decode, table.concat(sink))
    if not ok or type(data) ~= "table" then
        return nil, _("The server did not return JSON. Check the URL; if the server is behind Cloudflare Access, set the Access headers in Settings.")
    end
    return data
end

function Mealie:apiGet(path)
    if self:get("token", "") == "" then
        if not self:getBaseUrl() then
            return nil, _("Set the Mealie server URL first (Settings).")
        end
        return nil, _("No API token set (Settings).")
    end
    return self:requestJson("GET", path)
end

-- Log in once and mint a long-lived API token. Only the API token is stored;
-- the password and the short-lived session token are discarded.
function Mealie:requestToken(username, password)
    local body = "username=" .. util.urlEncode(username or "") .. "&password=" .. util.urlEncode(password or "")
    local headers = self:buildHeaders({
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Content-Length"] = tostring(#body),
    }, "")
    headers["Authorization"] = nil
    local data, err, code = self:requestJson("POST", "/api/auth/token", { headers = headers, body = body })
    if not data then
        if code == 401 then
            return nil, _("Login failed: wrong username or password.")
        elseif code == 423 then
            return nil, _("Login failed: this Mealie user is locked out.")
        end
        return nil, err
    end
    if type(data.access_token) ~= "string" or data.access_token == "" then
        return nil, _("Login response did not contain a token.")
    end
    local token_body = JSON.encode({ name = TOKEN_NAME .. " " .. os.date("%Y-%m-%d") })
    local token_headers = self:buildHeaders({
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#token_body),
    }, data.access_token)
    local created, cerr = self:requestJson("POST", "/api/users/api-tokens",
        { headers = token_headers, body = token_body, expect = 201 })
    if not created then
        return nil, cerr
    end
    if type(created.token) ~= "string" or created.token == "" then
        return nil, _("Mealie did not return an API token.")
    end
    -- Revoke the token from the previous login on this device, so logging in
    -- again doesn't pile up five-year tokens in Mealie. Best effort: it fails
    -- harmlessly if the old token belonged to another user or is already gone.
    local old_id = tonumber(self:get("token_id"))
    local new_id = tonumber(created.id)
    if old_id and old_id >= 0 and old_id % 1 == 0 and old_id ~= new_id then
        self:requestJson("DELETE", string.format("/api/users/api-tokens/%d", old_id),
            { headers = self:buildHeaders(nil, data.access_token) })
    end
    return created.token, (new_id and new_id >= 0 and new_id % 1 == 0) and new_id or nil
end

-- Paged recipe list. Returns the page table (items, total, page, total_pages).
function Mealie:fetchRecipes(params, page)
    local query = { "page=" .. page, "perPage=" .. self:get("page_size", DEFAULT_PAGE_SIZE) }
    for _i, p in ipairs(params) do
        query[#query + 1] = p
    end
    return self:apiGet("/api/recipes?" .. table.concat(query, "&"))
end

-- All items of an organizer endpoint (categories, tags, cookbooks).
function Mealie:fetchAll(path)
    local data, err = self:apiGet(path .. "?page=1&perPage=-1&orderBy=name&orderDirection=asc")
    if not data then
        return nil, err
    end
    local out = {}
    for _i, item in ipairs(type(data.items) == "table" and data.items or {}) do
        if type(item) == "table" and isUuid(item.id) then
            out[#out + 1] = item
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end)
    return out
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

function Mealie:showMenu(title, items, handlers, opts)
    opts = opts or {}
    local menu
    menu = Menu:new{
        title = title,
        subtitle = opts.subtitle,
        title_bar_left_icon = opts.back and "chevron.left" or nil,
        onLeftButtonTap = opts.back and function()
            self:closeMenu(menu)
        end or nil,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(menu_self, item)
            if handlers.select then
                handlers.select(menu, item)
            elseif item.action then
                item.action(menu)
            end
            return true
        end,
        onMenuHold = function(menu_self, item)
            if handlers.hold then
                handlers.hold(menu, item)
            end
            return true
        end,
        close_callback = function()
            if opts.back then
                self:closeAllMenus()
            else
                self:closeMenu(menu)
            end
        end,
    }
    table.insert(self.menus, menu)
    UIManager:show(menu)
    return menu
end

function Mealie:closeMenu(menu)
    for i = #self.menus, 1, -1 do
        if self.menus[i] == menu then
            table.remove(self.menus, i)
        end
    end
    UIManager:close(menu)
end

function Mealie:closeAllMenus()
    for i = #self.menus, 1, -1 do
        UIManager:close(self.menus[i])
        self.menus[i] = nil
    end
end

function Mealie:showHome()
    local items = {
        { text = _("Today's meal plan"), action = function() self:showMealPlan() end },
        { text = _("Newest recipes"), action = function() self:showNewest() end },
        { text = _("Search"), action = function() self:showSearchDialog() end },
        { text = _("Categories"), action = function() self:showOrganizer("categories") end },
        { text = _("Tags"), action = function() self:showOrganizer("tags") end },
        { text = _("Cookbooks"), action = function() self:showOrganizer("cookbooks") end },
        { text = _("All recipes (A–Z)"), action = function() self:showAllRecipes() end },
        { text = _("Saved recipes (offline)"), action = function() self:showSaved() end },
        { text = _("Settings"), action = function() self:showSettings() end },
    }
    self:showMenu(_("Mealie recipes"), items, {})
end

-- Same ordering the Mealie web UI uses for its recipe list (newest first).
function Mealie:showNewest(restore)
    self:showRecipeList(_("Newest recipes"), { "orderBy=created_at", "orderDirection=desc" }, restore)
end

function Mealie:showAllRecipes(restore)
    self:showRecipeList(_("All recipes"), { "orderBy=name", "orderDirection=asc" }, restore)
end

function Mealie:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search recipes"),
        input_hint = _("Name, ingredient, …"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = util.trim(dialog:getInputText())
                    UIManager:close(dialog)
                    if q ~= "" then
                        self:showRecipeList(T(_("Search: %1"), q), { "search=" .. util.urlEncode(q) })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local ORGANIZERS = {
    categories = { path = "/api/organizers/categories", title = _("Categories"), param = "categories", empty = _("No categories found.") },
    tags = { path = "/api/organizers/tags", title = _("Tags"), param = "tags", empty = _("No tags found.") },
    cookbooks = { path = "/api/households/cookbooks", title = _("Cookbooks"), param = "cookbook", empty = _("No cookbooks found.") },
}

function Mealie:showOrganizer(kind)
    local org = ORGANIZERS[kind]
    NetworkMgr:runWhenConnected(function()
        local list, err = self:fetchAll(org.path)
        if not list then
            self:showError(err)
            return
        end
        if #list == 0 then
            UIManager:show(InfoMessage:new{ text = org.empty })
            return
        end
        local items = {}
        for _i, o in ipairs(list) do
            items[#items + 1] = { text = text(o.name, "?"), org = o }
        end
        self:showMenu(org.title, items, {
            select = function(menu, item)
                self:showOrganizerRecipes(kind, item.org)
            end,
        }, { back = true })
    end)
end

function Mealie:organizerParams(kind, org_item)
    if not isUuid(org_item and org_item.id) then
        return nil
    end
    return { ORGANIZERS[kind].param .. "=" .. org_item.id, "orderBy=name", "orderDirection=asc" }
end

function Mealie:showOrganizerRecipes(kind, org_item, restore)
    local params = self:organizerParams(kind, org_item)
    if not params then
        self:showError(_("The server returned an invalid ID."))
        return
    end
    local name = text(org_item.name, "?")
    self:showRecipeList(name, params, restore, ORGANIZERS[kind].title .. " \u{203A} " .. name,
        { kind = kind, org = { id = org_item.id, name = name } })
end

---------------------------------------------------------------------------
-- Recipe lists
---------------------------------------------------------------------------

function Mealie:recipeItem(r)
    local mark = self:savedPath(r.id) and "\u{2B07} " or ""
    return { text = text(r.name, "?"), mandatory = mark .. text(r.totalTime, ""), recipe = r }
end

function Mealie:showRecipeList(title, params, restore, subtitle, origin)
    NetworkMgr:runWhenConnected(function()
        local data, err = self:fetchRecipes(params, 1)
        if not data then
            self:showError(err)
            return
        end
        local recipes = {}
        for _i, r in ipairs(type(data.items) == "table" and data.items or {}) do
            if type(r) == "table" and isUuid(r.id) then
                recipes[#recipes + 1] = r
            end
        end
        if #recipes == 0 then
            UIManager:show(InfoMessage:new{ text = _("No recipes found.") })
            return
        end
        local state = { page = 1, loaded = #recipes, total = tonumber(data.total) or #recipes }
        local want = restore and math.min(tonumber(restore.count) or 0, MAX_RESTORE_ITEMS) or 0
        while state.loaded < want and state.loaded < state.total do
            local more = self:fetchRecipes(params, state.page + 1)
            local more_items = more and type(more.items) == "table" and more.items or {}
            if #more_items == 0 then
                break
            end
            for _i, r in ipairs(more_items) do
                if type(r) == "table" and isUuid(r.id) then
                    recipes[#recipes + 1] = r
                end
            end
            state.page = state.page + 1
            state.loaded = state.loaded + #more_items
        end
        local menu_title = title .. " (" .. state.total .. ")"
        local function moreItem()
            return { text = T(_("Load more… (%1 left)"), state.total - state.loaded), is_more = true }
        end
        local items = {}
        for _i, r in ipairs(recipes) do
            items[#items + 1] = self:recipeItem(r)
        end
        if state.loaded < state.total then
            items[#items + 1] = moreItem()
        end
        local function returnInfo(menu, item)
            return { kind = "list", title = title, params = params, subtitle = subtitle,
                     origin = origin, count = state.loaded, focus = itemIndex(menu, item) }
        end
        local list_menu = self:showMenu(menu_title, items, {
            select = function(menu, item)
                if item.is_more then
                    self:loadMore(menu, menu_title, params, state, moreItem)
                elseif item.recipe then
                    self:openRecipe(item.recipe, returnInfo(menu, item))
                end
            end,
            hold = function(menu, item)
                if item.recipe then
                    self:showRecipeActions(item.recipe, returnInfo(menu, item))
                end
            end,
        }, { back = true, subtitle = subtitle })
        if restore and restore.focus and restore.focus > 1 then
            list_menu:switchItemTable(nil, items, math.min(restore.focus, #items))
        end
    end)
end

function Mealie:loadMore(menu, menu_title, params, state, moreItem)
    local data, err = self:fetchRecipes(params, state.page + 1)
    if not data then
        self:showError(err)
        return
    end
    local got = type(data.items) == "table" and data.items or {}
    local items = menu.item_table
    table.remove(items)
    for _i, r in ipairs(got) do
        if type(r) == "table" and isUuid(r.id) then
            items[#items + 1] = self:recipeItem(r)
        end
    end
    state.page = state.page + 1
    state.loaded = state.loaded + #got
    if #got > 0 and state.loaded < state.total then
        items[#items + 1] = moreItem()
    end
    menu:switchItemTable(menu_title, items, -1)
end

---------------------------------------------------------------------------
-- Meal plan
---------------------------------------------------------------------------

local ENTRY_TYPES = {
    breakfast = _("Breakfast"), lunch = _("Lunch"), dinner = _("Dinner"), side = _("Side"),
    snack = _("Snack"), drink = _("Drink"), dessert = _("Dessert"),
}
local ENTRY_ORDER = { breakfast = 1, lunch = 2, dinner = 3, side = 4, snack = 5, drink = 6, dessert = 7 }

function Mealie:showMealPlan(focus)
    NetworkMgr:runWhenConnected(function()
        local entries, err = self:apiGet("/api/households/mealplans/today")
        if not entries then
            self:showError(err)
            return
        end
        local rows = {}
        for _i, e in ipairs(entries) do
            if type(e) == "table" then
                local etype = text(e.entryType or e.entry_type, "")
                rows[#rows + 1] = { e = e, etype = etype, order = ENTRY_ORDER[etype] or 99 }
            end
        end
        if #rows == 0 then
            UIManager:show(InfoMessage:new{ text = _("Nothing is planned for today.") })
            return
        end
        table.sort(rows, function(a, b) return a.order < b.order end)
        local items = {}
        for _i, row in ipairs(rows) do
            local e, label = row.e, ENTRY_TYPES[row.etype] or row.etype
            local r = type(e.recipe) == "table" and isUuid(e.recipe.id) and e.recipe or nil
            if r then
                local item = self:recipeItem(r)
                item.mandatory = label
                items[#items + 1] = item
            else
                items[#items + 1] = { text = text(e.title, _("(note)")), mandatory = label,
                                      note = text(e.text, "") }
            end
        end
        local plan_menu = self:showMenu(_("Today's meal plan"), items, {
            select = function(menu, item)
                if item.recipe then
                    self:openRecipe(item.recipe, { kind = "mealplan", focus = itemIndex(menu, item) })
                elseif item.note then
                    UIManager:show(InfoMessage:new{ text = item.text .. (item.note ~= "" and ("\n\n" .. item.note) or "") })
                end
            end,
            hold = function(menu, item)
                if item.recipe then
                    self:showRecipeActions(item.recipe, { kind = "mealplan", focus = itemIndex(menu, item) })
                end
            end,
        }, { back = true })
        if focus and focus > 1 then
            plan_menu:switchItemTable(nil, items, math.min(focus, #items))
        end
    end)
end

---------------------------------------------------------------------------
-- Recipe pages
---------------------------------------------------------------------------

function Mealie:savedPath(id)
    if not isUuid(id) then
        return nil
    end
    local path = self:getRecipeDir() .. "/" .. id .. ".html"
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
end

-- Download the recipe photo next to the page. Returns the local file name or nil.
function Mealie:fetchImage(base, id, dir)
    local name = id .. ".webp"
    local tmp = dir .. "/." .. id .. ".webp.part"
    local fh = io.open(tmp, "wb")
    if not fh then
        return nil
    end
    local headers = self:buildHeaders()
    headers["Accept"] = "image/webp,image/*"
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, resp_headers = self:httpRequest{
        url = base .. "/api/media/recipes/" .. id .. "/images/min-original.webp",
        method = "GET",
        headers = headers,
        sink = cappedSink(timedFileSink(fh), MAX_IMAGE_BYTES),
    }
    socketutil:reset_timeout()
    if io.type(fh) == "file" then
        fh:close() -- the sink closes it on success; not when the transfer was aborted
    end
    local ctype = (resp_headers and resp_headers["content-type"] or ""):lower()
    if code ~= 200 or not ctype:find("image/", 1, true) then
        os.remove(tmp)
        return nil
    end
    os.remove(dir .. "/" .. name)
    if not os.rename(tmp, dir .. "/" .. name) then
        os.remove(tmp)
        return nil
    end
    return name
end

-- Fetch, render and save a recipe. Calls on_done(path) on success.
function Mealie:saveRecipe(summary, on_done)
    local id = summary and summary.id
    if not isUuid(id) then
        self:showError(_("The server returned an invalid recipe ID."))
        return
    end
    local base, base_err = self:checkedBaseUrl()
    if not base then
        self:showError(base_err)
        return
    end
    NetworkMgr:runWhenConnected(function()
        local info = InfoMessage:new{ text = T(_("Loading “%1”…"), text(summary.name, "recipe")) }
        UIManager:show(info)
        UIManager:forceRePaint()
        local recipe, err = self:apiGet("/api/recipes/" .. id)
        if not recipe then
            UIManager:close(info)
            self:showError(err)
            return
        end
        local dir = self:getRecipeDir()
        local image
        if self:get("show_photos", true) then
            image = self:fetchImage(base, id, dir)
        end
        local html = Render.recipeHtml(recipe, {
            title = text(summary.name, "Recipe"),
            image = image,
            saved_at = os.date("%Y-%m-%d %H:%M"),
        })
        local path = dir .. "/" .. id .. ".html"
        local tmp = dir .. "/." .. id .. ".html.part"
        local fh, ferr = io.open(tmp, "wb")
        if not fh then
            UIManager:close(info)
            self:showError(T(_("Cannot write to %1: %2"), dir, tostring(ferr)))
            return
        end
        fh:write(html)
        fh:close()
        os.remove(path)
        if not os.rename(tmp, path) then
            os.remove(tmp)
            UIManager:close(info)
            self:showError(T(_("Could not save recipe in %1"), dir))
            return
        end
        if not image then
            os.remove(dir .. "/" .. id .. ".webp")
        end
        local saved = self:get("saved", {})
        saved[id] = text(recipe.name, text(summary.name, id))
        self:set("saved", saved)
        UIManager:close(info)
        if on_done then
            UIManager:nextTick(function()
                on_done(path)
            end)
        end
    end)
end

function Mealie:openFile(path, return_info)
    if return_info then
        return_info.path = path
        session.pending = return_info
    else
        session.pending = nil
    end
    self:closeAllMenus()
    UIManager:nextTick(function()
        if self.ui.document then
            self.ui:switchDocument(path)
        else
            self.ui:openFile(path)
        end
    end)
end

-- Always fetch the current version when online; use the saved copy if
-- the "offline first" setting is on.
function Mealie:openRecipe(summary, return_info)
    local path = self:savedPath(summary and summary.id)
    if path and self:get("prefer_saved", false) then
        self:openFile(path, return_info)
        return
    end
    self:saveRecipe(summary, function(saved)
        self:openFile(saved, return_info)
    end)
end

function Mealie:deleteSaved(id)
    if not isUuid(id) then
        return
    end
    local dir = self:getRecipeDir()
    os.remove(dir .. "/" .. id .. ".html")
    os.remove(dir .. "/" .. id .. ".webp")
    local saved = self:get("saved", {})
    saved[id] = nil
    self:set("saved", saved)
end

function Mealie:showRecipeActions(summary, return_info)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local path = self:savedPath(summary.id)
    dialog = ButtonDialog:new{
        title = text(summary.name, "?"),
        buttons = {
            {{
                text = _("Open (refresh from Mealie)"),
                callback = function()
                    UIManager:close(dialog)
                    self:saveRecipe(summary, function(saved)
                        self:openFile(saved, return_info)
                    end)
                end,
            }},
            {{
                text = _("Open saved copy"),
                enabled = path ~= nil,
                callback = function()
                    UIManager:close(dialog)
                    self:openFile(path, return_info)
                end,
            }},
            {{
                text = _("Save for offline"),
                callback = function()
                    UIManager:close(dialog)
                    self:saveRecipe(summary, function()
                        UIManager:show(InfoMessage:new{ text = _("Saved for offline use."), timeout = 2 })
                    end)
                end,
            }},
            {{
                text = _("Delete saved copy"),
                enabled = path ~= nil,
                callback = function()
                    UIManager:close(dialog)
                    self:deleteSaved(summary.id)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Mealie:showSaved(focus)
    local saved = self:get("saved", {})
    local items = {}
    for id, name in pairs(saved) do
        if isUuid(id) and self:savedPath(id) then
            items[#items + 1] = { text = text(name, id), recipe = { id = id, name = name } }
        end
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No saved recipes yet. Recipes are saved when you open them.") })
        return
    end
    table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
    local saved_menu = self:showMenu(_("Saved recipes"), items, {
        select = function(menu, item)
            self:openFile(self:savedPath(item.recipe.id), { kind = "saved", focus = itemIndex(menu, item) })
        end,
        hold = function(menu, item)
            self:showRecipeActions(item.recipe, { kind = "saved", focus = itemIndex(menu, item) })
        end,
    }, { back = true })
    if focus and focus > 1 then
        saved_menu:switchItemTable(nil, items, math.min(focus, #items))
    end
end

function Mealie:restoreLocation(loc)
    self:showHome()
    if loc.kind == "list" then
        if loc.origin and loc.origin.kind and ORGANIZERS[loc.origin.kind] then
            -- Rebuild the organizer level so Back walks up again.
            self:showOrganizer(loc.origin.kind)
        end
        self:showRecipeList(loc.title, loc.params, { count = loc.count, focus = loc.focus }, loc.subtitle, loc.origin)
    elseif loc.kind == "mealplan" then
        self:showMealPlan(loc.focus)
    elseif loc.kind == "saved" then
        self:showSaved(loc.focus)
    end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

function Mealie:inputSetting(title, key, hint, refresh)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self:get(key, ""),
        input_hint = hint,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    self:set(key, util.trim(dialog:getInputText()))
                    UIManager:close(dialog)
                    refresh()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Mealie:loginDialog(refresh)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Log in to Mealie"),
        fields = {
            { hint = _("Username or email") },
            { hint = _("Password"), text_type = "password" },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Log in"),
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    NetworkMgr:runWhenConnected(function()
                        local token, err_or_id = self:requestToken(fields[1], fields[2])
                        local err = err_or_id
                        if token then
                            self:set("token", token)
                            self:set("token_id", err_or_id)
                            UIManager:show(InfoMessage:new{ text = T(_("Logged in. An API token named “%1 …” was created in Mealie and saved here (password not stored)."), TOKEN_NAME) })
                            refresh()
                        else
                            self:showError(err)
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Mealie:cloudflareDialog(refresh)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Cloudflare Access headers (optional)"),
        fields = {
            { text = self:get("cf_client_id", ""), hint = _("CF-Access-Client-Id") },
            { text = self:get("cf_client_secret", ""), hint = _("CF-Access-Client-Secret") },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                callback = function()
                    local fields = dialog:getFields()
                    self:set("cf_client_id", util.trim(fields[1]))
                    self:set("cf_client_secret", util.trim(fields[2]))
                    UIManager:close(dialog)
                    refresh()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Mealie:toggleItem(label, key, default, refresh)
    return {
        text = label,
        mandatory = self:get(key, default) and _("on") or _("off"),
        action = function()
            self:set(key, not self:get(key, default))
            refresh()
        end,
    }
end

function Mealie:settingsItems(refresh)
    local cf_set = self:get("cf_client_id", "") ~= "" and self:get("cf_client_secret", "") ~= ""
    return {
        {
            text = _("Server URL"),
            mandatory = self:get("server_url", "") ~= "" and self:get("server_url") or _("not set"),
            action = function()
                self:inputSetting(_("Server URL"), "server_url", _("https://mealie.example.com"), refresh)
            end,
        },
        {
            text = _("API token"),
            mandatory = self:get("token", "") ~= "" and _("set") or _("not set"),
            action = function()
                self:inputSetting(_("API token"), "token", _("Mealie > Profile > API Tokens"), refresh)
            end,
        },
        {
            text = _("Log in with username/password"),
            action = function()
                self:loginDialog(refresh)
            end,
        },
        {
            text = _("Cloudflare Access headers"),
            mandatory = cf_set and _("set") or _("not set"),
            action = function()
                self:cloudflareDialog(refresh)
            end,
        },
        {
            text = _("Custom CA certificate file"),
            mandatory = self:get("ca_file", "") ~= "" and self:get("ca_file") or _("bundled"),
            action = function()
                self:inputSetting(_("CA certificate file (PEM); empty = bundled public CAs"), "ca_file", "/mnt/us/koreader/my-ca.pem", refresh)
            end,
        },
        {
            text = _("Recipe folder"),
            mandatory = self:getRecipeDir(),
            action = function()
                require("ui/downloadmgr"):new{
                    onConfirm = function(path)
                        self:set("recipe_dir", path)
                        refresh()
                    end,
                }:chooseDir(self:getRecipeDir())
            end,
        },
        {
            text = _("Recipes per page"),
            mandatory = tostring(self:get("page_size", DEFAULT_PAGE_SIZE)),
            action = function()
                UIManager:show(SpinWidget:new{
                    title_text = _("Recipes per page"),
                    value = self:get("page_size", DEFAULT_PAGE_SIZE),
                    value_min = 10, value_max = 100, value_step = 10,
                    default_value = DEFAULT_PAGE_SIZE,
                    ok_text = _("Save"),
                    callback = function(spin)
                        self:set("page_size", spin.value)
                        refresh()
                    end,
                })
            end,
        },
        self:toggleItem(_("Keep screen awake while a recipe is open"), "keep_awake", true, refresh),
        {
            text = _("Keep awake for up to (hours without a tap)"),
            mandatory = tostring(self:get("awake_hours", DEFAULT_AWAKE_HOURS)),
            action = function()
                UIManager:show(SpinWidget:new{
                    title_text = _("Hours without a tap before the device may sleep"),
                    value = self:get("awake_hours", DEFAULT_AWAKE_HOURS),
                    value_min = 1, value_max = 12, value_step = 1,
                    default_value = DEFAULT_AWAKE_HOURS,
                    ok_text = _("Save"),
                    callback = function(spin)
                        self:set("awake_hours", spin.value)
                        refresh()
                    end,
                })
            end,
        },
        self:toggleItem(_("Show recipe photos"), "show_photos", true, refresh),
        self:toggleItem(_("Open saved copy instead of refreshing"), "prefer_saved", false, refresh),
        self:toggleItem(_("Return to the list after closing a recipe"), "return_to_list", true, refresh),
    }
end

function Mealie:showSettings()
    local menu
    local function refresh()
        if menu then
            menu:switchItemTable(nil, self:settingsItems(refresh), -1)
        end
    end
    menu = self:showMenu(_("Mealie settings"), self:settingsItems(refresh), {}, { back = true })
end

return Mealie
