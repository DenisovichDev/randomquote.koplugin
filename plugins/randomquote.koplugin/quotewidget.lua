-- SPDX-License-Identifier: AGPL-3.0-or-later

-- Custom widget to display chunked text in a framed, centered container 

local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Device = require("device")
local Input = Device.input
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Screen = require("device").screen

local QuoteWidget = InputContainer:extend{
    modal = true,
    dismissable = true,
    timeout = nil,
    face = nil,
    width = nil,
    height = nil,
    -- text may be string or table of chunks: { {text=..., bold=true, align="center"}, ... }
    text = "",
    _timeout_func = nil,
}

function QuoteWidget:init()
    if not self.face then
        self.face = Font:getFace("infofont")
    end

    -- Content padding (pixels) between frame border and content; tweakable
    local CONTENT_PADDING = (Size.padding.default * 4) or 20
    -- Margin (pixels) between frame and screen edge; tweakable
    local FRAME_MARGIN = (Size.margin.window) or 0

    if self.dismissable then
        if Device:hasKeys() then
            self.key_events = { AnyKeyPressed = { { Input.group.Any } } }
        end
        if Device:isTouchDevice() then
            local Geom = require("ui/geometry")
            local GestureRange = require("ui/gesturerange")
            self.ges_events = {
                TapClose = {
                    GestureRange:new{
                        ges = "tap",
                        range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
                    }
                }
            }
        end
    end

    local vg = VerticalGroup:new{ align = "center" }

    -- normalize text into chunks
    local chunks = {}
    if type(self.text) == "table" then
        chunks = self.text
    else
        chunks = { { text = tostring(self.text) } }
    end

    -- todo: this does not work. Maybe soomeone can fix it later.
    -- helper: attempt to get an italic variant of a face by scanning FontList's collected font info
    local function try_get_italic_face(base_face)
        if not base_face or type(base_face) ~= "table" or not base_face.realname then return nil end
        local ok, FontList = pcall(require, "fontlist")
        if not ok or not FontList then return nil end
        -- Ensure fontlist is populated
        pcall(function() FontList:getFontList() end)
        local b_real = tostring(base_face.realname or "")
        local b_orig = tostring(base_face.orig_font or "")
        -- derive basename of realname (filename) for loose matching
        local _, b_name = string.match(b_real, "(.*/)(.+)")
        b_name = b_name or b_real
        for path, coll in pairs(FontList.fontinfo or {}) do
            -- direct path match
            if tostring(path) == b_real or tostring(path):find(b_name, 1, true) then
                for _, finfo in ipairs(coll) do
                    if finfo.italic then
                        local idx = finfo.index or 0
                        local ok2, face = pcall(function() return Font:getFace(path, base_face.orig_size or base_face.size, idx) end)
                        if ok2 and face then return face end
                    end
                end
            end
            -- fallback: match by family name
            for _, finfo in ipairs(coll) do
                if (finfo.name == b_orig or finfo.name == b_real or finfo.name == b_name) and finfo.italic then
                    local idx = finfo.index or 0
                    local ok2, face = pcall(function() return Font:getFace(path, base_face.orig_size or base_face.size, idx) end)
                    if ok2 and face then return face end
                end
            end
        end
        return nil
    end

    for _, c in ipairs(chunks) do
        local t = tostring(c.text or "")
        local bold = c.bold or false
        local italic = c.italic or false
        local align = c.align or "left"

        local face_for_chunk = self.face
        if italic and type(self.face) == "table" then
            local ital = try_get_italic_face(self.face)
            if ital then face_for_chunk = ital end
        end

        local tb = TextBoxWidget:new{
            text = t,
            face = face_for_chunk,
            bold = bold and true or nil,
            alignment = align,
            width = self.width or math.floor(Screen:getWidth() * 2/3),
        }
        table.insert(vg, tb)
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = CONTENT_PADDING,
        margin = FRAME_MARGIN,
        vg,
    }

    self.movable = MovableContainer:new{ frame }
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.movable }
end

function QuoteWidget:onShow()
    UIManager:setDirty(self, function() return "ui", self.movable.dimen end)
    if self.timeout then
        self._timeout_func = function()
            self._timeout_func = nil
            UIManager:close(self)
        end
        UIManager:scheduleIn(self.timeout, self._timeout_func)
    end
    return true
end

function QuoteWidget:onCloseWidget()
    if self._timeout_func then
        UIManager:unschedule(self._timeout_func)
        self._timeout_func = nil
    end
    UIManager:setDirty(nil, function() return "ui", self.movable.dimen end)
end

function QuoteWidget:onTapClose()
    UIManager:close(self)
    return true
end
QuoteWidget.onAnyKeyPressed = QuoteWidget.onTapClose

return QuoteWidget
