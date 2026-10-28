--[[
Turns a Mealie recipe (the JSON from GET /api/recipes/<id>) into a small,
self-contained HTML page for KOReader's reader.

Every value from the server is HTML-escaped. Nothing in the page refers to the
network: the only <img> points at a local file name chosen by the plugin.
--]]

local M = {}

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }

function M.escape(s)
    if s == nil then
        return ""
    end
    return (tostring(s):gsub("[&<>\"']", ESCAPES))
end

local function str(v)
    if type(v) == "string" then
        return v
    end
    if type(v) == "number" then
        return tostring(v)
    end
    return nil
end

local function nonEmpty(v)
    v = str(v)
    if v and v:match("%S") then
        return v
    end
    return nil
end

local function list(v)
    return type(v) == "table" and v or {}
end

-- Escaped text with light formatting: **bold**, blank line = new paragraph,
-- single newline = line break. Mealie stores steps and notes as Markdown;
-- anything beyond this is shown as plain text.
function M.formatText(s)
    s = nonEmpty(s)
    if not s then
        return ""
    end
    s = s:gsub("\r\n?", "\n")
    local paras = {}
    for block in (s .. "\n\n"):gmatch("(.-)\n%s*\n") do
        if block:match("%S") then
            local html = M.escape(block):gsub("%*%*(.-)%*%*", "<b>%1</b>"):gsub("\n", "<br/>")
            paras[#paras + 1] = "<p>" .. html .. "</p>"
        end
    end
    return table.concat(paras, "\n")
end

local function fmtNumber(n)
    n = tonumber(n)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    if n == math.floor(n) then
        return string.format("%d", n)
    end
    local whole = math.floor(n)
    local frac = n - whole
    local fractions = { { 0.25, "\u{BC}" }, { 0.5, "\u{BD}" }, { 0.75, "\u{BE}" },
                        { 1 / 3, "\u{2153}" }, { 2 / 3, "\u{2154}" }, { 0.125, "\u{215B}" } }
    for _i, f in ipairs(fractions) do
        if math.abs(frac - f[1]) < 0.01 then
            return (whole > 0 and tostring(whole) or "") .. f[2]
        end
    end
    return (string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", ""))
end
M.fmtNumber = fmtNumber

local function nameOf(obj)
    if type(obj) ~= "table" then
        return nil
    end
    return nonEmpty(obj.name)
end

-- One ingredient line. Mealie computes `display` for every ingredient
-- (quantity, unit, food and note); fall back to the original text, then to
-- composing it from the parsed parts.
function M.ingredientText(ing)
    if type(ing) ~= "table" then
        return ""
    end
    local display = nonEmpty(ing.display)
    if display then
        return display
    end
    local original = nonEmpty(ing.originalText or ing.original_text)
    if original then
        return original
    end
    local parts = {}
    local qty = tonumber(ing.quantity)
    if qty and qty > 0 then
        parts[#parts + 1] = fmtNumber(qty)
    end
    parts[#parts + 1] = nameOf(ing.unit)
    parts[#parts + 1] = nameOf(ing.food)
    local note = nonEmpty(ing.note)
    local text = table.concat(parts, " ")
    if note then
        text = text ~= "" and (text .. ", " .. note) or note
    end
    return text
end

local function timeRow(label, value)
    value = nonEmpty(value)
    if not value then
        return nil
    end
    return "<b>" .. M.escape(label) .. ":</b>&#160;" .. M.escape(value)
end

M.CSS = [[
body { line-height: 1.35; margin: 0; }
h1 { font-size: 1.5em; margin: 0 0 0.3em 0; text-align: left; }
h2 { font-size: 1.25em; margin: 1em 0 0.3em 0; border-bottom: 1px solid black; page-break-after: avoid; }
h3 { font-size: 1.05em; margin: 0.8em 0 0.2em 0; page-break-after: avoid; }
p { margin: 0.3em 0; text-indent: 0; text-align: left; }
.desc { font-style: italic; }
.meta { margin: 0.5em 0; }
.photo { text-align: center; margin: 0.6em 0; }
.photo img { max-width: 100%; max-height: 40%; }
ul.ing { margin: 0.2em 0 0.2em 1.2em; padding: 0; }
ul.ing li { margin: 0.25em 0; }
.step { margin: 0.7em 0; }
.stepnum { font-weight: bold; }
.small { font-size: 0.85em; }
]]

-- opts.title (fallback), opts.image (local file name or nil), opts.servings_note
function M.recipeHtml(recipe, opts)
    opts = opts or {}
    local out = {}
    local function add(s)
        out[#out + 1] = s
    end
    local name = nonEmpty(recipe.name) or opts.title or "Recipe"
    add('<!DOCTYPE html>')
    add('<html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>')
    add("<title>" .. M.escape(name) .. "</title><style>" .. M.CSS .. "</style></head><body>")
    add("<h1>" .. M.escape(name) .. "</h1>")

    local desc = nonEmpty(recipe.description)
    if desc then
        add('<div class="desc">' .. M.formatText(desc) .. "</div>")
    end

    local meta = {}
    meta[#meta + 1] = timeRow("Total", recipe.totalTime)
    meta[#meta + 1] = timeRow("Prep", recipe.prepTime)
    meta[#meta + 1] = timeRow("Cook", recipe.performTime or recipe.cookTime)
    local servings = tonumber(recipe.recipeServings)
    if servings and servings > 0 then
        meta[#meta + 1] = "<b>Serves:</b>&#160;" .. M.escape(fmtNumber(servings))
    end
    local yield = nonEmpty(recipe.recipeYield)
    if yield then
        meta[#meta + 1] = "<b>Yield:</b>&#160;" .. M.escape(yield)
    end
    if #meta > 0 then
        add('<p class="meta">' .. table.concat(meta, " &#160;\u{B7}&#160; ") .. "</p>")
    end

    if opts.image then
        add('<div class="photo"><img src="' .. M.escape(opts.image) .. '" alt=""/></div>')
    end

    local ingredients = list(recipe.recipeIngredient)
    if #ingredients > 0 then
        add("<h2>Ingredients</h2>")
        local open = false
        for _i, ing in ipairs(ingredients) do
            local title = type(ing) == "table" and nonEmpty(ing.title)
            if title then
                if open then
                    add("</ul>")
                    open = false
                end
                add("<h3>" .. M.escape(title) .. "</h3>")
            end
            local text = M.ingredientText(ing)
            if text ~= "" then
                if not open then
                    add('<ul class="ing">')
                    open = true
                end
                add("<li>" .. M.escape(text) .. "</li>")
            end
        end
        if open then
            add("</ul>")
        end
    end

    local steps = list(recipe.recipeInstructions)
    if #steps > 0 then
        add("<h2>Instructions</h2>")
        local n = 0
        for _i, step in ipairs(steps) do
            if type(step) == "table" then
                local title = nonEmpty(step.title)
                if title then
                    add("<h3>" .. M.escape(title) .. "</h3>")
                end
                local text = nonEmpty(step.text)
                local summary = nonEmpty(step.summary)
                if text or summary then
                    n = n + 1
                    add('<div class="step"><p class="stepnum">Step ' .. n
                        .. (summary and (": " .. M.escape(summary)) or "") .. "</p>"
                        .. M.formatText(text) .. "</div>")
                end
            end
        end
    end

    local notes = list(recipe.notes)
    local has_notes = false
    for _i, note in ipairs(notes) do
        if type(note) == "table" and (nonEmpty(note.title) or nonEmpty(note.text)) then
            if not has_notes then
                add("<h2>Notes</h2>")
                has_notes = true
            end
            if nonEmpty(note.title) then
                add("<h3>" .. M.escape(note.title) .. "</h3>")
            end
            add(M.formatText(note.text))
        end
    end

    local function names(v)
        local t = {}
        for _i, o in ipairs(list(v)) do
            t[#t + 1] = nameOf(o)
        end
        return t
    end
    local cats, tags = names(recipe.recipeCategory), names(recipe.tags)
    local footer = {}
    if #cats > 0 then
        footer[#footer + 1] = "<b>Categories:</b> " .. M.escape(table.concat(cats, ", "))
    end
    if #tags > 0 then
        footer[#footer + 1] = "<b>Tags:</b> " .. M.escape(table.concat(tags, ", "))
    end
    -- Shown as text, not a link: there is no usable browser to send it to.
    local source = nonEmpty(recipe.orgURL)
    if source then
        footer[#footer + 1] = "<b>Source:</b> " .. M.escape(source)
    end
    if opts.saved_at then
        footer[#footer + 1] = "Saved from Mealie " .. M.escape(opts.saved_at)
    end
    if #footer > 0 then
        add('<h2>About</h2><p class="small">' .. table.concat(footer, "<br/>") .. "</p>")
    end
    add("</body></html>")
    return table.concat(out, "\n")
end

return M
