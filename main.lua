local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local Dispatcher = require("dispatcher")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")

-- Create EB Garamond face from bundled fonts folder. Falls back silently if missing.
local EB_GARAMOND_FACE = Font:getFace("EBGaramond-VariableFont_wght.ttf", Font.sizemap.infofont)

-- helper to load quotes from quotes.lua in this plugin directory
local function load_quotes()
    -- load quotes.lua from this plugin directory explicitly (avoid global require path issues)
    local source = debug.getinfo(1, "S").source
    local plugin_dir = ""
    if source:sub(1,1) == "@" then
        local this_path = source:sub(2)
        plugin_dir = this_path:match("(.*/)") or ""
    end
    local quotes_path = plugin_dir .. "quotes.lua"
    if quotes_path ~= "quotes.lua" then
        local ok, t = pcall(function()
            local fn, err = loadfile(quotes_path)
            if not fn then error(err) end
            return fn()
        end)
        if ok and type(t) == "table" and #t > 0 then
            return t
        end
    end
    -- fallback defaults
    return { _("Hello, reader!"), _("Stay focused"), _("Time to read!"), _("Random wisdom incoming..."), _("Enjoy the moment") }
end

-- format a quote entry for display; supports either string or {text,book,author}
local function format_quote(entry)
    local text, book, author
    if type(entry) == "string" then
        text = entry
        book = ""
        author = ""
    elseif type(entry) == "table" then
        text = tostring(entry.text or "")
        book = tostring(entry.book or "")
        author = tostring(entry.author or "")
    else
        text = tostring(entry)
        book = ""
        author = ""
    end
    if text == "" then text = _("(empty)") end
    -- add ellipsis if starting with lowercase letter
    if type(text) ~= "string" then text = tostring(text) end
    if text:match("^[a-z]") then
        text = "\u{2026} " .. text
    end
    local out = "\u{201C}" .. text .. "\u{201D}"
    if book ~= "" or author ~= "" then
        out = out .. "\n\n" .. book .. "\n" .. author
    end
    return out
end

-- Define plugin (use WidgetContainer like other plugins)
local RandomQuote = WidgetContainer:extend{
    name = "my_random_quote",
    is_doc_only = false,
}

function RandomQuote:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function RandomQuote:onDispatcherRegisterActions()
    Dispatcher:registerAction("randomquote_extract_highlights", {category="none", event="RandomQuote.ExtractHighlights", title=_("Extract highlights"), general=true,})
end

-- Add menu item to main menu
function RandomQuote:addToMainMenu(menu_items)
    menu_items.randomquote_extract = {
        text = _("Extract highlighted Texts"),
        sorting_hint = "more_tools",
        callback = function()
            local info = InfoMessage:new{ text = _("Scanning for highlights…"), fontface = EB_GARAMOND_FACE }
            UIManager:show(info)
            -- perform extraction (may take a while); protect with pcall to always show a result
            local ok, res = pcall(RandomQuote.extract_highlights_to_quotes)
            if not ok then
                UIManager:show(InfoMessage:new{ text = string.format(_("Error during extraction: %s"), tostring(res)), timeout = 4, fontface = EB_GARAMOND_FACE })
                return
            end
            local nb = tonumber(res) or 0
            if nb and nb > 0 then
                if nb == 1 then
                    UIManager:show(InfoMessage:new{ text = _("1 highlight found and saved."), timeout = 3, fontface = EB_GARAMOND_FACE })
                else
                    UIManager:show(InfoMessage:new{ text = string.format(_("%d highlights found and saved."), nb), timeout = 3, fontface = EB_GARAMOND_FACE })
                end
                -- show a sample of the newly saved quotes immediately
                local msgs = load_quotes()
                if type(msgs) == "table" and #msgs > 0 then
                    local sample = msgs[math.random(#msgs)]
                    UIManager:show(InfoMessage:new{ text = format_quote(sample), timeout = 4, fontface = EB_GARAMOND_FACE })
                end
            else
                UIManager:show(InfoMessage:new{ text = _("No highlights found."), timeout = 3, fontface = EB_GARAMOND_FACE })
            end
        end,
    }
    -- Debug: show a random quote immediately
    menu_items.randomquote_show = {
        text = _("Debug: Show A Random Quote"),
        sorting_hint = "more_tools",
        callback = function()
            -- reuse onResume behavior to display a random quote
            RandomQuote:onResume()
        end,
    }
end

-- Called when device wakes from lock or focus resumes
function RandomQuote:onResume()
    -- seed once with time plus an increment to avoid identical seeds on quick resumes
    math.randomseed((os.time() or 0) + (tostring({}):len() or 0))

    local messages = load_quotes()
    -- pick a random entry and format for display
    if type(messages) ~= "table" or #messages == 0 then
        return
    end
    local entry = messages[math.random(#messages)]
    local display_text = format_quote(entry)
    UIManager:show(InfoMessage:new{ text = display_text, fontface = EB_GARAMOND_FACE })
end


-- Utility: scan book folders for .sdr metadata files and extract quoted strings
function RandomQuote.extract_highlights_to_quotes()
    local books_dirs = { "/mnt/us/Books"}
    local found = {}
    local seen = {}

    local function accept(s)
        if not s then return false end
        s = s:gsub("\n", " ")
        s = s:match("^%s*(.-)%s*$") or s
        if #s < 20 then return false end
        if s:match("^") then end
        if s:match("/") or s:match("\\\\") then return false end
        if s:match("^%s*$") then return false end
        return true
    end

    local metadata_names = {"metadata.epub.lua.old"}

    local books_dir = nil
    for _, d in ipairs(books_dirs) do
        if lfs.attributes(d, "mode") == "directory" then
            books_dir = d
            break
        end
    end
    if not books_dir then
        return 0
    end

    for entry in lfs.dir(books_dir) do
        if entry and entry:match("%.sdr$") then
            -- debug: show current folder being scanned
            UIManager:show(InfoMessage:new{ text = string.format(_("Scanning: %s"), entry), timeout = 1, fontface = EB_GARAMOND_FACE })
            local bpath = books_dir .. "/" .. entry
            if lfs.attributes(bpath, "mode") == "directory" then
                for _, m in ipairs(metadata_names) do
                    local mp = bpath .. "/" .. m
                    if lfs.attributes(mp, "mode") == "file" then
                        -- Prefer loading the metadata Lua file and reading its table
                        local ok, t = pcall(function()
                            local fn, err = loadfile(mp)
                            if not fn then error(err) end
                            return fn()
                        end)
                        if ok and type(t) == "table" and type(t.annotations) == "table" then
                            -- obtain book and author from metadata
                            local book = nil
                            local author = nil
                            if type(t.doc_props) == "table" then
                                book = t.doc_props.title or book
                                author = t.doc_props.authors or author
                            end
                            if not book and type(t.stats) == "table" then book = t.stats.title end
                            if not author and type(t.doc_props) ~= "table" and type(t.stats) == "table" then author = t.stats.authors end
                            for _, ann in pairs(t.annotations) do
                                if type(ann) == "table" then
                                    local txt = ann.text or ann.note
                                    if type(txt) == "string" and accept(txt) then
                                        local key = txt .. "\x1f" .. tostring(book or "") .. "\x1f" .. tostring(author or "")
                                        if not seen[key] then
                                            seen[key] = true
                                            table.insert(found, { text = txt, book = book or "", author = author or "" })
                                        end
                                    end
                                end
                            end
                        else
                            -- fallback: read raw file and extract quoted strings
                            local fh = io.open(mp, "r")
                            if fh then
                                local content = fh:read("*a") or ""
                                fh:close()
                                for s in content:gmatch('"([^"]+)"') do
                                    if accept(s) then
                                        local key = s .. "\x1f" .. "" .. "\x1f" .. ""
                                        if not seen[key] then
                                            seen[key] = true
                                            table.insert(found, { text = s, book = "", author = "" })
                                        end
                                    end
                                end
                                for s in content:gmatch("'([^']+)'") do
                                    if accept(s) then
                                        local key = s .. "\x1f" .. "" .. "\x1f" .. ""
                                        if not seen[key] then
                                            seen[key] = true
                                            table.insert(found, { text = s, book = "", author = "" })
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- write quotes.lua in plugin directory
    local source = debug.getinfo(1, "S").source
    if source:sub(1,1) == "@" then
        local this_path = source:sub(2)
        local plugin_dir = this_path:match("(.*/)") or ""
        local quotes_path = plugin_dir .. "quotes.lua"
        local fh = io.open(quotes_path, "w")
        if fh then
            fh:write("-- autogenerated by randomquote plugin\n")
            fh:write("local quotes = {\n")
            for _, q in ipairs(found) do
                local text = tostring(q.text or "")
                local book = tostring(q.book or "")
                local author = tostring(q.author or "")
                local esc_text = text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n")
                local esc_book = book:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n")
                local esc_author = author:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n")
                fh:write('    { text = "' .. esc_text .. '", book = "' .. esc_book .. '", author = "' .. esc_author .. '" },\n')
            end
            fh:write("}\n\nreturn quotes\n")
            fh:close()
            -- clear require cache for quotes module so subsequent require() picks updated file
            package.loaded["quotes"] = nil
        end
    end

    return #found
end

return RandomQuote
