--[[
Random Quote plugin

A plugin that shows a random quote from a library of
quotes. Quotes are read from `quotes.lua` stored in this plugin
directory (or from a fallback list when missing).

Features:
- Display a random quote in a lightweight `QuoteWidget` that supports
    chunked formatting (per-chunk `text`, `bold`, `italic`, `align`).
- Settings persisted under the `randomquote` namespace:
    - `font_face` (CRE face name)
    - `font_size` (numeric)
    - `book_dir` (path used when extracting highlights)
    - `title_mode` ("default" | "custom" | "none")
    - `title_custom` (custom title text)
- A settings menu under More Tools → Random Quote Options → Random Quote Settings
    lets the user change font, size, book directory, and title text.
- Extract highlighted texts from book metadata into `quotes.lua`.

Implementation notes:
- `QuoteWidget` (quotewidget.lua) consumes a table of chunks and uses
    `TextBoxWidget` for rendering; this plugin asks `Font` for faces and
    attempts to select italic variants using `fontlist` metadata.
- Settings are read and saved via `G_reader_settings`.

Files:
- `main.lua` (this file): plugin entry, menu, settings, extraction logic
- `quotewidget.lua`: lightweight display widget for chunked quotes
- `quotes.lua`: generated or user-provided list of quotes (table)

Defaults:
- Title: "Random Quote from Library"
- Book directory: `/mnt/us/Books`

Usage:
- More Tools → Random Quote Options → Use Debug to preview or Extract
    to scan book metadata and populate `quotes.lua`.

]]


local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local QuoteWidget = require("quotewidget")
local Screen = require("device").screen
local _ = require("gettext")
local Dispatcher = require("dispatcher")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")

-- Use reader's current font as plugin default (fall back to infofont)

-- plugin settings (saved to G_reader_settings under plugin namespace)
local SETTINGS_NS = "randomquote"
local function read_setting(k, def)
    return G_reader_settings:readSetting(SETTINGS_NS .. "." .. k, def)
end
local function write_setting(k, v)
    return G_reader_settings:saveSetting(SETTINGS_NS .. "." .. k, v)
end

local plugin_font_face_name = read_setting("font_face", G_reader_settings:readSetting("cre_font") or "infofont")
local plugin_font_size = tonumber(read_setting("font_size", G_reader_settings:readSetting("copt_font_size") or Font.sizemap.infofont)) or Font.sizemap.infofont
local plugin_book_dir = read_setting("book_dir", "/mnt/us/Books")
local plugin_title_mode = read_setting("title_mode", "default") -- values: "default", "custom", "none"
local plugin_title_custom = read_setting("title_custom", "Random Quote from Library")
local function plugin_get_face()
    -- Try to resolve CRE font face names to actual filename + face index so Font:getFace
    -- can load the intended font. Fall back to using the stored name directly.
    local ok, cre = pcall(function() return require("document/credocument"):engineInit() end)
    if ok and cre and type(cre.getFontFaceFilenameAndFaceIndex) == "function" then
        local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(plugin_font_face_name)
        if font_filename then
            return Font:getFace(font_filename, plugin_font_size, font_faceindex)
        end
    end
    return Font:getFace(plugin_font_face_name, plugin_font_size)
end


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
local function get_title_text()
    if plugin_title_mode == "none" then return nil end
    if plugin_title_mode == "custom" then return plugin_title_custom or "" end
    -- default
    return "Random Quote from Library"
end

-- format a quote entry for display as a table of chunks compatible with QuoteWidget
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
    if type(text) ~= "string" then text = tostring(text) end
    if text:match("^[a-z]") then
        text = "\u{2026} " .. text
    end

    -- assemble chunks
    local chunks = {}
    local title = get_title_text()
    if title and title ~= "" then
        table.insert(chunks, { text = title, bold = true, align = "center" })
        table.insert(chunks, { text = "" })
    end

    -- quote text (wrapped in typographic quotes)
    local quote_text = "\u{201C}" .. text .. "\u{201D}"
    -- todo: italics does not work currently
    table.insert(chunks, { text = quote_text, italic = true, align = "left" })
    table.insert(chunks, { text = "" })

    if book ~= "" then
        table.insert(chunks, { text = book, bold = true, align = "left" })
    end
    if author ~= "" then
        table.insert(chunks, { text = author, bold = true, align = "left" })
    end

    return chunks
end

-- show a random sample using current settings
local function show_sample()
    local msgs = load_quotes()
    if type(msgs) == "table" and #msgs > 0 then
        local sample = msgs[math.random(#msgs)]
        UIManager:show(QuoteWidget:new{ text = format_quote(sample), timeout = 4, face = plugin_get_face() })
    end
end

-- Define plugin (use WidgetContainer like other plugins)
local RandomQuote = WidgetContainer:extend{
    name = "randomquote",
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
    -- group under More Tools
    menu_items.randomquote_group = {
        text = _("Random Quote Options"),
        sorting_hint = "more_tools",
        sub_item_table = {},
    }
    local group = menu_items.randomquote_group.sub_item_table

    -- Extract item
    table.insert(group, {
        text = _("Extract Highlighted Texts"),
        callback = function()
            local info = InfoMessage:new{ text = _("Scanning for highlights…"), timeout = 2 }
            UIManager:show(info)
            -- perform extraction (may take a while); protect with pcall to always show a result
            local ok, res = pcall(RandomQuote.extract_highlights_to_quotes)
            if not ok then
                UIManager:show(InfoMessage:new{ text = string.format(_("Error during extraction: %s"), tostring(res)), timeout = 4 })
                return
            end
            local nb = tonumber(res) or 0
            if nb and nb > 0 then
                if nb == 1 then
                    UIManager:show(InfoMessage:new{ text = _("1 highlight found and saved."), timeout = 3 })
                else
                    UIManager:show(InfoMessage:new{ text = string.format(_("%d highlights found and saved."), nb), timeout = 3 })
                end
            else
                UIManager:show(InfoMessage:new{ text = _("No highlights found."), timeout = 3 })
            end
        end,
    })

    -- Debug: show a random quote immediately
    table.insert(group, {
        text = _("Debug: Show A Random Quote"),
        callback = function()
            RandomQuote:onResume()
        end,
    })

    -- Settings submenu for quote widget customization
    local settings_item = { text = _("Random Quote Settings"), sub_item_table = {} }
    table.insert(group, settings_item)
    -- Title selector (Default / None / Custom)
    table.insert(settings_item.sub_item_table, {
        text_func = function()
            if plugin_title_mode == "none" then
                return string.format("%s: %s", _("Title"), _("None"))
            elseif plugin_title_mode == "custom" then
                return string.format("%s: %s", _("Title"), plugin_title_custom)
            else
                return string.format("%s: %s", _("Title"), _("Random Quote from Library"))
            end
        end,
        sub_item_table = {
            {
                text = _("Default"),
                radio = true,
                checked_func = function() return plugin_title_mode == "default" end,
                callback = function(touchmenu_instance)
                    plugin_title_mode = "default"
                    write_setting("title_mode", "default")
                    if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
                    -- show a sample when title changes
                    show_sample()
                end,
            },
            {
                text = _("None"),
                radio = true,
                checked_func = function() return plugin_title_mode == "none" end,
                callback = function(touchmenu_instance)
                    plugin_title_mode = "none"
                    write_setting("title_mode", "none")
                    if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
                    -- show a sample when title changes
                    show_sample()
                end,
            },
            {
                text = _("Custom..."),
                callback = function(touchmenu_instance)
                    local MultiInputDialog = require("ui/widget/multiinputdialog")
                    local dlg
                    dlg = MultiInputDialog:new{
                        title = _("Custom Title"),
                        fields = { { text = plugin_title_custom or "", hint = _("Title") } },
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    callback = function() UIManager:close(dlg) end,
                                },
                                {
                                    text = _("OK"),
                                    callback = function()
                                        local fields = dlg:getFields()
                                        local txt = fields[1] or ""
                                        plugin_title_custom = txt
                                        plugin_title_mode = "custom"
                                        write_setting("title_custom", plugin_title_custom)
                                        write_setting("title_mode", "custom")
                                        UIManager:close(dlg)
                                        if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
                                        -- show a sample when title changes
                                        show_sample()
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
        },
    })

    -- font face selector (cycle through a short list)
    local faces = { "infofont", "smallinfofont", "cfont", "ffont" }
        -- font face selector: open submenu listing all available faces
        table.insert(settings_item.sub_item_table, {
            text_func = function() return string.format("%s: %s", _("Font"), plugin_font_face_name) end,
            sub_item_table_func = function()
                local subs = {}
                local FontList = require("fontlist")
                local cre = require("document/credocument"):engineInit()
                local face_list = cre.getFontFaces()
                for _, v in ipairs(face_list) do
                    local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(v)
                    local label = FontList:getLocalizedFontName(font_filename, font_faceindex) or v
                    table.insert(subs, {
                        text = label,
                        font_func = function(size)
                            if font_filename and font_faceindex then
                                return Font:getFace(font_filename, size, font_faceindex)
                            end
                        end,
                        callback = function()
                            plugin_font_face_name = v
                            write_setting("font_face", plugin_font_face_name)
                            -- show a sample with new font
                            show_sample()
                        end,
                        radio = true,
                        checked_func = function() return plugin_font_face_name == v end,
                        menu_item_id = v,
                    })
                end
                return subs
            end,
        })
    -- font size selector (cycle common sizes)
    local sizes = { 12, 14, 16, 18, 20 }
        -- font size selector: submenu of common sizes
        local sizes = { 10, 12, 14, 16, 18, 20, 24 }
        table.insert(settings_item.sub_item_table, {
            text_func = function() return string.format("%s: %d", _("Font size"), plugin_font_size) end,
            sub_item_table = (function()
                local s = {}
                for _, v in ipairs(sizes) do
                    table.insert(s, {
                        text = tostring(v),
                        callback = function()
                            plugin_font_size = v
                            write_setting("font_size", plugin_font_size)
                            -- show a sample with new size
                            show_sample()
                        end,
                        radio = true,
                        checked_func = function() return plugin_font_size == v end,
                    })
                end
                return s
            end)(),
        })
    table.insert(settings_item.sub_item_table, {
            text_func = function() return string.format("%s: %s", _("Book dir"), plugin_book_dir) end,
            callback = function(touchmenu_instance)
                local PathChooser = require("ui/widget/pathchooser")
                local old_path = plugin_book_dir
                UIManager:show(PathChooser:new{
                    select_directory = true,
                    select_file = false,
                    height = Screen:getHeight(),
                    path = old_path,
                    onConfirm = function(dir_path)
                        if dir_path and dir_path:sub(-1) ~= "/" then dir_path = dir_path .. "/" end
                        plugin_book_dir = dir_path
                        write_setting("book_dir", plugin_book_dir)
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        })
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
    UIManager:show(QuoteWidget:new{ text = display_text, face = plugin_get_face() })
end


-- Utility: scan book folders for .sdr metadata files and extract quoted strings
function RandomQuote.extract_highlights_to_quotes()
    local books_dirs = { plugin_book_dir }
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

    -- We'll detect any metadata.*.lua (or backup *.lua.old) file inside the
    -- book sidecar folder rather than relying on a single hardcoded name.
    local metadata_pattern = "^metadata%..+%.lua"

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
            UIManager:show(InfoMessage:new{ text = string.format(_("Scanning: %s"), entry), timeout = 2 })
            local bpath = books_dir .. "/" .. entry
            if lfs.attributes(bpath, "mode") == "directory" then
                for m in lfs.dir(bpath) do
                    if m and m:match(metadata_pattern) then
                        local mp = bpath .. "/" .. m
                        if lfs.attributes(mp, "mode") == "file" then
                        -- Prefer loading the metadata Lua file and reading its table
                        local ok, t = pcall(function()
                            local fn, err = loadfile(mp)
                            if not fn then error(err) end
                            return fn()
                        end)
                        if ok and type(t) == "table" and type(t.annotations) == "table" then
                            -- obtain and normalize book and author from metadata
                            local book = nil
                            local author = nil
                            local function normalize_authors(a)
                                if not a then return nil end
                                if type(a) == "string" then
                                    return a
                                elseif type(a) == "table" then
                                    -- join array of authors
                                    local parts = {}
                                    for _, v in ipairs(a) do
                                        if type(v) == "string" and v:match("%S") then table.insert(parts, v) end
                                    end
                                    if #parts > 0 then return table.concat(parts, ", ") end
                                end
                                return nil
                            end

                            if type(t.doc_props) == "table" then
                                if type(t.doc_props.title) == "string" and t.doc_props.title:match("%S") then
                                    book = t.doc_props.title
                                end
                                author = normalize_authors(t.doc_props.authors)
                            end
                            if (not book or book == "") and type(t.stats) == "table" then
                                if type(t.stats.title) == "string" and t.stats.title:match("%S") then book = t.stats.title end
                            end
                            if (not author or author == "") and type(t.stats) == "table" then
                                author = normalize_authors(t.stats.authors)
                            end
                            -- fallback: derive a readable book name from the .sdr folder name
                            if (not book or book == "") and type(entry) == "string" then
                                local derived = entry:gsub("%.sdr$", "")
                                derived = derived:gsub("[_%-]+", " ")
                                derived = derived:gsub("^%s*(.-)%s*$", "%1")
                                if derived:match("%S") then book = derived end
                            end

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
