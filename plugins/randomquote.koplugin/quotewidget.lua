local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Device = require("device")
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

    if self.dismissable then
        if Device:hasKeys() then
            self.key_events = { AnyKeyPressed = { { Device.input.group.Any } } }
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

    for _, c in ipairs(chunks) do
        local t = tostring(c.text or "")
        local bold = c.bold or false
        local align = c.align or "left"
        local tb = TextBoxWidget:new{
            text = t,
            face = self.face,
            bold = bold and true or nil,
            alignment = align,
            width = self.width or math.floor(Screen:getWidth() * 2/3),
        }
        table.insert(vg, tb)
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
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
