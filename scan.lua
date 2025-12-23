-- SPDX-License-Identifier: AGPL-3.0-or-later

local lfs = require("libs/libkoreader-lfs")
local DocSettings = require("docsettings")
local logger = require("logger")

local Scan = {}

local function accept(s)
    if not s then return false end
    s = s:gsub("\n", " ")
    s = s:match("^%s*(.-)%s*$") or s
    if #s < 20 then return false end
    if s:match("/") or s:match("\\\\") then return false end
    if s:match("^%s*$") then return false end
    return true
end

local function table_contains(t, v)
    if not t then return false end
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end

-- Recursively scan `root_dir` for files up to `max_depth` deep (default 5).
-- For each file found, attempt to open doc settings and extract annotations.
-- options: { colors = table or nil }
function Scan.extract_highlights(root_dir, options)
    options = options or {}
    local max_depth = options.max_depth or 5
    local colors = options.colors -- nil or table of allowed color names

    local found = {}
    local seen = {}

    local function handle_doc(path)
        if not path or path == "" then return end
        -- Open doc settings (will return object even if no sidecar; data may be empty)
        local ok, doc_settings = pcall(DocSettings.open, DocSettings, path)
        if not ok or not doc_settings or type(doc_settings.data) ~= "table" then return end
        local t = doc_settings.data
        if type(t.annotations) ~= "table" then return end
        local book = nil
        local author = nil
        if type(t.doc_props) == "table" then
            book = t.doc_props.title
            author = t.doc_props.authors
        end
        if (not book or book == "") and type(t.stats) == "table" then
            book = t.stats.title
            author = author or t.stats.authors
        end
        for _, ann in pairs(t.annotations) do
            if type(ann) == "table" then
                local txt = ann.text or ann.note
                if type(txt) == "string" and accept(txt) then
                    -- color filtering
                    if colors and type(colors) == "table" and #colors > 0 then
                        local acol = ann.color or ann.drawer or ""
                        if not table_contains(colors, acol) then goto continue end
                    end
                    local key = txt .. "\x1f" .. tostring(book or "") .. "\x1f" .. tostring(author or "")
                    if not seen[key] then
                        seen[key] = true
                        table.insert(found, { text = txt, book = book or "", author = author or "" })
                    end
                end
            end
            ::continue::
        end
    end

    local function recurse(dir, depth)
        if depth > max_depth then return end
        local ok, mode = pcall(lfs.attributes, dir, "mode")
        if not ok or mode ~= "directory" then return end
        for entry in lfs.dir(dir) do
            if entry and entry ~= "." and entry ~= ".." then
                local path = dir .. "/" .. entry
                local st = lfs.attributes(path, "mode")
                if st == "directory" then
                    recurse(path, depth + 1)
                elseif st == "file" then
                    -- try to handle as document (DocSettings will ignore missing sidecars)
                    handle_doc(path)
                end
            end
        end
    end

    recurse(root_dir, 0)

    return found
end

return Scan
