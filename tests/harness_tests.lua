local results = { pass = 0, fail = 0 }
local function check(cond, msg)
    if cond then results.pass = results.pass + 1
    else results.fail = results.fail + 1; print("FAIL: " .. msg) end
end

-- ---- stubs ---------------------------------------------------------------
local shown = {}
local scheduled = {}
local executed = {}
local hooks = {}
os.execute = function(cmd) executed[#executed + 1] = cmd; return 0 end

local function newWidget(kind)
    return { new = function(self, args) args = args or {}; args.kind = kind; return args end }
end
local gettext = setmetatable({}, { __call = function(_, s) return s end })
package.preload["gettext"] = function() return gettext end
package.preload["ffi/util"] = function()
    return { template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end }
end
package.preload["ui/widget/buttondialog"] = function() return newWidget("buttondialog") end
package.preload["ui/widget/infomessage"] = function() return newWidget("info") end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(self, args)
        args.kind = "input"
        args.getInputText = function(d) return d._text or d.input or "" end
        args.onShowKeyboard = function() end
        return args
    end }
end
package.preload["ui/widget/multiinputdialog"] = function()
    return { new = function(self, args)
        args.kind = "multiinput"
        args.getFields = function(d) return d._fields or {} end
        args.onShowKeyboard = function() end
        return args
    end }
end
package.preload["ui/widget/spinwidget"] = function() return newWidget("spin") end
package.preload["ui/widget/menu"] = function()
    return { new = function(self, args)
        args.kind = "menu"
        args.switchItemTable = function(m, title, items, n) if title then m.title = title end; m.item_table = items; m.focus = n end
        return args
    end }
end
package.preload["ui/downloadmgr"] = function()
    return { new = function(self, args)
        return { chooseDir = function() args.onConfirm(WORK .. "/chosen") end }
    end }
end
local UIManager = {
    show = function(self, w) table.insert(shown, w) end,
    close = function(self, w) for i = #shown, 1, -1 do if shown[i] == w then table.remove(shown, i) end end end,
    nextTick = function(self, fn) fn() end,
    forceRePaint = function() end,
    scheduleIn = function(self, secs, fn) scheduled[fn] = secs end,
    unschedule = function(self, fn) scheduled[fn] = nil end,
    event_hook = { registerWidget = function(self, name, w) hooks[#hooks + 1] = { name = name, w = w } end },
}
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/network/manager"] = function() return { runWhenConnected = function(self, fn) fn() end } end
package.preload["dispatcher"] = function() return { registerAction = function() end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return WORK end } end
local settings_store = {}
package.preload["luasettings"] = function()
    local LS = {}
    function LS:open(path)
        settings_store[path] = settings_store[path] or {}
        return setmetatable({ data = settings_store[path] }, { __index = {
            readSetting = function(s, k) return s.data[k] end,
            saveSetting = function(s, k, v) s.data[k] = v end,
            flush = function() end,
        } })
    end
    return LS
end
package.preload["json"] = function() return { decode = py_json_decode, encode = py_json_encode } end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    function WC:extend(t) t = t or {}; t.__index = t; setmetatable(t, { __index = self }); return t end
    function WC:new(o) o = o or {}; setmetatable(o, { __index = self }); if o.init then o:init() end; return o end
    return WC
end
package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end; return 1 end end,
            file = function(fh) return function(chunk) if chunk then fh:write(chunk) else fh:close() end; return 1 end end,
        },
        source = { string = function(s) local done = false
            return function() if done then return nil end; done = true; return s end end },
    }
end
package.preload["socket"] = function() return { skip = function(n, ...) return select(n + 1, ...) end } end
package.preload["socket.http"] = function()
    return { request = function(opts)
        local code, h, s = py_request(opts)
        if code == nil then return nil, h end
        return 1, code, h, s
    end }
end
package.preload["ssl"] = function() return {} end
package.preload["ssl.https"] = function() return { TIMEOUT = 60 } end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end,
             LARGE_BLOCK_TIMEOUT = 1, LARGE_TOTAL_TIMEOUT = 1, FILE_BLOCK_TIMEOUT = 1, FILE_TOTAL_TIMEOUT = 1 }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(p, what) return py_stat(p, what) end }
end
package.preload["util"] = function()
    local U = {}
    function U.urlEncode(s) return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)) end
    function U.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    function U.makePath(p) os.remove("/nonexistent"); local f = io.popen("mkdir -p '" .. p .. "'"); f:close() end
    return U
end
local is_kindle = true
package.preload["device"] = function() return { isKindle = function() return is_kindle end } end
local PluginShare = {}
package.preload["pluginshare"] = function() return PluginShare end
local LASTFILE
G_reader_settings = { readSetting = function(self, k)
    if k == "home_dir" then return WORK .. "/home" end
    if k == "lastfile" then return LASTFILE end
end }

-- ---- load plugin --------------------------------------------------------------
local Mealie = assert(loadfile(PLUGIN_DIR .. "/main.lua"))()
local meta = assert(loadfile(PLUGIN_DIR .. "/_meta.lua"))()
check(type(meta.fullname) == "string" and type(meta.description) == "string", "_meta.lua returns fullname/description")
local KA = Mealie.KeepAwake
check(KA ~= nil, "KeepAwake exposed for tests")
local clock = 1000000
KA.deps.now = function() return clock end

local opened
local function fmUi() return { menu = { registerToMainMenu = function() end }, openFile = function(self, f) opened = f end } end
local registered
local p = Mealie:new{ ui = { menu = { registerToMainMenu = function(self, x) registered = x end }, openFile = function(self, f) opened = f end } }
check(registered == p, "plugin registered with main menu")
local items = {}
p:addToMainMenu(items)
check(items.mealie and items.mealie.sorting_hint == "tools" and items.mealie.text == "Mealie recipes", "Tools menu entry")

local function fire(fn) scheduled[fn] = nil; fn() end
local function lastShown() return shown[#shown] end
local function reqs() return py_requests() end
local function findItem(menu, t) for _i, it in ipairs(menu.item_table) do if it.text == t then return it end end end
local function sel(menu, it) return menu:onMenuSelect(it) end
local function texts(m) local t = {}; for i, it in ipairs(m.item_table) do t[i] = it.text .. "|" .. tostring(it.mandatory or "") end; return table.concat(t, ", ") end
local function errorText(fn) shown = {}; fn(); local w = lastShown(); return w and w.kind == "info" and w.text or tostring(w and w.kind) end

-- ---- unconfigured --------------------------------------------------------------
check(errorText(function() p:showAllRecipes() end):find("server URL"), "unconfigured: asks for server URL")

-- ---- settings ---------------------------------------------------------------------
shown = {}
p:showHome()
local home = lastShown()
check(texts(home) == "Today's meal plan|, Newest recipes|, Search|, Categories|, Tags|, Cookbooks|, All recipes (A–Z)|, Saved recipes (offline)|, Settings|", "home menu: " .. texts(home))
sel(home, findItem(home, "Settings"))
local st = lastShown()
check(st.title == "Mealie settings", "settings menu")
sel(st, findItem(st, "Server URL"))
lastShown()._text = "  mealie.test/  "
lastShown().buttons[1][2].callback()
check(p:getBaseUrl() == "https://mealie.test", "bare host -> https, trimmed: " .. tostring(p:getBaseUrl()))
check(findItem(st, "Server URL").mandatory == "mealie.test/", "settings refreshed")
check(errorText(function() p:showAllRecipes() end):find("No API token"), "missing token message")

-- login: wrong, locked, right
shown = {}
sel(st, findItem(st, "Log in with username/password"))
local login = lastShown()
check(login.kind == "multiinput" and login.fields[2].text_type == "password", "login dialog masks password")
login._fields = { "kindle", "wrong" }
login.buttons[1][2].callback()
check(lastShown().text:find("wrong username"), "bad login message")
sel(st, findItem(st, "Log in with username/password")); login = lastShown(); login._fields = { "locked", "x" }
login.buttons[1][2].callback()
check(lastShown().text:find("locked out"), "locked-out message")
check(p:get("token", "") == "", "no token after failed logins")
sel(st, findItem(st, "Log in with username/password")); login = lastShown(); login._fields = { "kindle", "p&ss word" }
py_clear_requests()
login.buttons[1][2].callback()
check(p:get("token") == "LONGTOKEN", "long-lived API token stored")
local r = reqs()
check(#r == 2 and r[1].url == "https://mealie.test/api/auth/token" and r[1].method == "POST", "login posts to /api/auth/token")
check(r[1].headers.Authorization == nil, "login carries no Authorization")
check(r[1].headers["Content-Type"] == "application/x-www-form-urlencoded" and r[1].body == "username=kindle&password=p%26ss%20word", "login is form-encoded and escaped: " .. tostring(r[1].body))
check(r[2].url == "https://mealie.test/api/users/api-tokens" and r[2].headers.Authorization == "Bearer SESSIONJWT", "token minted with the session token")
check(r[2].body:find('"name": "KOReader ', 1, true) ~= nil, "token named KOReader <date>: " .. tostring(r[2].body))
local s = settings_store[WORK .. "/mealie.lua"]
local has_secret = false
for k, v in pairs(s) do if tostring(v):find("p&ss", 1, true) or tostring(v):find("SESSIONJWT", 1, true) then has_secret = true end end
check(not has_secret, "password and session token not stored")
check(findItem(st, "API token").mandatory == "set", "token shown as set, not revealed")

shown = {}
sel(st, findItem(st, "Cloudflare Access headers"))
local cf = lastShown(); cf._fields = { " id.access ", " secret " }; cf.buttons[1][2].callback()
check(p:get("cf_client_id") == "id.access" and p:get("cf_client_secret") == "secret", "CF headers saved trimmed")
sel(st, findItem(st, "Recipe folder"))
check(p:get("recipe_dir") == WORK .. "/chosen", "recipe folder chosen")
p:set("recipe_dir", WORK .. "/recipes")
sel(st, findItem(st, "Recipes per page"))
local spin = lastShown(); check(spin.kind == "spin", "page size spinner"); spin.callback({ value = 2 })
check(p:get("page_size") == 2, "page size saved")
sel(st, findItem(st, "Keep awake for up to (hours without a tap)"))
lastShown().callback({ value = 2 })
check(p:get("awake_hours") == 2, "awake hours saved")
for _i, label in ipairs({ "Show recipe photos", "Keep screen awake while a recipe is open", "Return to the list after closing a recipe" }) do
    sel(st, findItem(st, label)); check(findItem(st, label).mandatory == "off", label .. " toggles off")
    sel(st, findItem(st, label)); check(findItem(st, label).mandatory == "on", label .. " toggles on")
end

-- ---- lists -------------------------------------------------------------------------
shown = {}
py_clear_requests()
p:showAllRecipes()
local list = lastShown()
check(list.title == "All recipes (3)", "list title with total: " .. tostring(list.title))
check(texts(list) == "Boilermaker Tailgate Chili|2 hours 30 minutes, Dan-O's Chicken Thighs|1 hour 30 minutes, Load more… (1 left)|", "first page + load more: " .. texts(list))
r = reqs()
check(r[1].url == "https://mealie.test/api/recipes?page=1&perPage=2&orderBy=name&orderDirection=asc", "list URL: " .. r[1].url)
check(r[1].headers.Authorization == "Bearer LONGTOKEN", "Bearer token sent")
check(r[1].headers["CF-Access-Client-Id"] == "id.access" and r[1].headers["CF-Access-Client-Secret"] == "secret", "CF headers sent")
sel(list, list.item_table[3])
check(texts(list) == "Boilermaker Tailgate Chili|2 hours 30 minutes, Dan-O's Chicken Thighs|1 hour 30 minutes, Prime Rib Roast|", "load more appends: " .. texts(list))
check(reqs()[2].url:find("page=2", 1, true) ~= nil, "page 2 requested")
p:set("page_size", 50)
shown = {}
py_clear_requests()
sel(home, findItem(home, "Newest recipes"))
check(reqs()[1].url == "https://mealie.test/api/recipes?page=1&perPage=50&orderBy=created_at&orderDirection=desc", "newest recipes URL: " .. reqs()[1].url)
check(lastShown().title == "Newest recipes (3)", "newest recipes title")

-- organizers
for _i, case in ipairs({
    { "categories", "Categories", "Dessert|, Main|", "categories=" .. CAT_MAIN, "Main" },
    { "tags", "Tags", "Chicken|", "tags=" .. TAG_CHICKEN, "Chicken" },
    { "cookbooks", "Cookbooks", "Weeknights|", "cookbook=" .. COOKBOOK, "Weeknights" },
}) do
    shown = {}
    py_clear_requests()
    p:showOrganizer(case[1])
    local om = lastShown()
    check(om.title == case[2] and texts(om) == case[3], case[1] .. " list (invalid ids dropped, sorted): " .. texts(om))
    check(reqs()[1].url:find("perPage=-1", 1, true) ~= nil, case[1] .. " fetches all")
    py_clear_requests()
    sel(om, findItem(om, case[5]))
    check(reqs()[1].url:find(case[4], 1, true) ~= nil, case[1] .. " filter param: " .. reqs()[1].url)
    check(lastShown().subtitle == case[2] .. " \u{203A} " .. case[5], case[1] .. " breadcrumb: " .. tostring(lastShown().subtitle))
end
check(errorText(function() p:showOrganizerRecipes("categories", { id = "x&tags=1", name = "x" }) end):find("invalid ID"), "non-UUID organizer id rejected")

-- search
shown = {}
p:showSearchDialog()
lastShown()._text = "  chili & beans  "
py_clear_requests()
lastShown().buttons[1][2].callback()
check(reqs()[1].url:find("search=chili%%20%%26%%20beans") ~= nil, "search URL-encoded: " .. reqs()[1].url)
check(lastShown().kind == "info" and lastShown().text == "No recipes found.", "no-match message")

-- server-supplied bad ids never reach the UI
py_set_mode("badids")
shown = {}
p:showAllRecipes()
check(not texts(lastShown()):find("evil"), "recipe with non-UUID id dropped")
py_set_mode("ok")

-- ---- meal plan -----------------------------------------------------------------------
shown = {}
py_clear_requests()
p:showMealPlan()
local plan = lastShown()
check(reqs()[1].url == "https://mealie.test/api/households/mealplans/today", "meal plan URL")
check(texts(plan) == "Leftover pizza|Breakfast, Boilermaker Tailgate Chili|Dinner, (note)|Side", "meal plan sorted by meal, notes shown: " .. texts(plan))
sel(plan, plan.item_table[1])
check(lastShown().kind == "info" and lastShown().text == "Leftover pizza\n\nFrom Friday", "note entry shows its text")
check(plan.item_table[3].recipe == nil, "entry with invalid recipe id is not openable")
py_set_plan(true)
check(errorText(function() p:showMealPlan() end) == "Nothing is planned for today.", "empty plan message")
py_set_plan(false)

-- ---- open a recipe -----------------------------------------------------------------------
shown = {}
p:showMealPlan()
plan = lastShown()
py_clear_requests()
opened = nil
sel(plan, findItem(plan, "Boilermaker Tailgate Chili"))
r = reqs()
check(r[1].url == "https://mealie.test/api/recipes/" .. CHILI, "recipe fetched by id: " .. r[1].url)
check(r[2].url == "https://mealie.test/api/media/recipes/" .. CHILI .. "/images/min-original.webp", "photo fetched")
local page = WORK .. "/recipes/" .. CHILI .. ".html"
check(opened == page, "KOReader opens the recipe page: " .. tostring(opened))
check(py_stat(WORK .. "/recipes/" .. CHILI .. ".webp", "mode") == "file", "photo saved next to page")
local html = py_read(page) or ""
check(not html:find("<script", 1, true) and html:find("Chili &lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;beans&quot;", 1, true), "recipe name HTML-escaped")
check(html:find('<img src="' .. CHILI .. '.webp"', 1, true) ~= nil, "page uses the local photo")
check(html:find("<b>Total:</b>&#160;2 hours 30 minutes", 1, true) and html:find("<b>Prep:</b>&#160;30 minutes", 1, true) and html:find("<b>Cook:</b>&#160;2 hours", 1, true) and html:find("<b>Serves:</b>&#160;12", 1, true), "times and servings")
check(html:find("<p>A <b>crowd</b> pleaser.</p>\n<p>Game day!</p>", 1, true) ~= nil, "description: bold + paragraphs")
check(html:find("<li>2 pounds ground beef chuck</li>\n</ul>\n<h3>Seasoning rub:</h3>\n<ul class=\"ing\">\n<li>3 cloves garlic, minced</li>", 1, true) ~= nil, "ingredient section header")
check(html:find("<li>1 tablespoon bacon bits</li>", 1, true) ~= nil, "falls back to originalText")
check(html:find("<li>2\u{BD} cups beef broth, low-salt</li>", 1, true) ~= nil, "composes parsed ingredient with fraction")
check(html:find("<li>salt</li>", 1, true) ~= nil, "zero quantity omitted")
check(html:find('<p class="stepnum">Step 1</p><p>Gather all ingredients.</p>', 1, true) ~= nil, "step 1")
check(html:find("<h3>Seasoning rub</h3>\n<div class=\"step\"><p class=\"stepnum\">Step 2</p><p>Combine.<br/>Rub it in.</p>", 1, true) ~= nil, "instruction section + continuous numbering + line breaks")
check(html:find("Step 3: Simmer</p><p>Cover and simmer &lt;low&gt;.</p>", 1, true) ~= nil, "step summary, text escaped")
check(html:find("<h2>Notes</h2>\n<h3>Tip</h3>\n<p>Better the next day.</p>", 1, true) ~= nil, "notes; empty note skipped")
check(html:find("<b>Source:</b> https://example.com/chili?a=1&amp;b=&lt;x&gt;", 1, true) and not html:find("<a ", 1, true), "source shown as escaped text, no link")
check(html:find("<b>Categories:</b> Main", 1, true) and html:find("<b>Tags:</b> American, Beef", 1, true), "categories and tags")
check(not html:find("http://", 1, true) and not html:find("src=\"http", 1, true), "page loads nothing from the network")
check(py_stat(WORK .. "/recipes/." .. CHILI .. ".html.part") == nil and py_stat(WORK .. "/recipes/." .. CHILI .. ".webp.part") == nil, "no .part files left")
check(p:get("saved")[CHILI] ~= nil, "recipe recorded as saved")

-- photo edge cases
p:set("prefer_saved", false)
py_set_image("missing")
p:saveRecipe({ id = RIB, name = "Prime Rib Roast" })
check(py_stat(WORK .. "/recipes/" .. RIB .. ".html", "mode") == "file" and not (py_read(WORK .. "/recipes/" .. RIB .. ".html") or ""):find("<img", 1, true), "missing photo: page without <img>")
py_set_image("html")
p:saveRecipe({ id = RIB, name = "Prime Rib Roast" })
check(py_stat(WORK .. "/recipes/" .. RIB .. ".webp") == nil, "non-image response not saved as photo")
py_set_image("huge")
p:saveRecipe({ id = RIB, name = "Prime Rib Roast" })
check(py_stat(WORK .. "/recipes/" .. RIB .. ".webp") == nil and py_stat(WORK .. "/recipes/." .. RIB .. ".webp.part") == nil, "oversized photo discarded, no .part left")
py_set_image("ok")
p:set("show_photos", false)
py_clear_requests()
p:saveRecipe({ id = RIB, name = "Prime Rib Roast" })
check(#reqs() == 1, "photos off: no image request")
p:set("show_photos", true)

-- saved / offline
shown = {}
p:set("prefer_saved", true)
py_clear_requests()
opened = nil
p:openRecipe({ id = CHILI, name = "x" })
check(#reqs() == 0 and opened == page, "prefer saved copy: opens without network")
p:set("prefer_saved", false)
shown = {}
p:showSaved()
check(texts(lastShown()) == "Chili <script>alert(1)</script> & \"beans\"|, Prime Rib Roast|", "saved list: " .. texts(lastShown()))
shown = {}
p:showRecipeActions({ id = RIB, name = "Prime Rib Roast" })
local act = lastShown()
check(act.kind == "buttondialog" and #act.buttons == 4 and act.buttons[2][1].enabled == true, "hold actions")
act.buttons[4][1].callback()
check(py_stat(WORK .. "/recipes/" .. RIB .. ".html") == nil and p:get("saved")[RIB] == nil, "delete saved copy")
p:deleteSaved("../../x")
check(true, "deleteSaved ignores non-UUID")
check(errorText(function() p:saveRecipe({ id = "../../etc/passwd", name = "x" }) end):find("invalid recipe ID"), "non-UUID recipe id rejected before any request")
check(p:savedPath("../../etc/passwd") == nil, "savedPath rejects non-UUID")

-- ---- keep awake while a recipe is open ------------------------------------------------
check(p:isRecipeFile(page) and not p:isRecipeFile(WORK .. "/recipes/notes.html") and not p:isRecipeFile(WORK .. "/other/" .. CHILI .. ".html"), "recipe file detection")
local function readerUi(file) return { document = { file = file }, menu = { registerToMainMenu = function() end }, switchDocument = function(self, f) opened = f end } end
executed = {}; hooks = {}
local rd = Mealie:new{ ui = readerUi(page) }
check(executed[1] == "lipc-set-prop com.lab126.powerd preventScreenSaver 1" and #executed == 1, "Kindle: preventScreenSaver 1 on open")
check(PluginShare.keepalive == true and PluginShare.pause_auto_suspend == true, "AutoSuspend paused and told keepalive is on")
check(p:get("keepawake_active") == true, "keep-awake flag persisted")
check(hooks[1] and hooks[1].name == "InputEvent" and hooks[1].w == rd, "input hook registered")
local task, secs = next(scheduled)
check(task ~= nil and secs == 2 * 3600, "idle check scheduled for the limit: " .. tostring(secs))
clock = clock + 3000; rd:onInputEvent(); clock = clock + 3000
fire(task)
local _t2, secs2 = next(scheduled)
check(KA.active and secs2 == 2 * 3600 - 3000, "a tap extends the limit; recheck in " .. tostring(secs2))
rd:onCloseDocument()
check(executed[2] == "lipc-set-prop com.lab126.powerd preventScreenSaver 0", "Kindle: preventScreenSaver 0 on close")
check(PluginShare.keepalive == nil and PluginShare.pause_auto_suspend == nil and not KA.active, "flags restored")
check(p:get("keepawake_active") == nil and next(scheduled) == nil, "flag cleared, timer cancelled")
rd:onCloseWidget()
check(#executed == 2, "no double release")
-- idle limit
executed = {}
rd = Mealie:new{ ui = readerUi(page) }
clock = clock + 2 * 3600
fire((next(scheduled)))
check(not KA.active and executed[2] == "lipc-set-prop com.lab126.powerd preventScreenSaver 0", "released after the idle limit")
rd:onCloseDocument()
check(#executed == 2, "close after release does nothing more")
-- user had KOReader's own Keep alive on: leave it on
executed = {}
PluginShare.keepalive = true
rd = Mealie:new{ ui = readerUi(page) }
rd:onCloseDocument()
check(#executed == 0 and PluginShare.keepalive == true, "user's Keep alive left untouched")
PluginShare.keepalive = nil
-- setting off
p:set("keep_awake", false)
executed = {}
rd = Mealie:new{ ui = readerUi(page) }
check(#executed == 0 and not KA.active, "keep awake off: nothing changed")
rd:onCloseDocument()
p:set("keep_awake", true)
-- not a recipe
executed = {}
rd = Mealie:new{ ui = readerUi(WORK .. "/home/book.epub") }
check(#executed == 0 and not KA.active, "other documents: nothing changed")
-- crash recovery: flag left set, next start releases it
p:set("keepawake_active", true)
executed = {}
Mealie:new{ ui = fmUi() }
check(executed[1] == "lipc-set-prop com.lab126.powerd preventScreenSaver 0" and p:get("keepawake_active") == nil, "stale keep-awake released on next start")
-- Kobo: no lipc, only pause_auto_suspend
is_kindle = false
executed = {}
rd = Mealie:new{ ui = readerUi(page) }
check(#executed == 0 and PluginShare.pause_auto_suspend == true and PluginShare.keepalive == nil, "non-Kindle: pause only")
rd:onCloseDocument()
check(PluginShare.pause_auto_suspend == nil, "non-Kindle: released")
is_kindle = true

-- ---- return to the list after closing a recipe -----------------------------------------------
local function menuTitles() local t = {}; for _i, w in ipairs(shown) do if w.kind == "menu" then t[#t + 1] = w.title end end; return table.concat(t, " > ") end
p:closeAllMenus()
shown = {}
p:showOrganizer("categories"); sel(lastShown(), findItem(lastShown(), "Main"))
local ml = lastShown()
opened = nil
sel(ml, ml.item_table[1])
LASTFILE = opened
shown = {}
Mealie:new{ ui = fmUi() }
check(menuTitles() == "Mealie recipes > Categories > Main (1)", "restore rebuilds Categories > Main: " .. menuTitles())
check(lastShown().subtitle == "Categories \u{203A} Main", "restored breadcrumb")
shown = {}
Mealie:new{ ui = fmUi() }
check(#shown == 0, "restore happens once")
-- meal plan
shown = {}
p:showMealPlan(); sel(lastShown(), findItem(lastShown(), "Boilermaker Tailgate Chili"))
LASTFILE = opened
shown = {}
Mealie:new{ ui = fmUi() }
check(menuTitles() == "Mealie recipes > Today's meal plan" and lastShown().focus == 2, "meal plan restored with focus")
-- other document read last -> no restore
shown = {}
p:showSaved(); sel(lastShown(), lastShown().item_table[1])
LASTFILE = "/elsewhere.epub"
shown = {}
Mealie:new{ ui = fmUi() }
check(#shown == 0, "no restore when another document was read")
-- setting off
shown = {}
p:showSaved(); sel(lastShown(), lastShown().item_table[1]); LASTFILE = opened
p:set("return_to_list", false)
shown = {}
Mealie:new{ ui = fmUi() }
check(#shown == 0, "return_to_list off")
p:set("return_to_list", true)

-- ---- autostart ------------------------------------------------------------------------------
local marker = WORK .. "/m.autostart"
local function writeMarker(t) local f = io.open(marker, "w"); f:write(tostring(t) .. "\n"); f:close() end
writeMarker(os.time()); check(p:consumeAutostart(marker) == true and io.open(marker, "r") == nil, "fresh marker consumed")
writeMarker(os.time() - 3600); check(p:consumeAutostart(marker) == false and io.open(marker, "r") == nil, "stale marker ignored, removed")
writeMarker("junk"); check(p:consumeAutostart(marker) == false, "malformed marker ignored")
local real = io.open("/tmp/mealie.autostart", "w"); real:write(os.time() .. "\n"); real:close()
shown = {}
Mealie:new{ ui = fmUi() }
check(#shown == 1 and shown[1].title == "Mealie recipes", "scriptlet marker opens the home menu")

-- ---- errors -------------------------------------------------------------------------------
py_set_mode("403"); check(errorText(function() p:showAllRecipes() end):find("403"), "403 message")
py_set_mode("302"); check(errorText(function() p:showAllRecipes() end):find("cloudflareaccess.com", 1, true), "302 shows its target")
py_set_mode("html"); check(errorText(function() p:showAllRecipes() end):find("did not return JSON"), "HTML login page detected")
py_set_mode("huge"); check(errorText(function() p:showAllRecipes() end):find("unexpectedly large"), "oversized JSON refused")
py_set_mode("neterr"); check(errorText(function() p:showAllRecipes() end):find("connection refused"), "network error")
py_set_mode("ok")
p:set("token", "bad"); check(errorText(function() p:showAllRecipes() end):find("401"), "401 message")
check(errorText(function() p:saveRecipe({ id = CHILI, name = "x" }) end):find("401"), "401 on recipe")
p:set("token", "LONGTOKEN")
check(errorText(function() p:saveRecipe({ id = "00000000-0000-4000-8000-0000000000ff", name = "gone" }) end):find("404"), "404 on missing recipe")

-- ---- transport security ---------------------------------------------------------------------
py_clear_requests()
p:showAllRecipes(); p:showMealPlan(); p:saveRecipe({ id = CHILI, name = "x" }); p:showOrganizer("tags"); p:requestToken("kindle", "p&ss word")
local all_ok = #reqs() >= 7
for _i, rq in ipairs(reqs()) do all_ok = all_ok and rq.redirect == false and rq.has_create == true end
check(all_ok, "every request (incl. login and photo): redirect=false and verified TLS create")
local saved_url = p:get("server_url")
p:set("server_url", "http://mealie.example.com")
py_clear_requests()
check(errorText(function() p:showAllRecipes() end):find("Refusing to connect"), "plain http to a public host refused")
check(errorText(function() p:requestToken("kindle", "p&ss word") end) and #reqs() == 0, "nothing sent over refused http (incl. login)")
local tok, terr = p:requestToken("kindle", "p&ss word")
check(tok == nil and terr:find("Refusing"), "login refused over public http")
p:set("server_url", "http://192.168.1.28:9925")
py_clear_requests()
p:showAllRecipes()
check(#reqs() == 1 and reqs()[1].has_create == false, "http to LAN IP allowed (no TLS)")
p:set("server_url", saved_url)
p:set("ca_file", "/nonexistent.pem")
check(errorText(function() p:showAllRecipes() end):find("CA certificate file not found"), "missing CA file refuses")
p:set("ca_file", "")

print(string.format("RESULT pass=%d fail=%d", results.pass, results.fail))
return results.fail
