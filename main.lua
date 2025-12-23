-- SPDX-License-Identifier: AGPL-3.0-or-later

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
local gettext = require("gettext")
local Dispatcher = require("dispatcher")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Scan = require("scan")

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
-- Advanced extraction settings
local plugin_auto_extract = read_setting("auto_extract_enabled", false)
local plugin_auto_extract_interval_days = tonumber(read_setting("auto_extract_interval_days", 1)) or 1
local plugin_extract_colors = read_setting("extract_colors", nil) -- nil = all
local plugin_italicize_quote = read_setting("italicize_quote", false)
local plugin_last_extract_time = tonumber(read_setting("last_extract_time", 0)) or 0
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
    return { gettext("Hello, reader!"), gettext("Stay focused"), gettext("Time to read!"), gettext("Random wisdom incoming..."), gettext("Enjoy the moment") }
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
    if text == "" then text = gettext("(empty)") end
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
    -- italicize only when enabled in settings
    table.insert(chunks, { text = quote_text, italic = plugin_italicize_quote, align = "left" })
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
    Dispatcher:registerAction("randomquote_extract_highlights", {category="none", event="RandomQuote.ExtractHighlights", title=gettext("Extract highlights"), general=true,})
end

-- Add menu item to main menu
function RandomQuote:addToMainMenu(menu_items)
    -- group under More Tools
    menu_items.randomquote_group = {
        text = gettext("Random Quote Options"),
        sorting_hint = "more_tools",
        sub_item_table = {},
    }
    local group = menu_items.randomquote_group.sub_item_table

    -- Extract item
    table.insert(group, {
        text = gettext("Extract Highlighted Texts"),
        callback = function()
            local info = InfoMessage:new{ text = gettext("Scanning for highlights…"), timeout = 2 }
            UIManager:show(info)
            -- perform extraction (may take a while); protect with pcall to always show a result
            local ok, res = pcall(RandomQuote.extract_highlights_to_quotes)
            if not ok then
                UIManager:show(InfoMessage:new{ text = string.format(gettext("Error during extraction: %s"), tostring(res)), timeout = 4 })
                return
            end
            local nb = tonumber(res) or 0
            if nb and nb > 0 then
                if nb == 1 then
                    UIManager:show(InfoMessage:new{ text = gettext("1 highlight found and saved."), timeout = 3 })
                else
                    UIManager:show(InfoMessage:new{ text = string.format(gettext("%d highlights found and saved."), nb), timeout = 3 })
                end
            else
                UIManager:show(InfoMessage:new{ text = gettext("No highlights found."), timeout = 3 })
            end
        end,
    })

    -- Debug: show a random quote immediately
    table.insert(group, {
        text = gettext("Debug: Show A Random Quote"),
        callback = function()
            RandomQuote:onResume()
        end,
    })

    -- Settings submenu for quote widget customization
    local settings_item = { text = gettext("Random Quote Settings"), sub_item_table = {} }
    table.insert(group, settings_item)
    
    -- Title selector (Default / None / Custom)
    table.insert(settings_item.sub_item_table, {
        text_func = function()
            if plugin_title_mode == "none" then
                return string.format("%s: %s", gettext("Title"), gettext("None"))
            elseif plugin_title_mode == "custom" then
                return string.format("%s: %s", gettext("Title"), plugin_title_custom)
            else
                return string.format("%s: %s", gettext("Title"), gettext("Random Quote from Library"))
            end
        end,
        sub_item_table = {
            {
                text = gettext("Default"),
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
                text = gettext("None"),
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
                text = gettext("Custom..."),
                callback = function(touchmenu_instance)
                    local MultiInputDialog = require("ui/widget/multiinputdialog")
                    local dlg
                    dlg = MultiInputDialog:new{
                        title = gettext("Custom Title"),
                        fields = { { text = plugin_title_custom or "", hint = gettext("Title") } },
                        buttons = {
                            {
                                {
                                    text = gettext("Cancel"),
                                    callback = function() UIManager:close(dlg) end,
                                },
                                {
                                    text = gettext("OK"),
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
            text_func = function() return string.format("%s: %s", gettext("Font"), plugin_font_face_name) end,
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
            text_func = function() return string.format("%s: %d", gettext("Font size"), plugin_font_size) end,
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

    -- Italicize quote toggle (CURRENTLY NOT WORKING)

    -- table.insert(settings_item.sub_item_table, {
    --         text_func = function() return string.format("%s: %s", gettext("Italicize Quote"), plugin_italicize_quote and gettext("On") or gettext("Off")) end,
    --         checked_func = function() return plugin_italicize_quote end,
    --         callback = function()
    --             plugin_italicize_quote = not plugin_italicize_quote
    --             write_setting("italicize_quote", plugin_italicize_quote)
    --             show_sample()
    --         end,
    --     })

    table.insert(settings_item.sub_item_table, {
            text_func = function() return string.format("%s: %s", gettext("Book dir"), plugin_book_dir) end,
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
    -- Advanced Settings (inserted at the end of Random Quote Settings)
    do
        local advanced_item = { text = gettext("Advanced Settings"), sub_item_table = {} }
        table.insert(settings_item.sub_item_table, advanced_item)
        -- Automatic extraction toggle
        table.insert(advanced_item.sub_item_table, {
            text = gettext("Automatic Highlight Extraction"),
            sub_item_table = {
                {
                    text = gettext("Enable Automatic Extraction"),
                    checked_func = function() return plugin_auto_extract end,
                    callback = function()
                        plugin_auto_extract = not plugin_auto_extract
                        write_setting("auto_extract_enabled", plugin_auto_extract)
                    end,
                },
                {
                    text_func = function() return string.format("%s: %d %s", gettext("Interval"), plugin_auto_extract_interval_days, gettext("days")) end,
                    sub_item_table = (function()
                        local opts = {1, 7, 14, 30}
                        local s = {}
                        for _, v in ipairs(opts) do
                            table.insert(s, {
                                text = tostring(v) .. " " .. gettext("days"),
                                radio = true,
                                checked_func = function() return plugin_auto_extract_interval_days == v end,
                                callback = function(touchmenu_instance)
                                    plugin_auto_extract_interval_days = v
                                    write_setting("auto_extract_interval_days", plugin_auto_extract_interval_days)
                                    if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
                                end,
                            })
                        end
                        return s
                    end)(),
                },
            },
        })
        -- Highlight color selection (import from reader highlight module when possible)
        local all_colors = nil
        do
            local ok, RH = pcall(require, "apps/reader/modules/readerhighlight")
            if ok and RH and type(RH.highlight_colors) == "table" then
                all_colors = {}
                for _, v in ipairs(RH.highlight_colors) do table.insert(all_colors, { v[1], v[2] }) end
            end
        end
        if not all_colors then
            all_colors = { {gettext("Red"), "red"}, {gettext("Orange"), "orange"}, {gettext("Yellow"), "yellow"}, {gettext("Green"), "green"}, {gettext("Olive"), "olive"}, {gettext("Cyan"), "cyan"}, {gettext("Blue"), "blue"}, {gettext("Purple"), "purple"}, {gettext("Gray"), "gray"} }
        end
        local function is_color_selected(col)
            if not plugin_extract_colors then return true end
            for _, v in ipairs(plugin_extract_colors) do if v == col then return true end end
            return false
        end
        local function toggle_color(col)
            if not plugin_extract_colors then
                plugin_extract_colors = {}
                for _, v in ipairs(all_colors) do table.insert(plugin_extract_colors, v[2]) end
            end
            local found = false
            for i, v in ipairs(plugin_extract_colors) do
                if v == col then table.remove(plugin_extract_colors, i); found = true; break end
            end
            if not found then table.insert(plugin_extract_colors, col) end
            write_setting("extract_colors", plugin_extract_colors)
        end
        local color_subs = {}
        table.insert(color_subs, {
            text = gettext("Select all colors"),
            checked_func = function() return plugin_extract_colors == nil end,
            callback = function()
                plugin_extract_colors = nil
                write_setting("extract_colors", nil)
            end,
        })
        for _, v in ipairs(all_colors) do
            table.insert(color_subs, {
                text = v[1],
                checked_func = function() return is_color_selected(v[2]) end,
                callback = function() toggle_color(v[2]) end,
            })
        end
        table.insert(advanced_item.sub_item_table, {
            text = gettext("Set Highlight Color to Extract"),
            sub_item_table = color_subs,
        })
    end
end

-- Called when device wakes from lock or focus resumes
function RandomQuote:onResume()
    -- seed once with time plus an increment to avoid identical seeds on quick resumes
    math.randomseed((os.time() or 0) + (tostring({}):len() or 0))

    -- Automatic extraction if enabled and interval elapsed
    if plugin_auto_extract then
        local now = os.time() or 0
        local elapsed = now - (plugin_last_extract_time or 0)
        if elapsed >= (plugin_auto_extract_interval_days or 1) * 24 * 3600 then
            pcall(function()
                local nb = RandomQuote.extract_highlights_to_quotes()
                -- ignore nb here; user can manually extract too
                plugin_last_extract_time = os.time()
                write_setting("last_extract_time", plugin_last_extract_time)
            end)
        end
    end

    local messages = load_quotes()
    -- pick a random entry and format for display
    if type(messages) ~= "table" or #messages == 0 then
        return
    end
    local entry = messages[math.random(#messages)]
    local display_text = format_quote(entry)
    UIManager:show(QuoteWidget:new{ text = display_text, face = plugin_get_face() })
end


-- Utility: wrapper that delegates scanning to scan.lua and writes the quotes file
function RandomQuote.extract_highlights_to_quotes()
    local books_dir = plugin_book_dir
    if not books_dir or lfs.attributes(books_dir, "mode") ~= "directory" then
        return 0
    end

    local colors = plugin_extract_colors -- nil means all
    local found = {}
    local ok, res = pcall(function()
        found = Scan.extract_highlights(books_dir, { max_depth = 5, colors = colors })
    end)
    if not ok then return 0 end

    -- write quotes.lua in plugin directory
    local source = debug.getinfo(1, "S").source
    if source:sub(1,1) == "@" then
        local this_path = source:sub(2)
        local plugin_dir = this_path:match("(.*/)" ) or ""
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
            package.loaded["quotes"] = nil
        end
    end

    -- save last extract time
    plugin_last_extract_time = os.time()
    write_setting("last_extract_time", plugin_last_extract_time)

    return #found
end

return RandomQuote
