local SC = {}
SC.Version = "1.0.0-rc.9"
local BRAND = "ScriptCenter"
local LOGO = "rbxassetid://97517292167647"
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

-- 01 | Validation ----------------------------------------------------------
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function text(value, fallback, limit)
    if type(value) ~= "string" then
        return fallback
    end
    local cap = limit or 200
    if #value <= cap then return value end
    local ok, boundary = pcall(utf8.offset, value, 0, cap + 1)
    if not ok then return fallback end
    return string.sub(value, 1, (boundary or (cap + 1)) - 1)
end

local function clone(value, seen, depth)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    depth = depth or 0
    if depth > 24 then
        error("Table nesting exceeds 24 levels", 2)
    end
    if seen[value] then
        error("Cyclic table is not supported", 2)
    end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        if type(key) ~= "string" and not finite(key) then
            error("Unsupported table key", 2)
        end
        result[key] = clone(item, seen, depth + 1)
    end
    seen[value] = nil
    return result
end

local function trace(err)
    return debug.traceback(tostring(err), 2)
end

-- 02 | Bounded diagnostic buffer -------------------------------------------
local Logger = {}
Logger.__index = Logger

function Logger.new(limit)
    return setmetatable({ Limit = limit, Entries = {}, Sequence = 0 }, Logger)
end

function Logger:Write(level, context, message)
    self.Sequence += 1
    local entry = {
        Id = self.Sequence,
        Time = os.clock(),
        Level = level,
        Context = tostring(context),
        Message = string.sub(tostring(message), 1, 4000),
    }
    table.insert(self.Entries, entry)
    if #self.Entries > self.Limit then
        table.remove(self.Entries, 1)
    end
    if level == "Error" or level == "Warning" then
        warn("[SC-UI] " .. entry.Context .. ": " .. entry.Message)
    end
end

function Logger:Snapshot()
    return clone(self.Entries)
end

function Logger:Clear()
    table.clear(self.Entries)
end

local logger = Logger.new(100)

local function protected(context, callback, ...)
    if type(callback) ~= "function" then
        logger:Write("Error", context, "Expected function")
        return false, "Expected function"
    end
    local args = table.pack(...)
    local result = table.pack(xpcall(function()
        return callback(table.unpack(args, 1, args.n))
    end, trace))
    if not result[1] then
        logger:Write("Error", context, result[2])
    end
    return table.unpack(result, 1, result.n)
end

-- 03 | Resource ownership --------------------------------------------------
local Scope = {}
Scope.__index = Scope

local function dispose(resource)
    local kind = typeof(resource)
    if kind == "RBXScriptConnection" then
        resource:Disconnect()
    elseif kind == "Instance" then
        if resource:IsA("Tween") then
            resource:Cancel()
        end
        resource:Destroy()
    elseif kind == "thread" then
        if resource ~= coroutine.running() and coroutine.status(resource) ~= "dead" then
            task.cancel(resource)
        end
    elseif kind == "function" then
        resource()
    else
        error("Unsupported resource: " .. kind)
    end
end

function Scope.new(name)
    return setmetatable({ Name = name, Alive = true, Items = {}, Count = 0 }, Scope)
end

function Scope:Add(resource)
    if not self.Alive then
        protected(self.Name .. ".lateDispose", dispose, resource)
        return resource
    end
    if self.Items[resource] == nil then
        self.Count += 1
        self.Items[resource] = self.Count
    end
    return resource
end

function Scope:Forget(resource)
    self.Items[resource] = nil
end

function Scope:Remove(resource)
    if self.Items[resource] ~= nil then
        self.Items[resource] = nil
        protected(self.Name .. ".dispose", dispose, resource)
    end
end

function Scope:Connect(signal, callback)
    if not self.Alive then
        return nil
    end
    local connection = signal:Connect(function(...)
        if self.Alive then
            protected(self.Name .. ".event", callback, ...)
        end
    end)
    return self:Add(connection)
end

function Scope:Delay(seconds, callback)
    if not self.Alive then
        return nil
    end
    if not finite(seconds) or seconds < 0 then
        error("Invalid delay", 2)
    end
    local thread
    thread = task.delay(seconds, function()
        if self.Alive then
            protected(self.Name .. ".task", callback)
        end
        self:Forget(thread)
    end)
    return self:Add(thread)
end

function Scope:Spawn(callback)
    return self:Delay(0, callback)
end

function Scope:Child(name)
    local child = Scope.new(self.Name .. "/" .. name)
    local cleanup = function()
        child:Destroy()
    end
    self:Add(cleanup)
    child.ParentRelease = function()
        self:Forget(cleanup)
    end
    return child
end

function Scope:Destroy()
    if not self.Alive then
        return
    end
    self.Alive = false
    local items = self.Items
    self.Items = {}
    local ordered = {}
    for resource, order in pairs(items) do
        table.insert(ordered, { Resource = resource, Order = order })
    end
    table.sort(ordered, function(a, b)
        return a.Order > b.Order
    end)
    for _, item in ipairs(ordered) do
        protected(self.Name .. ".cleanup", dispose, item.Resource)
    end
    if self.ParentRelease then
        self.ParentRelease()
        self.ParentRelease = nil
    end
end

function Scope:Size()
    local count = 0
    for _ in pairs(self.Items) do
        count += 1
    end
    return count
end

-- 04 | Instance factory ----------------------------------------------------
local function create(scope, class, properties, parent)
    assert(scope.Alive, "Scope is closed")
    local instance = Instance.new(class)
    scope:Add(instance)
    local ok, err = protected("Instance." .. class, function()
        for key, value in pairs(properties or {}) do
            assert(key ~= "Parent", "Pass Parent separately")
            instance[key] = value
        end
        instance.Parent = parent
    end)
    if not ok then
        scope:Remove(instance)
        error(err, 2)
    end
    return instance
end

-- 05 | Tween ownership (one channel per target/property set) ---------------
local Animator = {}
Animator.__index = Animator

function Animator.new(scope)
    local self = setmetatable({ Scope = scope, Active = {} }, Animator)
    scope:Add(function()
        self:CancelAll()
    end)
    return self
end

function Animator:Cancel(target)
    local entry = self.Active[target]
    if entry then
        self.Active[target] = nil
        entry.Scope:Destroy()
    end
end

function Animator:CancelAll()
    local targets = {}
    for target in pairs(self.Active) do
        table.insert(targets, target)
    end
    for _, target in ipairs(targets) do
        self:Cancel(target)
    end
end

function Animator:Play(target, goals, duration)
    if not self.Scope.Alive then
        return false
    end
    self:Cancel(target)
    duration = finite(duration) and math.clamp(duration, 0, 2) or 0.15
    if duration == 0 then
        return protected("Animation.immediate", function()
            for key, value in pairs(goals) do
                target[key] = value
            end
        end)
    end
    local scope = self.Scope:Child("Tween")
    local ok, tween = protected("Animation.create", function()
        return TweenService:Create(target, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goals)
    end)
    if not ok then
        scope:Destroy()
        return false
    end
    scope:Add(tween)
    local entry = { Scope = scope }
    self.Active[target] = entry
    scope:Connect(tween.Completed, function()
        if self.Active[target] == entry then
            self.Active[target] = nil
        end
        scope:Destroy()
    end)
    local played = protected("Animation.play", function()
        tween:Play()
    end)
    if not played then
        self:Cancel(target)
    end
    return played
end

-- 06 | Validated state -----------------------------------------------------
local State = {}
State.__index = State

function State.new()
    return setmetatable({ Entries = {}, Closed = false }, State)
end

function State:Register(flag, default, validator, callback)
    assert(not self.Closed, "State closed")
    assert(type(flag) == "string" and #flag > 0 and #flag <= 100, "Invalid flag")
    assert(not self.Entries[flag], "Duplicate flag: " .. flag)
    assert(type(validator) == "function", "Validator required")
    local ok, accepted, normalized = protected("State.validate." .. flag, validator, default)
    assert(ok and accepted == true, "Invalid default: " .. flag)
    self.Entries[flag] = {
        Value = clone(normalized),
        Default = clone(normalized),
        Validate = validator,
        Callback = callback,
        Busy = false,
    }
end

function State:Get(flag)
    local entry = self.Entries[flag]
    if entry then
        return clone(entry.Value)
    end
    return nil
end

function State:Set(flag, value, silent)
    local entry = self.Entries[flag]
    if self.Closed or not entry then
        return false, "Unknown or closed flag"
    end
    if entry.Busy then
        return false, "Recursive or concurrent update"
    end
    entry.Busy = true
    local success, accepted, normalized = protected("State.validate." .. flag, entry.Validate, value)
    if not success or accepted ~= true then
        entry.Busy = false
        return false, "Invalid value"
    end
    local copied, nextValue = protected("State.copy." .. flag, clone, normalized)
    if not copied or self.Closed then
        entry.Busy = false
        return false, "State unavailable"
    end
    entry.Value = nextValue
    local callbackOk = true
    if not silent and entry.Callback then
        callbackOk = protected("State.callback." .. flag, entry.Callback, clone(nextValue))
    end
    entry.Busy = false
    if not callbackOk then
        return true, "Value applied; callback failed"
    end
    return true
end

function State:Reset(flag, silent)
    local entry = self.Entries[flag]
    if not entry then
        return false, "Unknown flag"
    end
    return self:Set(flag, clone(entry.Default), silent)
end

function State:Snapshot()
    local result = {}
    for flag, entry in pairs(self.Entries) do
        result[flag] = clone(entry.Value)
    end
    return result
end

function State:Destroy()
    self.Closed = true
    table.clear(self.Entries)
end

-- 07 | Core lifecycle and minimal smoke-test shell -------------------------
local active
local Tab = {}
Tab.__index = Tab
local Window = {}
Window.__index = Window

function Window:IsAlive()
    return self._scope.Alive
end

function Window:Destroy()
    if not self:IsAlive() then
        return
    end
    if active == self then
        active = nil
    end
    self._pointer=nil
    self._keyCapture=nil
    self._scope:Destroy()
    self._popupOwner=nil
    self._dialog=nil
    self._loadingScope=nil
    self._lastAutoExport=nil
    self._storage=nil
    self._state:Destroy()
    for _,key in ipairs({"_elements","_tabs","_colors","_translations","_keyElements","_preferenceControls","_metricCaptions"}) do
        if self[key] then table.clear(self[key]) end
    end
    logger:Write("Info", "Window", "Destroyed")
end

function Window:GetDiagnostics()
    return {
        Version = SC.Version,
        Alive = self:IsAlive(),
        Resources = self._scope:Size(),
        Logs = logger:Snapshot(),
    }
end

function SC:GetLogs()
    return logger:Snapshot()
end

function SC:ClearLogs()
    logger:Clear()
end

function SC:Destroy()
    if active then
        active:Destroy()
    end
end

function SC:CreateWindow(options)
    assert(RunService:IsClient(), "SC-UI requires a client")
    options = options or {}
    assert(type(options) == "table", "Options must be a table")
    local player = assert(Players.LocalPlayer, "LocalPlayer unavailable")
    local parent = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
    assert(parent, "PlayerGui unavailable")
    self:Destroy()
    local scope = Scope.new("Window")
    local window = setmetatable({
        _scope = scope,
        _state = State.new(),
        _animator = Animator.new(scope),
    }, Window)
    local ok, err = protected("Window.initialize", function()
        -- Separate copies of the module use a synchronous BindableFunction handoff.
        local old = parent:FindFirstChild("SCUI_Signature")
        if old then
            local shutdown = old:FindFirstChild("SCUI_Shutdown")
            assert(shutdown and shutdown:IsA("BindableFunction"), "Existing SC-UI has no compatible shutdown hook")
            shutdown:Invoke()
            assert(not old.Parent, "Existing SC-UI did not shut down")
        end
        local gui = create(scope, "ScreenGui", {
            Name = "SCUI_Signature",
            ResetOnSpawn = false,
            IgnoreGuiInset = false,
            DisplayOrder = 20,
        }, parent)
        local shutdown = create(scope, "BindableFunction", { Name = "SCUI_Shutdown" }, gui)
        shutdown.OnInvoke = function()
            window:Destroy()
            return true
        end
        scope:Connect(gui.Destroying, function()
            window:Destroy()
        end)
        window:_buildSignature(gui, options)
    end)
    if not ok then
        window:Destroy()
        error(err, 2)
    end
    active = window
    logger:Write("Info", "Window", "Initialized")
    return window
end

-- 07A | Signature theme and layout -----------------------------------------
local UIS = game:GetService("UserInputService")
local Themes = {
    BlackGold = {20,20,23, 31,31,36, 217,188,124},
    Midnight = {16,22,35, 27,36,52, 139,169,244},
    Emerald = {16,24,23, 28,39,37, 105,198,162},
    Classic = {23,23,25, 36,36,40, 190,190,200},
}
local Sizes = {Compact = Vector2.new(420,300), Small = Vector2.new(480,340), Medium = Vector2.new(600,400), Large = Vector2.new(720,480)}
local function corner(scope, object, radius)
    return create(scope, "UICorner", {CornerRadius = UDim.new(0,radius)}, object)
end
local function label(scope, parent, value, size, position, dimensions)
    return create(scope, "TextLabel", {
        Text = value, TextSize = size, Font = Enum.Font.Gotham,
        TextColor3 = Color3.fromRGB(235,235,239), BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = position, Size = dimensions,
    }, parent)
end
local function button(scope, parent, value, position, dimensions)
    local object = create(scope, "TextButton", {
        Text = value, TextSize = 13, Font = Enum.Font.GothamMedium,
        TextColor3 = Color3.fromRGB(235,235,239), BackgroundColor3 = Color3.fromRGB(43,43,49),
        BorderSizePixel = 0, AutoButtonColor = true, Position = position, Size = dimensions,
    }, parent)
    corner(scope, object, 8)
    return object
end
function Window:_bindColor(object, property, role)
    table.insert(self._colors, {Object = object, Property = property, Role = role})
    object[property] = self._palette[role]
    object.Destroying:Once(function()
        for i=#self._colors,1,-1 do
            if self._colors[i].Object==object then table.remove(self._colors,i) end
        end
    end)
end
function Window:SetTheme(name)
    if not self:IsAlive() or type(name) ~= "string" or not Themes[name] then return false end
    local t = Themes[name]
    self._theme = name
    self._palette = {
        Background = Color3.fromRGB(t[1],t[2],t[3]),
        Surface = Color3.fromRGB(t[4],t[5],t[6]),
        Accent = Color3.fromRGB(t[7],t[8],t[9]),
        Text = Color3.fromRGB(235,235,239),
        Muted = Color3.fromRGB(159,159,170),
        Control = Color3.fromRGB(math.min(t[4]+14,255),math.min(t[5]+14,255),math.min(t[6]+14,255)),
    }
    for i = #self._colors, 1, -1 do
        local binding = self._colors[i]
        if binding.Object.Parent then
            binding.Object[binding.Property] = self._palette[binding.Role]
        else
            table.remove(self._colors,i)
        end
    end
    if self._selected then self:SelectTab(self._selected) end
    if self._elements then
        for e in pairs(self._elements) do
            if e:IsAlive() and e._render then protected("Theme.render",e._render,e:GetValue()) end
        end
    end
    return true
end
function Window:_bounds()
    local size = self._root.AbsoluteSize
    return Vector2.new(math.max(1,size.X),math.max(1,size.Y))
end
function Window:_clamp(object, position)
    local bounds = self:_bounds()
    local size = Vector2.new(object.Size.X.Offset, object.Size.Y.Offset)
    local margin = 6
    return Vector2.new(
        math.clamp(position.X, margin, math.max(margin,bounds.X-size.X-margin)),
        math.clamp(position.Y, margin, math.max(margin,bounds.Y-size.Y-margin))
    )
end
function Window:_place(object, position)
    local p = self:_clamp(object,position)
    object.Position = UDim2.fromOffset(p.X,p.Y)
end
function Window:_layout(center)
    if not self:IsAlive() then return end
    local bounds = self:_bounds()
    if bounds.X < 20 or bounds.Y < 20 then return end
    local target = self._customSize or Sizes[self._sizeMode] or Sizes.Medium
    if self._sizeMode == "Auto" and bounds.X < 540 then target = Sizes.Small end
    if self._maximized then target = bounds end
    local width = math.min(target.X,math.max(1,bounds.X-16))
    local height = math.min(target.Y,math.max(1,bounds.Y-16))
    self._panel.Size = UDim2.fromOffset(width,height)
    self._capsule.Size = UDim2.fromOffset(math.min(self._capsuleMode=="Logo only" and 36 or 148,math.max(1,bounds.X-12)),math.min(36,math.max(1,bounds.Y-12)))
    local compact = width < 500 or self._sidebarCollapsed
    local sidebarWidth = compact and 56 or 145
    self._sidebar.Size = UDim2.new(0,sidebarWidth,1,-58)
    self._content.Position = UDim2.fromOffset(sidebarWidth+12,66)
    self._content.Size = UDim2.new(1,-sidebarWidth-24,1,-78)
    for _, entry in pairs(self._tabs) do
        entry.Button.Text = compact and entry.Short or (entry.Short .. "   " .. (entry.DisplayName or entry.Name))
    end
    local current = self._panel.Position
    self:_place(self._panel,center and Vector2.new((bounds.X-width)/2,(bounds.Y-height)/2) or Vector2.new(current.X.Offset,current.Y.Offset))
    local cp = self._capsule.Position
    self:_place(self._capsule,Vector2.new(cp.X.Offset,cp.Y.Offset))
    -- AbsoluteSize can update on the following frame; clamp again once.
    if not self._layoutPending then
        self._layoutPending = true
        self._scope:Delay(0,function()
            self._layoutPending = false
            if not self:IsAlive() then return end
            for _, object in ipairs({self._panel,self._capsule}) do
                local p = object.Position
                self:_place(object,Vector2.new(p.X.Offset,p.Y.Offset))
            end
        end)
    end
end
function Window:SetSize(mode)
    if not self:IsAlive() then return false end
    if typeof(mode) == "Vector2" and finite(mode.X) and finite(mode.Y) then
        self._customSize = Vector2.new(math.clamp(mode.X,280,1600),math.clamp(mode.Y,220,1000))
        self._sizeMode = "Custom"
    elseif type(mode) == "string" and (mode == "Auto" or Sizes[mode]) then
        self._customSize = nil
        self._sizeMode = mode
    else return false end
    self._maximized = false
    self:_layout(false)
    return true
end
function Window:Center()
    self:_layout(true)
end
function Window:SetVisible(value)
    if not self:IsAlive() or type(value) ~= "boolean" then return false end
    if not value then
        self._pointer=nil
        local capture=self._keyCapture
        self._keyCapture=nil
        if capture and capture:IsAlive() then
            protected("Keybind.cancel",capture._render,capture:GetValue())
        end
        if self._popupOwner then self._popupOwner._closePopup() end
    end
    self._panel.Visible = value
    self._capsule.Visible = not value
    if value then
        self:_layout(false)
        self._panel.GroupTransparency = self._animation and 0.18 or 0
        self._animator:Play(self._panel,{GroupTransparency = 0},self._animation and not self._lowPerformance and (self._animationSpeed or 0.15) or 0)
    else
        self._animator:Cancel(self._panel)
    end
    return true
end
function Window:Toggle()
    return self:SetVisible(not self._panel.Visible)
end
function Window:SetAnimation(enabled)
    if type(enabled) ~= "boolean" or not self:IsAlive() then return false end
    self._animation = enabled
    if not enabled then
        self._animator:Cancel(self._panel)
        self._panel.GroupTransparency = 0
    end
    return true
end
-- Single pointer router: no independent global input listeners per widget.
function Window:_attachDrag(handle, object, mode, tap)
    self._scope:Connect(handle.InputBegan,function(input)
        local kind = input.UserInputType
        if object==self._panel and mode=="Move" and self._draggable==false then return end
        if self._pointer or (kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch) then return end
        self._pointer = {Input=input, Touch=kind==Enum.UserInputType.Touch, Start=Vector2.new(input.Position.X,input.Position.Y), Position=Vector2.new(object.Position.X.Offset,object.Position.Y.Offset), Size=object.AbsoluteSize, Object=object, Mode=mode, Tap=tap, Moved=false}
    end)
end
function Window:_initInput()
    self._scope:Connect(UIS.InputChanged,function(input)
        local p = self._pointer
        if not p then return end
        if p.Touch and input ~= p.Input then return end
        if not p.Touch and input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        if p.Mode=="Control" then
            if p.Owner:IsAlive() and not p.Owner._disabled then p.Update(input) end
            return
        end
        local delta = Vector2.new(input.Position.X,input.Position.Y)-p.Start
        if delta.Magnitude < 5 and not p.Moved then return end
        p.Moved = true
        if p.Mode == "Resize" then
            self:SetSize(p.Size+delta)
        else
            self:_place(p.Object,p.Position+delta)
        end
    end)
    self._scope:Connect(UIS.InputEnded,function(input)
        local p = self._pointer
        if not p then return end
        if (p.Touch and input==p.Input) or (not p.Touch and input.UserInputType==Enum.UserInputType.MouseButton1) then
            self._pointer = nil
            if not p.Moved and p.Tap then p.Tap() end
        end
    end)
    self._scope:Connect(UIS.WindowFocusReleased,function() self._pointer=nil end)
    self._scope:Connect(UIS.InputBegan,function(input,processed)
        if processed or UIS:GetFocusedTextBox() or self._dialog or self._loadingScope then return end
        local capture=self._keyCapture
        if capture and input.KeyCode~=Enum.KeyCode.Unknown then
            self._keyCapture=nil
            if capture:IsAlive() then
                if input.KeyCode~=Enum.KeyCode.Escape then capture:SetValue(input.KeyCode.Name) end
                capture._render(capture:GetValue())
            end
            return
        end
        if input.KeyCode == self._keybind then self:Toggle(); return end
        for element in pairs(self._keyElements or {}) do
            if element:IsAlive() and not element._disabled and element:GetValue()==input.KeyCode.Name and element._options.Callback then
                element._scope:Spawn(function() protected("Keybind.action",element._options.Callback,input.KeyCode.Name) end)
            end
        end
    end)
end
-- 07B | Navigation foundation (components follow in round 3) ---------------
function Window:SelectTab(name)
    if not self:IsAlive() or not self._tabs[name] then return false end
    if self._selected~=name then
        self._pointer=nil
        local capture=self._keyCapture
        self._keyCapture=nil
        if capture and capture:IsAlive() then
            protected("Keybind.cancel",capture._render,capture:GetValue())
        end
        if self._popupOwner then self._popupOwner._closePopup() end
    end
    self._selected = name
    for key, entry in pairs(self._tabs) do
        entry.Page.Visible = key == name
        entry.Button.TextColor3 = key == name and self._palette.Accent or self._palette.Text
        entry.Button.BackgroundColor3 = key == name and self._palette.Control or self._palette.Surface
        if entry.Indicator then entry.Indicator.Visible = key == name end
    end
    return true
end
function Window:CreateTab(options)
    assert(self:IsAlive(),"Window closed")
    if type(options)=="string" then options={Name=options} end
    assert(type(options)=="table","Tab options expected")
    local name = text(options.Name,"Tab",60)
    assert(name~="" and not self._tabs[name],"Invalid or duplicate tab")
    local scope = self._scope:Child("Tab/"..name)
    local tabButton = button(scope,self._nav,name,UDim2.new(),UDim2.new(1,0,0,36))
    tabButton.LayoutOrder = name == "Settings" and 100000 or self._tabCount
    self._tabCount += 1
    self:_bindColor(tabButton,"BackgroundColor3","Surface")
    local page = create(scope,"ScrollingFrame",{
        Size=UDim2.fromScale(1,1),BackgroundTransparency=1,BorderSizePixel=0,
        CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=3,
        Visible=false,ScrollingDirection=Enum.ScrollingDirection.Y,
    },self._content)
    create(scope,"UIListLayout",{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},page)
    local title = label(scope,page,name,20,UDim2.new(),UDim2.new(1,-8,0,30))
    title.Font=Enum.Font.GothamBold
    title.LayoutOrder=0
    local description = text(options.Desc or options.Description,"",200)
    if description~="" then
        local subtitle=label(scope,page,description,12,UDim2.new(),UDim2.new(1,-8,0,22))
        subtitle.LayoutOrder=1
        self:_bindColor(subtitle,"TextColor3","Muted")
    end
    local symbols = {home="⌂", settings="⚙", user="◎", list="≡", star="★", box="□", activity="∿", search="⌕", gamepad="◇", heart="♡", gift="◆", egg="◉", dna="∿", bug="✳", ["list-checks"]="☑", shield="◇", zap="ϟ", clock="◷", code="‹›", globe="◎", folder="▣"}
    local icon = type(options.Icon)=="string" and symbols[string.lower(options.Icon)] or nil
    local entry={Name=name,Short=icon or (name=="Home" and "⌂") or (name=="Settings" and "⚙") or string.sub(name,1,(utf8.offset(name,2) or (#name+1))-1),Page=page,Button=tabButton,_scope=scope,_window=self}
    entry.Title=title
    entry.Indicator=create(scope,"Frame",{Size=UDim2.fromOffset(3,22),Position=UDim2.fromOffset(0,7),BorderSizePixel=0,Visible=false},tabButton)
    corner(scope,entry.Indicator,2)
    self:_bindColor(entry.Indicator,"BackgroundColor3","Accent")
    self._tabs[name]=entry
    scope:Connect(tabButton.Activated,function() self:SelectTab(name) end)
    if not self._selected then self:SelectTab(name) end
    self:_layout(false)
    return setmetatable(entry,Tab)
end
-- 07C | Signature shell ---------------------------------------------------


-- 08 | Core self-test (no UI creation) -------------------------------------
function SC:RunCoreTests()
    local results = {}
    local function test(name, callback)
        local ok, err = protected("Test." .. name, callback)
        local result = { Name = name, Passed = ok }
        if not ok then
            result.Error = tostring(err)
        end
        table.insert(results, result)
    end
    test("finite validation", function()
        assert(finite(1) and not finite(0/0) and not finite(math.huge))
    end)
    test("clone isolation", function()
        local original = { Nested = { Value = 1 } }
        local copied = clone(original)
        copied.Nested.Value = 2
        assert(original.Nested.Value == 1)
    end)
    test("cycle rejected", function()
        local cyclic = {}
        cyclic.Self = cyclic
        assert(not pcall(clone, cyclic))
    end)
    test("scope cleanup order and idempotence", function()
        local scope = Scope.new("Test")
        local order = {}
        scope:Add(function() table.insert(order, 1) end)
        scope:Add(function() table.insert(order, 2) end)
        scope:Destroy()
        scope:Destroy()
        assert(#order == 2 and order[1] == 2 and order[2] == 1)
        assert(scope:Size() == 0)
    end)
    test("child release", function()
        local scope = Scope.new("Test")
        local child = scope:Child("Child")
        child:Destroy()
        assert(scope:Size() == 0)
        scope:Destroy()
    end)
    test("state validation and reset", function()
        local state = State.new()
        state:Register("Demo", false, function(value)
            return type(value) == "boolean", value
        end)
        assert(state:Set("Demo", true))
        assert(state:Get("Demo") == true)
        assert(not state:Set("Demo", 1))
        assert(state:Reset("Demo"))
        assert(state:Get("Demo") == false)
        state:Destroy()
    end)
    test("duplicate flag rejected", function()
        local state = State.new()
        local validator = function(v) return true, v end
        state:Register("Demo", 1, validator)
        assert(not pcall(state.Register, state, "Demo", 2, validator))
        state:Destroy()
    end)
    test("callback isolated", function()
        local state = State.new()
        state:Register("Demo", 1, function(v) return finite(v), v end, function() error("Intentional test error") end)
        local applied, message = state:Set("Demo", 2)
        assert(applied and message and state:Get("Demo") == 2)
        state:Destroy()
    end)
    return results
end

-- 09 | Public component engine --------------------------------------------
-- All controls share state validation, ownership and a consistent API.
local Element = {}
Element.__index = Element

local function optionsOf(options)
    if options == nil then return {} end
    if type(options) == "string" then return {Name=options} end
    assert(type(options) == "table", "Component options expected")
    return options
end

local function firstDefined(...)
    for i=1,select('#', ...) do
        local v=select(i,...)
        if v~=nil then return v end
    end
end

local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end

local function optionList(values)
    assert(type(values)=="table", "Options must be an array")
    local result, seen={},{}
    for _,v in ipairs(values) do
        assert(type(v)=="string" or finite(v), "Options must be strings or finite numbers")
        if not seen[v] then
            table.insert(result,v)
            seen[v]=true
        end
    end
    return result,seen
end

function Element:IsAlive()
    return self._scope.Alive and self._window:IsAlive()
end

function Element:SetText(value)
    if not self:IsAlive() or type(value)~="string" then return false end
    self._title.Text=value
    return true
end

function Element:SetDescription(value)
    if not self:IsAlive() or type(value)~="string" then return false end
    self._description.Text=value
    self._description.Visible=value~=""
    return true
end

function Element:SetVisible(value)
    if not self:IsAlive() or type(value)~="boolean" then return false end
    self._row.Visible=value
    if not value then
        if self._closePopup then self._closePopup() end
        if self._window._pointer and self._window._pointer.Owner==self then self._window._pointer=nil end
        if self._window._keyCapture==self then
            self._window._keyCapture=nil
            protected("Keybind.cancel",self._render,self:GetValue())
        end
    end
    return true
end

function Element:SetDisabled(value)
    if not self:IsAlive() or type(value)~="boolean" then return false end
    self._disabled=value
    if value and self._window._pointer and self._window._pointer.Owner==self then self._window._pointer=nil end
    self._title.TextTransparency=value and 0.48 or 0
    self._description.TextTransparency=value and 0.48 or 0
    if self._edit then
        self._edit.TextEditable=not value
        if value then self._edit:ReleaseFocus(false) end
    end
    if self._extraEdits then for _,edit in ipairs(self._extraEdits) do edit.TextEditable=not value; if value then edit:ReleaseFocus(false) end end end
    if self._closePopup then self._closePopup() end
    if value and self._window._keyCapture==self then self._window._keyCapture=nil; self._render(self:GetValue()) end
    return true
end

function Element:GetValue()
    if self._flag and self:IsAlive() then return self._window._state:Get(self._flag) end
end

function Element:SetValue(value,silent)
    if not self:IsAlive() or not self._flag then return false,"No writable state" end
    local old=self:GetValue()
    local ok,message=self._window._state:Set(self._flag,value,true)
    if not ok then return false,message end
    local current=self:GetValue()
    if self._render then protected("Component.render",self._render,current) end
    if not silent and not equal(old,current) and self._callback then
        -- Serialize callbacks per control; retain the latest value during rapid drag.
        self._pendingCallback={Value=clone(current)}
        if not self._callbackRunning then
            self._callbackRunning=true
            self._scope:Spawn(function()
                while self:IsAlive() and self._pendingCallback do
                    local pending=self._pendingCallback
                    self._pendingCallback=nil
                    protected("Component.callback."..self._flag,self._callback,pending.Value)
                end
                self._callbackRunning=false
            end)
        end
    end
    return true
end

function Element:Reset(silent)
    if not self._flag or not self:IsAlive() then return false end
    local entry=self._window._state.Entries[self._flag]
    return self:SetValue(clone(entry.Default),silent)
end

function Element:Destroy()
    if self._scope.Alive then self._scope:Destroy() end
end

function Element:_connect(signal,callback)
    return self._scope:Connect(signal,function(...)
        if self:IsAlive() and not self._disabled then callback(...) end
    end)
end

function Element:_state(default,validator,render)
    local window=self._window
    window._nextFlag=(window._nextFlag or 0)+1
    local flag=self._options.Flag or ("@"..window._nextFlag)
    local ok,err=pcall(window._state.Register,window._state,flag,default,validator)
    if not ok then self:Destroy(); error(err,2) end
    self._flag=flag
    self._render=render
    self._scope:Add(function()
        window._state.Entries[flag]=nil
    end)
    local rendered,message=protected("Component.initialRender",render,self:GetValue())
    if not rendered then self:Destroy(); error(message,2) end
end

function Tab:_element(options,height)
    options=optionsOf(options)
    assert(self._scope.Alive,"Tab closed")
    local w=self._window
    if options.Flag~=nil then
        assert(type(options.Flag)=="string" and #options.Flag>0 and #options.Flag<=100 and string.sub(options.Flag,1,1)~="@","Invalid or reserved Flag")
        assert(not w._state.Entries[options.Flag],"Duplicate Flag: "..options.Flag)
    end
    local scope=self._scope:Child("Element")
    local row=create(scope,"Frame",{
        Size=UDim2.new(1,-8,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        BorderSizePixel=0,
    },self.Page)
    w:_bindColor(row,"BackgroundColor3","Surface")
    corner(scope,row,9)
    create(scope,"UIPadding",{PaddingTop=UDim.new(0,9),PaddingBottom=UDim.new(0,9),PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10)},row)
    create(scope,"UIListLayout",{Padding=UDim.new(0,5),SortOrder=Enum.SortOrder.LayoutOrder},row)
    local title=label(scope,row,text(options.Name or options.Title,"Feature",200),13,UDim2.new(),UDim2.new(1,0,0,20))
    title.Font=Enum.Font.GothamMedium
    title.LayoutOrder=1
    w:_bindColor(title,"TextColor3","Text")
    local desc=label(scope,row,text(options.Desc or options.Description,"",1000),11,UDim2.new(),UDim2.new(1,0,0,0))
    desc.LayoutOrder=2
    desc.TextWrapped=true
    desc.TextTruncate=Enum.TextTruncate.None
    desc.AutomaticSize=Enum.AutomaticSize.Y
    desc.Visible=desc.Text~=""
    w:_bindColor(desc,"TextColor3","Muted")
    local content=create(scope,"Frame",{Size=UDim2.new(1,0,0,height or 0),BackgroundTransparency=1,Visible=(height or 0)>0},row)
    content.LayoutOrder=3
    self._elementOrder=(self._elementOrder or 2)+1
    row.LayoutOrder=self._elementOrder
    local e=setmetatable({_scope=scope,_window=w,_row=row,_title=title,_description=desc,_content=content,_options=options,_callback=options.Callback,_disabled=false},Element)
    w._elements=w._elements or {}
    w._elements[e]=true
    e._scope:Add(function()
        w._elements[e]=nil
        if w._keyCapture==e then w._keyCapture=nil end
        if w._translations then
            for i=#w._translations,1,-1 do
                if w._translations[i].Element==e then table.remove(w._translations,i) end
            end
        end
        if w._pointer and w._pointer.Owner==e then w._pointer=nil end
        for i=#w._colors,1,-1 do
            if not w._colors[i].Object.Parent or w._colors[i].Object:IsDescendantOf(e._row) or w._colors[i].Object==e._row then table.remove(w._colors,i) end
        end
    end)
    e._tabName=self.Name
    e._systemControl=self.Name=="Home" or self.Name=="Settings" or self.Name=="Search"
    return e
end


function Element:_button(name,parent,position,size)
    local b=button(self._scope,parent or self._content,name,position or UDim2.new(),size or UDim2.fromScale(1,1))
    self._window:_bindColor(b,"TextColor3","Text")
    self._window:_bindColor(b,"BackgroundColor3","Control")
    return b
end

function Element:_textbox(value,placeholder,parent,position,size)
    local box=create(self._scope,"TextBox",{
        Text=value,PlaceholderText=placeholder or "",ClearTextOnFocus=false,
        TextSize=13,Font=Enum.Font.Gotham,BorderSizePixel=0,
        Position=position or UDim2.new(),Size=size or UDim2.fromScale(1,1),
    },parent or self._content)
    corner(self._scope,box,7)
    self._window:_bindColor(box,"BackgroundColor3","Control")
    self._window:_bindColor(box,"TextColor3","Text")
    self._window:_bindColor(box,"PlaceholderColor3","Muted")
    return box
end

function Tab:CreateSection(options)
    local e=self:_element(options,0)
    e._row.BackgroundTransparency=1
    e._window:_bindColor(e._title,"TextColor3","Accent")
    return e
end

function Tab:CreateLabel(options)
    return self:_element(options,0)
end

function Tab:CreateParagraph(options)
    options=optionsOf(options)
    local e=self:_element(options,0)
    e:SetDescription(tostring(options.Content or options.Desc or options.Description or ""))
    return e
end

function Tab:CreateDivider()
    local e=self:_element({Name=""},2)
    e._title.Visible=false
    e._row.BackgroundTransparency=1
    e._window:_bindColor(e._content,"BackgroundColor3","Muted")
    e._content.BackgroundTransparency=0.65
    return e
end

function Tab:CreateButton(options)
    local e=self:_element(options,32)
    local b=e:_button(text(e._options.ButtonText,"Run",100))
    e:_connect(b.Activated,function()
        if e._callback then e._scope:Spawn(function() protected("Button.callback",e._callback) end) end
    end)
    return e
end

function Tab:CreateToggle(options)
    local e=self:_element(options,30)
    local b=e:_button("",nil,UDim2.new(1,-46,0,3),UDim2.fromOffset(46,24))
    corner(e._scope,b,12)
    local knob=create(e._scope,"Frame",{Size=UDim2.fromOffset(16,16),Position=UDim2.fromOffset(4,4),BackgroundColor3=Color3.fromRGB(245,245,245),BorderSizePixel=0},b)
    corner(e._scope,knob,8)
    local status=label(e._scope,e._content,"Off",12,UDim2.new(),UDim2.new(1,-55,1,0))
    e:_state(firstDefined(e._options.CurrentValue,e._options.Default,false),function(v) return type(v)=="boolean",v end,function(v)
        status.Text=v and "On" or "Off"
        b.BackgroundColor3=v and e._window._palette.Accent or e._window._palette.Control
        knob.Position=UDim2.fromOffset(v and 26 or 4,4)
    end)
    e:_connect(b.Activated,function() e:SetValue(not e:GetValue()) end)
    return e
end

local function numericRange(options)
    local range=options.Range
    local lo=firstDefined(options.Min,type(range)=="table" and range[1] or nil,0)
    local hi=firstDefined(options.Max,type(range)=="table" and range[2] or nil,100)
    local step=firstDefined(options.Increment,options.Step,1)
    assert(finite(lo) and finite(hi) and hi>lo and finite(step) and step>0,"Invalid numeric range")
    return lo,hi,step
end

local function quantize(v,lo,hi,step)
    if v>=hi then return hi end
    return math.clamp(lo+math.floor((math.clamp(v,lo,hi)-lo)/step+0.5)*step,lo,hi)
end

function Tab:CreateSlider(options)
    options=optionsOf(options)
    local lo,hi,step=numericRange(options)
    local e=self:_element(options,38)
    local track=e:_button("",nil,UDim2.fromOffset(0,22),UDim2.new(1,0,0,8))
    local fill=create(e._scope,"Frame",{Size=UDim2.fromScale(0,1),BorderSizePixel=0},track)
    e._window:_bindColor(fill,"BackgroundColor3","Accent")
    corner(e._scope,fill,5)
    local value=label(e._scope,e._content,"",12,UDim2.new(),UDim2.new(1,-82,0,18))
    local edit=e:_textbox("","",e._content,UDim2.new(1,-76,0,0),UDim2.fromOffset(76,20))
    e._edit=edit
    e:_state(firstDefined(options.CurrentValue,options.Default,lo),function(v)
        return finite(v),finite(v) and quantize(v,lo,hi,step) or nil
    end,function(v)
        value.Text=string.format("%g / %g",v,hi)
        edit.Text=string.format("%g",v)
        fill.Size=UDim2.fromScale((v-lo)/(hi-lo),1)
    end)
    e:_connect(edit.FocusLost,function() if not e:SetValue(tonumber(edit.Text)) then edit.Text=tostring(e:GetValue()) end end)
    local function update(input)
        local fraction=math.clamp((input.Position.X-track.AbsolutePosition.X)/math.max(1,track.AbsoluteSize.X),0,1)
        e:SetValue(lo+fraction*(hi-lo))
    end
    e:_connect(track.InputBegan,function(input)
        local kind=input.UserInputType
        if e._window._pointer or (kind~=Enum.UserInputType.Touch and kind~=Enum.UserInputType.MouseButton1) then return end
        e._window._pointer={Input=input,Touch=kind==Enum.UserInputType.Touch,Mode="Control",Update=update,Owner=e}
        update(input)
    end)
    return e
end


function Tab:CreateInput(options)
    options=optionsOf(options)
    local e=self:_element(options,32)
    local box=e:_textbox("",text(options.Placeholder,"Enter text",100))
    e._edit=box
    local limit=finite(options.MaxLength) and math.clamp(math.floor(options.MaxLength),1,4096) or 256
    e:_state(firstDefined(options.CurrentValue,options.Default,options.CurrentText,""),function(v)
        return type(v)=="string" and #v<=limit,v
    end,function(v) box.Text=v end)
    e:_connect(box.FocusLost,function(enter)
        if options.EnterOnly and not enter then box.Text=e:GetValue(); return end
        if not e:SetValue(box.Text) then box.Text=e:GetValue() end
    end)
    return e
end

function Tab:CreateNumberInput(options)
    options=optionsOf(options)
    local lo,hi,step=numericRange(options)
    local e=self:_element(options,32)
    local box=e:_textbox("","Number")
    e._edit=box
    e:_state(firstDefined(options.CurrentValue,options.Default,lo),function(v)
        return finite(v),finite(v) and quantize(v,lo,hi,step) or nil
    end,function(v) box.Text=tostring(v) end)
    e:_connect(box.FocusLost,function() if not e:SetValue(tonumber(box.Text)) then box.Text=tostring(e:GetValue()) end end)
    return e
end

-- Dropdown uses a bounded page of results instead of thousands of buttons.
function Tab:CreateDropdown(options)
    options=optionsOf(options)
    local values,allowed=optionList(options.Options or options.Values or {})
    local multi=firstDefined(options.MultipleOptions,options.Multi,false)==true
    local e=self:_element(options,32)
    local b=e:_button("Select")
    local popup,query,page= nil,"",1
    local selectedText=function(v)
        if multi then
            local names={}
            for _,item in ipairs(v) do table.insert(names,tostring(item)) end
            return #names>0 and table.concat(names,", ") or (options.Placeholder or "Select")
        end
        return v~=nil and tostring(v) or (options.Placeholder or "Select")
    end
    local function validate(v)
        if multi then
            if type(v)~="table" then return false end
            local result,seen={},{}
            for _,item in ipairs(v) do
                if not allowed[item] then return false end
                if not seen[item] then table.insert(result,item); seen[item]=true end
            end
            return true,result
        end
        return v==nil or allowed[v]==true,v
    end
    local function close()
        if popup then popup:Destroy(); popup=nil end
        if e._window._popupOwner==e then e._window._popupOwner=nil end
        if e:IsAlive() then e._content.Size=UDim2.new(1,0,0,32) end
    end
    e._closePopup=close
    e._scope:Add(close)
    b.Size=UDim2.new(1,0,0,32)
    b.TextTruncate=Enum.TextTruncate.AtEnd
    local renderList
    local listScope
    local function open()
        local w=e._window
        if w._popupOwner and w._popupOwner~=e then w._popupOwner._closePopup() end
        w._popupOwner=e
        popup=e._scope:Child("Dropdown")
        query=""; page=1
        local panel=create(popup,"Frame",{Position=UDim2.fromOffset(0,38),Size=UDim2.new(1,0,0,224),BackgroundTransparency=1},e._content)
        e._content.Size=UDim2.new(1,0,0,262)
        local search=create(popup,"TextBox",{Text="",PlaceholderText="Search options",ClearTextOnFocus=false,Size=UDim2.new(1,0,0,28),TextSize=12,Font=Enum.Font.Gotham,BorderSizePixel=0},panel)
        corner(popup,search,6)
        w:_bindColor(search,"BackgroundColor3","Control")
        w:_bindColor(search,"TextColor3","Text")
        local holder=create(popup,"Frame",{Position=UDim2.fromOffset(0,34),Size=UDim2.new(1,0,0,152),BackgroundTransparency=1},panel)
        local prev=button(popup,panel,"‹",UDim2.fromOffset(0,192),UDim2.fromOffset(42,28))
        local nextButton=button(popup,panel,"›",UDim2.new(1,-42,0,192),UDim2.fromOffset(42,28))
        local count=label(popup,panel,"",11,UDim2.fromOffset(46,192),UDim2.new(1,-92,0,28))
        count.TextXAlignment=Enum.TextXAlignment.Center
        renderList=function()
            if listScope then listScope:Destroy() end
            listScope=popup:Child("Page")
            local filtered={}
            for _,v in ipairs(values) do if string.find(string.lower(tostring(v)),query,1,true) then table.insert(filtered,v) end end
            local pages=math.max(1,math.ceil(#filtered/5))
            page=math.clamp(page,1,pages)
            count.Text=string.format("%d / %d",page,pages)
            local current=e:GetValue()
            for i=(page-1)*5+1,math.min(page*5,#filtered) do
                local item=filtered[i]
                local checked=multi and table.find(current,item)~=nil or (not multi and current==item)
                local row=button(listScope,holder,(checked and "✓  " or "")..tostring(item),UDim2.fromOffset(0,((i-1)%5)*30),UDim2.new(1,0,0,27))
                row.TextTruncate=Enum.TextTruncate.AtEnd
                listScope:Connect(row.Activated,function()
                    if e._disabled then return end
                    if multi then
                        local picked=e:GetValue()
                        local index=table.find(picked,item)
                        if index then table.remove(picked,index) else table.insert(picked,item) end
                        e:SetValue(picked); renderList()
                    else e:SetValue(item); close() end
                end)
            end
        end
        popup:Connect(search:GetPropertyChangedSignal("Text"),function() query=string.lower(search.Text); page=1; renderList() end)
        popup:Connect(prev.Activated,function() page-=1; renderList() end)
        popup:Connect(nextButton.Activated,function() page+=1; renderList() end)
        renderList()
    end
    local default=firstDefined(options.CurrentOption,options.CurrentValue,options.Default,multi and {} or values[1])
    if not multi and type(default)=="table" then default=default[1] end
    e:_state(default,validate,function(v) b.Text=selectedText(v).."  ▾" end)
    e:_connect(b.Activated,function() if popup then close() else open() end end)
    function e:Refresh(newValues,keep)
        if not self:IsAlive() then return false end
        local ok,newList,newAllowed=protected("Dropdown.refresh",optionList,newValues)
        if not ok then return false end
        close()
        values,allowed=newList,newAllowed
        local old=self:GetValue()
        local replacement
        if multi then
            replacement={}
            if keep~=false then for _,v in ipairs(old) do if allowed[v] then table.insert(replacement,v) end end end
        else replacement=keep~=false and old~=nil and allowed[old] and old or values[1] end
        self._window._state.Entries[self._flag].Default=clone(replacement)
        return self:SetValue(replacement,true)
    end
    return e
end

function Tab:CreateMultiDropdown(options)
    local copy=table.clone(optionsOf(options))
    copy.MultipleOptions=true
    return self:CreateDropdown(copy)
end


function Tab:CreateKeybind(options)
    options=optionsOf(options)
    local e=self:_element(options,32)
    local b=e:_button("Key")
    local function validate(v)
        if typeof(v)=="EnumItem" and v.EnumType==Enum.KeyCode then v=v.Name end
        if type(v)~="string" then return false end
        local ok,key=pcall(function() return Enum.KeyCode[v] end)
        return ok and key~=nil and key~=Enum.KeyCode.Unknown,v
    end
    e:_state(firstDefined(options.CurrentKeybind,options.CurrentValue,options.Default,"RightControl"),validate,function(v) b.Text=v end)
    e._callback=options.OnChanged
    e:_connect(b.Activated,function()
        local w=e._window
        if w._keyCapture and w._keyCapture~=e then w._keyCapture._render(w._keyCapture:GetValue()) end
        w._keyCapture=e
        b.Text="Press a key (Esc cancels)"
    end)
    local w=e._window
    w._keyElements=w._keyElements or {}
    w._keyElements[e]=true
    e._scope:Add(function() w._keyElements[e]=nil; if w._keyCapture==e then w._keyCapture=nil end end)
    return e
end

function Tab:CreateProgressBar(options)
    options=optionsOf(options)
    local e=self:_element(options,20)
    local track=e:_button("")
    track.Active=false
    local fill=create(e._scope,"Frame",{Size=UDim2.fromScale(0,1),BorderSizePixel=0},track)
    corner(e._scope,fill,8)
    e._window:_bindColor(fill,"BackgroundColor3","Accent")
    local caption=label(e._scope,track,"",11,UDim2.new(),UDim2.fromScale(1,1))
    caption.TextXAlignment=Enum.TextXAlignment.Center
    caption.ZIndex=fill.ZIndex+1
    e:_state(firstDefined(options.CurrentValue,options.Default,0),function(v) return finite(v),finite(v) and math.clamp(v,0,100) or nil end,function(v)
        fill.Size=UDim2.fromScale(v/100,1); caption.Text=string.format("%.0f%%",v)
    end)
    return e
end

function Tab:CreateStatus(options)
    options=optionsOf(options)
    local e=self:_element(options,22)
    local value=label(e._scope,e._content,"",12,UDim2.new(),UDim2.fromScale(1,1))
    e._window:_bindColor(value,"TextColor3","Accent")
    e:_state(firstDefined(options.CurrentValue,options.Default,"Ready"),function(v) return type(v)=="string",v end,function(v) value.Text=v end)
    return e
end

function Tab:CreateImage(options)
    options=optionsOf(options)
    local e=self:_element(options,finite(options.Height) and math.clamp(options.Height,32,300) or 100)
    local image=create(e._scope,"ImageLabel",{BackgroundTransparency=1,Size=UDim2.fromScale(1,1),ScaleType=Enum.ScaleType.Fit},e._content)
    e:_state(firstDefined(options.Image,options.AssetId,""),function(v)
        if finite(v) and v>0 then v="rbxassetid://"..string.format("%.0f",v) end
        return type(v)=="string" and (v=="" or string.match(v,"^rbxassetid://%d+$")~=nil),v
    end,function(v) image.Image=v end)
    return e
end

function Tab:CreateCard(options)
    return self:CreateParagraph(options)
end

function Tab:CreateThemePicker(options)
    options=table.clone(options or {})
    options.Name=options.Name or "Theme"
    options.Options={"BlackGold","Midnight","Emerald","Classic"}
    options.Default=self._window._theme
    local callback=options.Callback
    local w=self._window
    options.Callback=function(v) w:SetTheme(v); if callback then callback(v) end end
    return self:CreateDropdown(options)
end

function Tab:Select()
    return self._window:SelectTab(self.Name)
end

function Tab:Destroy()
    if not self._scope.Alive then return end
    local w=self._window
    if self.Name=="Home" or self.Name=="Settings" or self.Name=="Search" then return false end
    w._tabs[self.Name]=nil
    self._scope:Destroy()
    if w._selected==self.Name then w:SelectTab("Home") end
    return true
end

function Window:SetKeybind(value)
    if typeof(value)=="EnumItem" and value.EnumType==Enum.KeyCode then value=value.Name end
    if type(value)~="string" then return false end
    local ok,key=pcall(function() return Enum.KeyCode[value] end)
    if not ok or not key or key==Enum.KeyCode.Unknown then return false end
    self._keybind=key
    return true
end

-- Wrap navigation without changing the original signature shell.


-- 10 | Home dashboard and interface preferences ---------------------------
local Stats = game:GetService("Stats")
local function readMetric(callback)
    local ok, value = pcall(callback)
    if not ok or value == nil then return "N/A" end
    return tostring(value)
end

function Window:_localized(element, english, thai)
    self._translations = self._translations or {}
    table.insert(self._translations, {Element=element, English=english, Thai=thai})
    element:SetText(self._language=="Thai" and thai or english)
    return element
end

function Window:SetLanguage(language)
    if language~="English" and language~="Thai" then return false end
    if not self:IsAlive() then return false end
    self._language=language
    for _, entry in ipairs(self._metricCaptions or {}) do
        if entry.Label.Parent then entry.Label.Text=language=="Thai" and entry.Thai or entry.English end
    end
    local names={Home="หน้าแรก",Settings="ตั้งค่า",Search="ค้นหา"}
    for key,entry in pairs(self._tabs or {}) do
        if names[key] then
            entry.DisplayName=language=="Thai" and names[key] or key
            entry.Title.Text=entry.DisplayName
        end
    end
    if self._panel then self:_layout(false) end
    for _, entry in ipairs(self._translations or {}) do
        if entry.Element:IsAlive() then
            entry.Element:SetText(language=="Thai" and entry.Thai or entry.English)
        end
    end
    return true
end

function Window:SetOpacity(percent)
    if not self:IsAlive() or not finite(percent) then return false end
    self._opacity=math.clamp(percent,65,100)
    self._panel.BackgroundTransparency=1-self._opacity/100
    return true
end

function Window:SetCapsuleMode(mode)
    if not self:IsAlive() or (mode~="Full" and mode~="Logo only") then return false end
    self._capsuleMode=mode
    self._capsuleText.Visible=mode=="Full"
    if self._capsuleArrow then self._capsuleArrow.Visible=mode=="Full" end
    self:_layout(false)
    return true
end

function Window:ResetCapsulePosition()
    if not self:IsAlive() then return end
    local bounds=self:_bounds()
    self:_place(self._capsule,Vector2.new((bounds.X-self._capsule.Size.X.Offset)/2,12))
end

function Window:_positionFraction(object)
    local bounds=self:_bounds()
    return {
        X=math.clamp((object.Position.X.Offset-6)/math.max(1,bounds.X-object.Size.X.Offset-12),0,1),
        Y=math.clamp((object.Position.Y.Offset-6)/math.max(1,bounds.Y-object.Size.Y.Offset-12),0,1),
    }
end

function Window:_restorePosition(object,position)
    if type(position)~="table" or not finite(position.X) or not finite(position.Y) then return end
    local bounds=self:_bounds()
    self:_place(object,Vector2.new(
        6+math.clamp(position.X,0,1)*math.max(0,bounds.X-object.Size.X.Offset-12),
        6+math.clamp(position.Y,0,1)*math.max(0,bounds.Y-object.Size.Y.Offset-12)
    ))
end

function Window:GetPreferences()
    if not self:IsAlive() then return nil end
    return {
        Theme=self._theme, Language=self._language, Size=self._sizeMode,
        Opacity=self._opacity, Animation=self._animation,
        AnimationSpeed=self._animationSpeed, Keybind=self._keybind.Name,
        CapsuleMode=self._capsuleMode, Draggable=self._draggable,
        SidebarCollapsed=self._sidebarCollapsed==true,
        RefreshInterval=self._refreshInterval, LowPerformance=self._lowPerformance,
        CustomWidth=self._customSize and self._customSize.X,
        CustomHeight=self._customSize and self._customSize.Y,
        Notifications=self._notificationsEnabled~=false,
        RememberPosition=self._rememberPosition~=false,
        WindowPosition=self._rememberPosition~=false and self:_positionFraction(self._panel) or nil,
        CapsulePosition=self._rememberPosition~=false and self:_positionFraction(self._capsule) or nil,
    }
end

-- Home metrics stay local; no HTTP requests, fingerprinting or telemetry.
function Window:_buildHome(home, options)
    local player=Players.LocalPlayer
    local scope=home._scope
    local function section(en,th)
        return self:_localized(home:CreateSection(en),en,th)
    end
    local function field(en,th,initial)
        local e=home:CreateParagraph({Name=en,Content=initial or "N/A"})
        return self:_localized(e,en,th)
    end
    section("Player profile","ข้อมูลผู้เล่น")
    local avatar=home:_element({Name="Avatar"},64)
    self:_localized(avatar,"Avatar","รูปโปรไฟล์")
    local image=create(avatar._scope,"ImageLabel",{
        Size=UDim2.fromOffset(64,64),BackgroundTransparency=1,
        ScaleType=Enum.ScaleType.Fit,
    },avatar._content)
    corner(avatar._scope,image,12)
    scope:Spawn(function()
        local ok,url=pcall(Players.GetUserThumbnailAsync,Players,player.UserId,Enum.ThumbnailType.HeadShot,Enum.ThumbnailSize.Size100x100)
        if ok and scope.Alive then image.Image=url end
    end)
    field("Account","บัญชี",player.DisplayName.." (@"..player.Name..")")
    field("User ID","รหัสผู้เล่น",tostring(player.UserId))
    field("Account age","อายุบัญชี",tostring(player.AccountAge).." days")
    section("Performance","ประสิทธิภาพ")
    local metrics=home:_element({Name="Live statistics"},144)
    self:_localized(metrics,"Live statistics","สถิติขณะใช้งาน")
    metrics._row.BackgroundTransparency=1
    local grid=create(metrics._scope,"UIGridLayout",{
        CellPadding=UDim2.fromOffset(6,6),CellSize=UDim2.new(0.5,-3,0,66),
        SortOrder=Enum.SortOrder.LayoutOrder,
    },metrics._content)
    local captions={}
    local function metric(en,th)
        local card=create(metrics._scope,"Frame",{BorderSizePixel=0},metrics._content)
        self:_bindColor(card,"BackgroundColor3","Surface")
        corner(metrics._scope,card,10)
        local heading=label(metrics._scope,card,en,11,UDim2.fromOffset(9,5),UDim2.new(1,-18,0,20))
        self:_bindColor(heading,"TextColor3","Muted")
        table.insert(captions,{Label=heading,English=en,Thai=th})
        local value=label(metrics._scope,card,"N/A",16,UDim2.fromOffset(9,26),UDim2.new(1,-18,0,30))
        value.Font=Enum.Font.GothamBold
        value.TextScaled=true
        create(metrics._scope,"UITextSizeConstraint",{MinTextSize=9,MaxTextSize=16},value)
        self:_bindColor(value,"TextColor3","Accent")
        return {SetDescription=function(_,v) if metrics:IsAlive() then value.Text=v end end}
    end
    local perf=metric("FPS / minimum","FPS / ต่ำสุด")
    local pingCard=metric("Ping (one-way)","ปิง (ทางเดียว)")
    local memory=metric("Client memory","หน่วยความจำ Roblox")
    local session=metric("Session duration","เวลาใช้งาน")
    self._metricCaptions=captions
    local function layoutMetrics()
        if not metrics:IsAlive() then return end
        local cols=metrics._content.AbsoluteSize.X>=210 and 2 or 1
        grid.FillDirectionMaxCells=cols
        grid.CellSize=UDim2.new(1/cols,-(cols==2 and 3 or 0),0,66)
        local target=UDim2.new(1,0,0,math.ceil(4/cols)*72)
        if metrics._content.Size~=target then metrics._content.Size=target end
    end
    scope:Connect(metrics._content:GetPropertyChangedSignal("AbsoluteSize"),layoutMetrics)
    scope:Delay(0,layoutMetrics)
    section("Device","อุปกรณ์")
    local device=field("Input capabilities","อุปกรณ์รับข้อมูล")
    local viewport=field("Viewport","ขนาดพื้นที่แสดงผล")
    field("Runtime","สภาพแวดล้อม",RunService:IsStudio() and "Roblox Studio" or "Roblox client")
    -- An optional already-masked label supplied by the host; never query HWID.
    local deviceLabel=options.DeviceLabel
    if type(deviceLabel)~="string" or #deviceLabel>32 or not string.match(deviceLabel,"^%*+%s?%x%x%x%x$") then
        deviceLabel="Not supported by Roblox client API"
    end
    field("HWID / device label","รหัสอุปกรณ์",deviceLabel)
    section("Character","ตัวละคร")
    local character=field("Character status","สถานะตัวละคร")
    local movement=field("Movement","การเคลื่อนที่")
    local position=field("Position XYZ","ตำแหน่ง XYZ")
    local respawn=field("Respawns since UI start","จำนวนเกิดใหม่หลังเปิด UI","0")
    section("Game & server","เกมและเซิร์ฟเวอร์")
    if type(options.Game)=="string" and options.Game~="" then field("Game","ชื่อเกม",text(options.Game,"",100)) end
    field("Universe / place ID","รหัสเกม / สถานที่",tostring(game.GameId).." / "..tostring(game.PlaceId))
    field("Server ID","รหัสเซิร์ฟเวอร์",game.JobId~="" and game.JobId or "Studio / N/A")
    local population=field("Players","จำนวนผู้เล่น")
    section("ScriptCenter","ScriptCenter")
    field("Library version","เวอร์ชัน Library",SC.Version)
    if type(options.Version)=="string" then field("Script version","เวอร์ชันสคริปต์",text(options.Version,"",100)) end
    if type(options.Description)=="string" and options.Description~="" then field("Information","รายละเอียด",text(options.Description,"",1000)) end
    if type(options.Changelog)=="string" and options.Changelog~="" then field("Changelog","รายการอัปเดต",text(options.Changelog,"",1000)) end
    field("Community","ชุมชน","discord.gg/Pb2SWjrqF7")
    local started=os.clock()
    local respawns=0
    local frames,elapsed,slowest=0,0,nil
    local lastMemory=0
    local function visible()
        return self:IsAlive() and self._panel.Visible and self._selected=="Home"
    end
    scope:Connect(player.CharacterAdded,function()
        respawns+=1
    end)
    scope:Connect(RunService.RenderStepped,function(dt)
        if visible() then frames+=1; elapsed+=dt end
    end)
    local function refresh()
        if not visible() then frames=0; elapsed=0; return end
        local now=os.clock()
        local fps=elapsed>0 and math.floor(frames/elapsed+0.5) or nil
        if fps then slowest=slowest and math.min(slowest,fps) or fps end
        frames=0; elapsed=0
        local ping=readMetric(function() return string.format("%.0f ms (one-way)",player:GetNetworkPing()*1000) end)
        perf:SetDescription(tostring(fps or "N/A").." / "..tostring(slowest or "N/A"))
        pingCard:SetDescription(ping)
        if now-lastMemory>=5 or lastMemory==0 then
            memory:SetDescription(readMetric(function() return string.format("%.1f MB",Stats:GetTotalMemoryUsageMb()) end))
            lastMemory=now
        end
        local duration=math.floor(now-started)
        session:SetDescription(string.format("%02d:%02d:%02d",math.floor(duration/3600),math.floor(duration/60)%60,duration%60))
        device:SetDescription(string.format("Touch: %s | Keyboard: %s | Mouse: %s | Gamepad: %s",tostring(UIS.TouchEnabled),tostring(UIS.KeyboardEnabled),tostring(UIS.MouseEnabled),tostring(UIS.GamepadEnabled)))
        local bounds=self:_bounds()
        viewport:SetDescription(string.format("%d × %d",math.floor(bounds.X),math.floor(bounds.Y)))
        local char=player.Character
        local humanoid=char and char:FindFirstChildOfClass("Humanoid")
        local root=char and char:FindFirstChild("HumanoidRootPart")
        if root and not root:IsA("BasePart") then root=nil end
        character:SetDescription(humanoid and string.format("HP %.0f / %.0f | %s | %s",humanoid.Health,humanoid.MaxHealth,humanoid.RigType.Name,humanoid.Health>0 and "Alive" or "Dead") or "N/A")
        movement:SetDescription(humanoid and string.format("WalkSpeed: %.1f | %s: %.1f",humanoid.WalkSpeed,humanoid.UseJumpPower and "JumpPower" or "JumpHeight",humanoid.UseJumpPower and humanoid.JumpPower or humanoid.JumpHeight) or "N/A")
        position:SetDescription(root and string.format("%.1f, %.1f, %.1f",root.Position.X,root.Position.Y,root.Position.Z) or "N/A")
        respawn:SetDescription(tostring(respawns))
        population:SetDescription(string.format("%d / %d",#Players:GetPlayers(),Players.MaxPlayers))
    end
    -- A single scoped update job. Hidden dashboard does not read metrics.
    scope:Spawn(function()
        while scope.Alive do
            protected("Home.refresh",refresh)
            task.wait(self._lowPerformance and math.max(5,self._refreshInterval) or self._refreshInterval)
        end
    end)
end

function Window:GetHome()
    return self:IsAlive() and self._tabs.Home or nil
end

function Window:_buildSettings(tab)
    local controls={}
    self._preferenceControls=controls
    local function add(key,method,en,th,opts)
        opts=opts or {}
        opts.Name=en
        local element=tab[method](tab,opts)
        self:_localized(element,en,th)
        if key then controls[key]=element end
        return element
    end
    local function section(en,th) add(nil,"CreateSection",en,th) end
    local function action(en,th,callback) add(nil,"CreateButton",en,th,{ButtonText="Run / OK",Callback=callback}) end
    section("Appearance","รูปลักษณ์")
    add("Theme","CreateDropdown","Theme","ธีม",{Options={"BlackGold","Midnight","Emerald","Classic"},Default="BlackGold",Callback=function(v) self:SetTheme(v) end})
    add("Language","CreateDropdown","Language","ภาษา",{Options={"English","Thai"},Default="English",Callback=function(v) self:SetLanguage(v) end})
    add("Opacity","CreateSlider","Panel opacity","ความทึบพื้นหลัง",{Range={65,100},Increment=5,Default=100,Callback=function(v) self:SetOpacity(v) end})
    section("Window","หน้าต่าง")
    add("Size","CreateDropdown","Window size","ขนาดหน้าต่าง",{Options={"Auto","Compact","Small","Medium","Large","Custom"},Default="Auto",Callback=function(v)
        if v=="Custom" then self:SetSize(self._customSize or Vector2.new(600,400)) else self:SetSize(v) end
    end})
    local width=add("CustomWidth","CreateNumberInput","Custom width","ความกว้างกำหนดเอง",{Min=280,Max=1600,Default=600})
    local height=add("CustomHeight","CreateNumberInput","Custom height","ความสูงกำหนดเอง",{Min=220,Max=1000,Default=400})
    action("Apply custom size","ใช้ขนาดกำหนดเอง",function() self:SetSize(Vector2.new(width:GetValue(),height:GetValue())) end)
    add("Draggable","CreateToggle","Window dragging","ลากหน้าต่าง",{Default=true,Callback=function(v) self._draggable=v; self._pointer=nil end})
    add("SidebarCollapsed","CreateToggle","Collapse sidebar","พับเมนูด้านซ้าย",{Default=false,Callback=function(v) self._sidebarCollapsed=v; self:_layout(false) end})
    add("RememberPosition","CreateToggle","Remember positions in profile","จำตำแหน่งในโปรไฟล์",{Default=true,Callback=function(v) self._rememberPosition=v end})
    action("Center window","คืนหน้าต่างกลางจอ",function() self:Center() end)
    section("Capsule & controls","แคปซูลและการควบคุม")
    add("CapsuleMode","CreateDropdown","Capsule style","รูปแบบแคปซูล",{Options={"Full","Logo only"},Default="Full",Callback=function(v) self:SetCapsuleMode(v) end})
    action("Reset capsule position","คืนตำแหน่งแคปซูล",function() self:ResetCapsulePosition() end)
    add("Keybind","CreateKeybind","Toggle UI shortcut","ปุ่มลัดเปิดปิด UI",{CurrentKeybind="RightControl",OnChanged=function(v) self:SetKeybind(v) end})
    section("Performance","ประสิทธิภาพ")
    add("Animation","CreateToggle","Animations","ภาพเคลื่อนไหว",{Default=true,Callback=function(v) self:SetAnimation(v) end})
    add("AnimationSpeed","CreateSlider","Animation duration (s)","ระยะเวลาแอนิเมชัน (วินาที)",{Range={0.05,0.35},Increment=0.05,Default=0.15,Callback=function(v) self._animationSpeed=v end})
    add("RefreshInterval","CreateSlider","Statistics interval (s)","ช่วงอัปเดตสถิติ (วินาที)",{Range={1,10},Increment=1,Default=1,Callback=function(v) self._refreshInterval=v end})
    add("LowPerformance","CreateToggle","Low performance mode","โหมดประหยัดทรัพยากร",{Default=false,Callback=function(v) self._lowPerformance=v; if v then self:SetAnimation(false); controls.Animation:SetValue(false,true) end end})
    section("System","ระบบ")
    add(nil,"CreateParagraph","Configuration","การบันทึกค่า",{Content="Profiles use session storage or a host-provided storage adapter."})
    action("Reset interface settings","คืนค่าการตั้งค่า UI",function() self:ResetPreferences() end)
    action("Unload interface","ปิดและล้าง UI",function()
        self:Confirm({Title=self._language=="Thai" and "ปิด UI?" or "Unload interface?",Callback=function() self:Destroy() end})
    end)
end

function Window:ResetPreferences()
    if not self:IsAlive() then return false end
    self._draggable=true
    self._rememberPosition=true
    self._sidebarCollapsed=false
    self._lowPerformance=false
    self._refreshInterval=1
    self._animationSpeed=0.15
    self:SetTheme("BlackGold")
    self:SetLanguage("English")
    self:SetOpacity(100)
    self:SetSize("Auto")
    self:SetAnimation(true)
    self:SetCapsuleMode("Full")
    self:SetKeybind("RightControl")
    self:Center()
    self:ResetCapsulePosition()
    for _,control in pairs(self._preferenceControls or {}) do control:Reset(true) end
    self._notificationsEnabled=true
    self:SetAutoSave(false)
    return true
end


-- Keep Settings handles synchronized when the host calls public setters.
local function syncPreference(window,key,value)
    local control=window._preferenceControls and window._preferenceControls[key]
    if control and control:IsAlive() then control:SetValue(value,true) end
end
local preferenceSetters={SetTheme="Theme",SetLanguage="Language",SetOpacity="Opacity",SetSize="Size",SetAnimation="Animation",SetCapsuleMode="CapsuleMode",SetKeybind="Keybind"}
for method,key in pairs(preferenceSetters) do
    local original=Window[method]
    Window[method]=function(self,value)
        local ok=original(self,value)
        if ok and self._preferenceControls then
            local preferences=self:GetPreferences()
            if preferences then
                syncPreference(self,key,preferences[key])
                if method=="SetSize" and self._customSize then
                    syncPreference(self,"CustomWidth",self._customSize.X)
                    syncPreference(self,"CustomHeight",self._customSize.Y)
                end
            end
        end
        return ok
    end
end

-- 11 | Profiles and local storage adapter ---------------------------------
local HttpService = game:GetService("HttpService")
local memoryProfiles = {}
local function profileName(name)
    return type(name)=="string" and #name<=48 and name:match("^[%w_-]+$")~=nil
end
local function encodeValue(value)
    if typeof(value)=="Color3" then return {Kind="Color3",R=value.R,G=value.G,B=value.B} end
    return {Kind="Value",Value=clone(value)}
end
local function decodeValue(item)
    if type(item)~="table" then error("Invalid profile value") end
    if item.Kind=="Color3" and finite(item.R) and finite(item.G) and finite(item.B) then
        return Color3.new(math.clamp(item.R,0,1),math.clamp(item.G,0,1),math.clamp(item.B,0,1))
    end
    assert(item.Kind=="Value","Unknown value format")
    return clone(item.Value)
end
function Window:_profileKey(name)
    assert(profileName(name),"Invalid profile name")
    return self._profileNamespace..":"..name
end
function Window:ExportConfig()
    local values={}
    for e in pairs(self._elements or {}) do
        if e:IsAlive() and e._flag and e._options.Flag and not e._systemControl then
            values[e._flag]=encodeValue(e:GetValue())
        end
    end
    return HttpService:JSONEncode({Schema=1,Preferences=self:GetPreferences(),Values=values})
end
function Window:ImportConfig(raw,applyCallbacks)
    if not self:IsAlive() then return false,"Window closed" end
    if type(raw)~="string" or #raw>524288 then return false,"Invalid profile size" end
    local ok,data=protected("Config.decode",function() return HttpService:JSONDecode(raw) end)
    if not ok or type(data)~="table" or data.Schema~=1 or type(data.Values)~="table" then return false,"Invalid or unsupported profile" end
    local applied,skipped=0,0
    local prefs=type(data.Preferences)=="table" and data.Preferences or {}
    local setters={Theme="SetTheme",Language="SetLanguage",Opacity="SetOpacity",Size="SetSize",Animation="SetAnimation",CapsuleMode="SetCapsuleMode",Keybind="SetKeybind"}
    for key,method in pairs(setters) do
        if prefs[key]~=nil then protected("Config.preference",self[method],self,prefs[key]) end
    end
    for e in pairs(self._elements or {}) do
        if e:IsAlive() and e._flag and e._options.Flag and not e._systemControl and data.Values[e._flag]~=nil then
            local valid,value=protected("Config.value",decodeValue,data.Values[e._flag])
            if valid and e:SetValue(value,not applyCallbacks) then applied+=1 else skipped+=1 end
        end
    end
    self:_restoreExtraPreferences(prefs)
    return true,{Applied=applied,Skipped=skipped}
end
function Window:SaveConfig(name)
    if not self:IsAlive() or not profileName(name) then return false,"Invalid profile" end
    local ok,raw=protected("Config.export",self.ExportConfig,self)
    if not ok or #raw>524288 then return false,"Cannot encode profile" end
    local key=self:_profileKey(name)
    if self._storage then
        local success,result=protected("Config.write",self._storage.Write,key,raw)
        if not success or result==false then return false,"Storage write failed" end
    else memoryProfiles[key]=raw end
    return true
end
function Window:LoadConfig(name,applyCallbacks)
    name=name or "default"
    if not self:IsAlive() or not profileName(name) then return false,"Invalid profile" end
    local key=self:_profileKey(name)
    local raw=memoryProfiles[key]
    if self._storage then
        local ok,result=protected("Config.read",self._storage.Read,key)
        if not ok then return false,"Storage read failed" end
        raw=result
    end
    local imported,result=self:ImportConfig(raw,applyCallbacks==true)
    if imported and name==self._autoProfile then
        local ok,baseline=protected("AutoSave.loadedBaseline",self.ExportConfig,self)
        self._lastAutoExport=ok and baseline or nil
    end
    return imported,result
end
function Window:DeleteConfig(name)
    if not self:IsAlive() or not profileName(name) then return false,"Invalid profile" end
    local key=self:_profileKey(name)
    if self._storage then
        local ok,result=protected("Config.delete",self._storage.Delete,key)
        return ok and result~=false
    end
    memoryProfiles[key]=nil
    return true
end
function Window:ListConfigs()
    if not self:IsAlive() then return {} end
    local names={}
    if self._storage then
        local ok,result=protected("Config.list",self._storage.List,self._profileNamespace..":")
        if ok and type(result)=="table" then
            for _,name in ipairs(result) do if profileName(name) then table.insert(names,name) end end
        end
    else
        local prefix=self._profileNamespace..":"
        for key in pairs(memoryProfiles) do
            if key:sub(1,#prefix)==prefix then table.insert(names,key:sub(#prefix+1)) end
        end
    end
    local unique,seen={},{}
    for _,name in ipairs(names) do
        if not seen[name] then
            seen[name]=true
            table.insert(unique,name)
        end
    end
    table.sort(unique)
    return unique
end
-- 12 | Notifications and modal dialogs ------------------------------------
function Window:Notify(options)
    if not self:IsAlive() or self._notificationsEnabled==false then return end
    options=optionsOf(options)
    local scope=self._scope:Child("Notification")
    local frame=create(scope,"Frame",{Size=UDim2.fromOffset(245,66),BackgroundColor3=self._palette.Surface,BorderSizePixel=0},self._notificationHost)
    corner(scope,frame,10)
    local title=label(scope,frame,text(options.Title,BRAND,80),14,UDim2.fromOffset(10,5),UDim2.new(1,-38,0,23))
    title.TextColor3=self._palette.Accent
    local content=label(scope,frame,text(options.Content or options.Description,"",240),11,UDim2.fromOffset(10,29),UDim2.new(1,-20,0,32))
    content.TextWrapped=true
    local close=button(scope,frame,"×",UDim2.new(1,-26,0,3),UDim2.fromOffset(23,23))
    scope:Connect(close.Activated,function() scope:Destroy() end)
    local duration=finite(options.Duration) and math.clamp(options.Duration,1,30) or 4
    scope:Delay(duration,function() scope:Destroy() end)
    self._notices=self._notices or {}
    table.insert(self._notices,scope)
    scope:Add(function()
        local i=table.find(self._notices,scope)
        if i then table.remove(self._notices,i) end
    end)
    while #self._notices>3 do self._notices[1]:Destroy() end
end
function SC:Notify(options)
    if active then return active:Notify(options) end
end
function Window:Confirm(options)
    if not self:IsAlive() then return end
    options=optionsOf(options)
    if self._dialog then self._dialog:Destroy() end
    if self._loadingScope then self._loadingScope:Destroy() end
    if self._popupOwner then self._popupOwner._closePopup() end
    self._pointer=nil
    local scope=self._scope:Child("Dialog")
    self._dialog=scope
    scope:Add(function() if self._dialog==scope then self._dialog=nil end end)
    local overlay=create(scope,"TextButton",{Text="",Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.new(),BackgroundTransparency=0.35,AutoButtonColor=false,ZIndex=30},self._root)
    local panel=create(scope,"Frame",{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.new(0.9,0,0,150),BackgroundColor3=self._palette.Surface,ZIndex=31},overlay)
    create(scope,"UISizeConstraint",{MaxSize=Vector2.new(340,150)},panel)
    corner(scope,panel,12)
    local title=label(scope,panel,text(options.Title,"Confirm",100),16,UDim2.fromOffset(12,8),UDim2.new(1,-24,0,28)); title.ZIndex=32
    local body=label(scope,panel,text(options.Content,"Continue?",250),12,UDim2.fromOffset(12,40),UDim2.new(1,-24,0,55)); body.TextWrapped=true; body.ZIndex=32
    local yes=button(scope,panel,text(options.ConfirmText,"Confirm",24),UDim2.new(.5,4,1,-42),UDim2.new(.5,-16,0,32)); yes.ZIndex=32
    local no=button(scope,panel,"Cancel",UDim2.new(0,12,1,-42),UDim2.new(.5,-16,0,32)); no.ZIndex=32
    scope:Connect(no.Activated,function() scope:Destroy() end)
    scope:Connect(yes.Activated,function()
        scope:Destroy()
        if type(options.Callback)=="function" then protected("Dialog.callback",options.Callback) end
    end)
end
function SC:Confirm(options)
    if active then return active:Confirm(options) end
end
-- 13 | Cross-tab search and profile controls -------------------------------
function Window:Search(query)
    if type(query)~="string" then return {} end
    local result={}
    query=string.lower(query)
    if query=="" then return result end
    for e in pairs(self._elements or {}) do
        if e:IsAlive() and not e._systemControl and e._row.Visible then
            local name=e._title.Text
            local description=e._description.Text
            if string.find(string.lower(name.." "..description),query,1,true) then
                table.insert(result,{Name=name,Tab=e._tabName,Element=e})
            end
        end
    end
    table.sort(result,function(a,b) return (a.Tab..a.Name)<(b.Tab..b.Name) end)
    return result
end

function Tab:CreateConfigManager()
    local w=self._window
    local function localize(e,en,th)
        return w:_localized(e,en,th)
    end
    localize(self:CreateSection("Configuration profiles"),"Configuration profiles","โปรไฟล์การตั้งค่า")
    local name=localize(self:CreateInput({Name="Profile name",Default="default"}),"Profile name","ชื่อโปรไฟล์")
    local status=self:CreateLabel("Storage: "..(w._storage and "Host adapter" or "Session only"))
    local function report(ok,message)
        status:SetText(ok and "Success" or tostring(message or "Operation failed"))
    end
    localize(self:CreateButton({Name="Save profile",Callback=function() report(w:SaveConfig(name:GetValue())) end}),"Save profile","บันทึกโปรไฟล์")
    localize(self:CreateButton({Name="Load profile (values only)",Callback=function() report(w:LoadConfig(name:GetValue(),false)) end}),"Load profile (values only)","โหลดเฉพาะค่า")
    self:CreateButton({Name="Load and apply profile",Callback=function()
        local selected=name:GetValue()
        w:Confirm({Title="Apply profile?",Content="Saved values may activate callbacks.",Callback=function()
            report(w:LoadConfig(selected,true))
        end})
    end})
    self:CreateButton({Name="Delete profile",Callback=function()
        local selected=name:GetValue()
        w:Confirm({Title="Delete profile?",Content=selected,Callback=function() report(w:DeleteConfig(selected)) end})
    end})
    localize(self:CreateButton({Name="List profiles",Callback=function() status:SetText(table.concat(w:ListConfigs(),", ")) end}),"List profiles","รายการโปรไฟล์")
    return status
end


-- 14 | Release candidate: advanced controls and preference recovery --------
local function beginControl(element, target, update)
    element:_connect(target.InputBegan, function(input)
        local kind = input.UserInputType
        local window = element._window
        if window._pointer or (kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch) then
            return
        end
        window._pointer = {
            Input = input,
            Touch = kind == Enum.UserInputType.Touch,
            Mode = "Control",
            Owner = element,
            Update = update,
        }
        update(input)
    end)
end

function Tab:CreateRangeSlider(options)
    options = optionsOf(options)
    local lo, hi, step = numericRange(options)
    local e = self:_element(options, 48)
    local readout = label(e._scope, e._content, "", 12, UDim2.new(), UDim2.new(1,0,0,20))
    local track = e:_button("", nil, UDim2.fromOffset(8,28), UDim2.new(1,-16,0,14))
    local fill = create(e._scope,"Frame",{BorderSizePixel=0},track)
    e._window:_bindColor(fill,"BackgroundColor3","Accent")
    corner(e._scope,fill,7)
    local handles = {}
    for i=1,2 do
        local handle = create(e._scope,"Frame",{
            AnchorPoint=Vector2.new(.5,.5), Size=UDim2.fromOffset(18,18),
            BorderSizePixel=0, ZIndex=3,
        },track)
        corner(e._scope,handle,9)
        e._window:_bindColor(handle,"BackgroundColor3","Accent")
        handles[i]=handle
    end
    e:_state(firstDefined(options.CurrentValue,options.Default,{lo,hi}),function(v)
        if type(v)~="table" or not finite(v[1]) or not finite(v[2]) or v[1]>v[2] then return false end
        return true,{quantize(v[1],lo,hi,step),quantize(v[2],lo,hi,step)}
    end,function(v)
        local a,b=(v[1]-lo)/(hi-lo),(v[2]-lo)/(hi-lo)
        fill.Position=UDim2.fromScale(a,0)
        fill.Size=UDim2.fromScale(b-a,1)
        handles[1].Position=UDim2.fromScale(a,.5)
        handles[2].Position=UDim2.fromScale(b,.5)
        readout.Text=string.format("%g — %g",v[1],v[2])
    end)
    local selected, pointer
    beginControl(e,track,function(input)
        local v=e:GetValue()
        local x=lo+math.clamp((input.Position.X-track.AbsolutePosition.X)/math.max(1,track.AbsoluteSize.X),0,1)*(hi-lo)
        if pointer~=e._window._pointer then
            pointer=e._window._pointer
            selected=math.abs(x-v[1])<math.abs(x-v[2]) and 1 or 2
            if v[1]==v[2] and x<v[1] then selected=1 end
        end
        v[selected]=selected==1 and math.min(x,v[2]) or math.max(x,v[1])
        e:SetValue(v)
    end)
    return e
end

function Tab:CreateColorPicker(options)
    options=optionsOf(options)
    local e=self:_element(options,146)
    local preview=e:_button("",nil,UDim2.new(),UDim2.fromOffset(32,28))
    local hex=e:_textbox("","#RRGGBB",e._content,UDim2.fromOffset(40,0),UDim2.new(1,-40,0,28))
    e._edit=hex
    local sv=e:_button("",nil,UDim2.fromOffset(0,34),UDim2.new(1,-24,0,84))
    local white=create(e._scope,"Frame",{Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0},sv)
    create(e._scope,"UIGradient",{Transparency=NumberSequence.new(0,1)},white)
    local black=create(e._scope,"Frame",{Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.new(),BorderSizePixel=0},sv)
    create(e._scope,"UIGradient",{Rotation=90,Transparency=NumberSequence.new(1,0)},black)
    local hue=e:_button("",nil,UDim2.new(1,-18,0,34),UDim2.fromOffset(18,84))
    hue.BackgroundColor3=Color3.new(1,1,1)
    local keys={}
    for i=0,6 do table.insert(keys,ColorSequenceKeypoint.new(i/6,Color3.fromHSV(i/6,1,1))) end
    create(e._scope,"UIGradient",{Rotation=90,Color=ColorSequence.new(keys)},hue)
    local marker=create(e._scope,"Frame",{AnchorPoint=Vector2.new(.5,.5),Size=UDim2.fromOffset(10,10),BackgroundTransparency=1,ZIndex=4},sv)
    corner(e._scope,marker,5)
    create(e._scope,"UIStroke",{Color=Color3.new(1,1,1),Thickness=2},marker)
    local h,saturation,value=0,0,1
    local readout=label(e._scope,e._content,"",11,UDim2.fromOffset(0,122),UDim2.new(1,0,0,20))
    e:_state(firstDefined(options.CurrentValue,options.Default,options.Color,Color3.fromRGB(217,188,124)),function(v)
        if typeof(v)=="Color3" then return true,v end
        if type(v)=="string" and v:match("^#?%x%x%x%x%x%x$") then return true,Color3.fromHex((v:gsub("#",""))) end
        return false
    end,function(v)
        local nextHue, nextSat, nextValue=v:ToHSV()
        if nextSat>0 and nextValue>0 then h=nextHue end
        saturation,value=nextSat,nextValue
        sv.BackgroundColor3=Color3.fromHSV(h,1,1)
        preview.BackgroundColor3=v
        hex.Text="#"..v:ToHex()
        marker.Position=UDim2.fromScale(saturation,1-value)
        readout.Text=string.format("H %d°   S %d%%   V %d%%",h*360,saturation*100,value*100)
    end)
    e:_connect(hex.FocusLost,function()
        if not e:SetValue(hex.Text) then e._render(e:GetValue()) end
    end)
    beginControl(e,sv,function(input)
        local x=math.clamp((input.Position.X-sv.AbsolutePosition.X)/math.max(1,sv.AbsoluteSize.X),0,1)
        local y=math.clamp((input.Position.Y-sv.AbsolutePosition.Y)/math.max(1,sv.AbsoluteSize.Y),0,1)
        e:SetValue(Color3.fromHSV(h,x,1-y))
    end)
    beginControl(e,hue,function(input)
        h=math.clamp((input.Position.Y-hue.AbsolutePosition.Y)/math.max(1,hue.AbsoluteSize.Y),0,1)
        e:SetValue(Color3.fromHSV(h,saturation,value))
        e._render(e:GetValue())
    end)
    return e
end

function Window:_restoreExtraPreferences(prefs)
    if prefs.Size=="Custom" and finite(prefs.CustomWidth) and finite(prefs.CustomHeight) then
        self:SetSize(Vector2.new(prefs.CustomWidth,prefs.CustomHeight))
    end
    for _,key in ipairs({"Draggable","SidebarCollapsed","LowPerformance","Notifications"}) do
        if type(prefs[key])=="boolean" then
            local fields={Draggable="_draggable",SidebarCollapsed="_sidebarCollapsed",LowPerformance="_lowPerformance",Notifications="_notificationsEnabled"}
            self[fields[key]]=prefs[key]
            syncPreference(self,key,prefs[key])
        end
    end
    if finite(prefs.AnimationSpeed) then
        self._animationSpeed=math.clamp(prefs.AnimationSpeed,.05,.35)
        syncPreference(self,"AnimationSpeed",self._animationSpeed)
    end
    if finite(prefs.RefreshInterval) then
        self._refreshInterval=math.clamp(prefs.RefreshInterval,1,10)
        syncPreference(self,"RefreshInterval",self._refreshInterval)
    end
    self:_layout(false)
    if type(prefs.RememberPosition)=="boolean" then
        self._rememberPosition=prefs.RememberPosition
        syncPreference(self,"RememberPosition",prefs.RememberPosition)
    end
    if self._rememberPosition~=false then
        if type(prefs.WindowPosition)=="table" or type(prefs.CapsulePosition)=="table" then self._restoredPositions=true end
        self:_restorePosition(self._panel,prefs.WindowPosition)
        self:_restorePosition(self._capsule,prefs.CapsulePosition)
    end
end

function Window:SetAutoSave(enabled, profile)
    if not self:IsAlive() or type(enabled)~="boolean" then return false end
    profile=profile or self._autoProfile or "default"
    if not profileName(profile) then return false end
    self._autoSave=enabled
    self._autoProfile=profile
    local ok,raw=protected("AutoSave.baseline",self.ExportConfig,self)
    self._lastAutoExport=ok and raw or nil
    if self._autoSaveControl then self._autoSaveControl:SetValue(enabled,true) end
    return true
end

local function sameProfileJson(a,b)
    if a==b then return true end
    if type(a)~="string" or type(b)~="string" then return false end
    local ok,result=pcall(function()
        return equal(HttpService:JSONDecode(a),HttpService:JSONDecode(b))
    end)
    return ok and result==true
end

function Window:_startAutoSave()
    local function tick()
        if not self:IsAlive() then return end
        if self._autoSave then
            local ok,raw=protected("AutoSave.export",self.ExportConfig,self)
            if ok and not sameProfileJson(raw,self._lastAutoExport) then
                local saved=self:SaveConfig(self._autoProfile)
                if saved then self._lastAutoExport=raw end
            end
        end
        if self:IsAlive() then self._scope:Delay(5,tick) end
    end
    self._scope:Delay(5,tick)
end

-- Tooltips are explicit inline help controls, usable on touch as well as PC.
function Tab:CreateTooltip(options)
    options=optionsOf(options)
    local help=self:CreateParagraph({Name=options.Name or "Help",Content=options.Content or options.Desc or ""})
    help:SetVisible(false)
    local trigger=self:CreateButton({Name=options.Name or "Help",ButtonText="Show / hide",Callback=function()
        if help:IsAlive() then help:SetVisible(not help._row.Visible) end
    end})
    trigger._scope:Add(function() help:Destroy() end)
    return trigger
end

function Tab:CreateGroup(options)
    options=optionsOf(options)
    return self:CreateSection(options)
end

-- Subtabs use a separate navigation page, retaining the original tab API.
function Tab:CreateSubTab(options)
    options=optionsOf(options)
    local copy=clone(options)
    copy.Name=self.Name.." / "..text(copy.Name,"Subtab",30)
    return self._window:CreateTab(copy)
end

function Window:CreateLoading(options)
    if not self:IsAlive() then return nil end
    options=optionsOf(options)
    if self._loadingScope then self._loadingScope:Destroy() end
    if self._dialog then self._dialog:Destroy() end
    if self._popupOwner then self._popupOwner._closePopup() end
    self._pointer=nil
    local scope=self._scope:Child("Loading")
    self._loadingScope=scope
    scope:Add(function() if self._loadingScope==scope then self._loadingScope=nil end end)
    local overlay=create(scope,"TextButton",{Text="",AutoButtonColor=false,Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.new(),BackgroundTransparency=.35,ZIndex=40},self._root)
    local panel=create(scope,"Frame",{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.new(.85,0,0,110),BackgroundColor3=self._palette.Surface,ZIndex=41},overlay)
    corner(scope,panel,12)
    create(scope,"UISizeConstraint",{MaxSize=Vector2.new(320,110)},panel)
    local title=label(scope,panel,text(options.Title,"ScriptCenter",80),15,UDim2.fromOffset(12,8),UDim2.new(1,-24,0,24))
    title.ZIndex=42
    local caption=label(scope,panel,"",12,UDim2.fromOffset(12,36),UDim2.new(1,-24,0,24))
    caption.ZIndex=42
    local track=create(scope,"Frame",{Position=UDim2.fromOffset(12,72),Size=UDim2.new(1,-24,0,9),BackgroundColor3=self._palette.Control,ZIndex=42},panel)
    corner(scope,track,5)
    local bar=create(scope,"Frame",{Size=UDim2.fromScale(0,1),BackgroundColor3=self._palette.Accent,ZIndex=43},track)
    corner(scope,bar,5)
    local handle={}
    function handle:SetValue(v)
        if not scope.Alive or not finite(v) then return false end
        v=math.clamp(v,0,100)
        bar.Size=UDim2.fromScale(v/100,1)
        caption.Text=string.format("%d%%",math.floor(v))
        return true
    end
    function handle:SetText(v)
        if not scope.Alive or type(v)~="string" then return false end
        caption.Text=text(v,"",100)
        return true
    end
    function handle:Destroy() scope:Destroy() end
    handle:SetValue(options.Default or 0)
    -- A bounded lifetime prevents a forgotten overlay from blocking the game.
    local timeout=finite(options.Timeout) and math.clamp(options.Timeout,1,120) or 30
    scope:Delay(timeout,function() scope:Destroy() end)
    return handle
end


function Window:_buildSignature(gui,options)
    self._profileNamespace=tostring(game.GameId)..":"..tostring(game.PlaceId)
    if type(options.ConfigId)=="string" and profileName(options.ConfigId) then self._profileNamespace=self._profileNamespace..":"..options.ConfigId end
    local storage=options.Storage
    if type(storage)=="table" and type(storage.Read)=="function" and type(storage.Write)=="function" and type(storage.Delete)=="function" and type(storage.List)=="function" then self._storage=storage end
    local scope=self._scope
    self._colors={}
    self._tabs={}
    self._tabCount=0
    self._sizeMode="Auto"
    self._animation=true
    self._keybind=Enum.KeyCode.RightControl
    self:SetTheme("BlackGold")
    self._root=create(scope,"Frame",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1},gui)
    local panel=create(scope,"CanvasGroup",{Name="Signature",Size=UDim2.fromOffset(600,400),Position=UDim2.fromOffset(0,0),BorderSizePixel=0},self._root)
    self._panel=panel
    self:_bindColor(panel,"BackgroundColor3","Background")
    corner(scope,panel,14)
    local stroke=create(scope,"UIStroke",{Thickness=1,Transparency=0.35},panel)
    self:_bindColor(stroke,"Color","Accent")
    local header=create(scope,"Frame",{Size=UDim2.new(1,0,0,54),BorderSizePixel=0},panel)
    self:_bindColor(header,"BackgroundColor3","Surface")
    local separator=create(scope,"Frame",{Position=UDim2.new(0,12,1,-1),Size=UDim2.new(1,-24,0,1),BorderSizePixel=0,BackgroundTransparency=0.8},header)
    self:_bindColor(separator,"BackgroundColor3","Accent")
    local drag=create(scope,"Frame",{Size=UDim2.new(1,-132,1,0),BackgroundTransparency=1,Active=true},header)
    local fallback=label(scope,drag,"SC",14,UDim2.fromOffset(12,10),UDim2.fromOffset(34,34))
    fallback.TextXAlignment=Enum.TextXAlignment.Center
    self:_bindColor(fallback,"TextColor3","Accent")
    local logo=create(scope,"ImageLabel",{Image=LOGO,BackgroundTransparency=1,Position=UDim2.fromOffset(12,10),Size=UDim2.fromOffset(34,34)},drag)
    corner(scope,logo,9)
    scope:Connect(logo:GetPropertyChangedSignal("IsLoaded"),function() fallback.Visible=not logo.IsLoaded end)
    fallback.Visible=not logo.IsLoaded
    local brand=label(scope,drag,BRAND,15,UDim2.fromOffset(56,7),UDim2.new(1,-60,0,22))
    brand.Font=Enum.Font.GothamBold
    self:_bindColor(brand,"TextColor3","Accent")
    local subtitle=text(options.Game,"",60)
    local sub=label(scope,drag,subtitle~="" and subtitle or "Signature Interface",10,UDim2.fromOffset(56,29),UDim2.new(1,-60,0,16))
    self:_bindColor(sub,"TextColor3","Muted")
    local fold=button(scope,header,"≡",UDim2.new(1,-128,0,10),UDim2.fromOffset(28,34))
    local minimize=button(scope,header,"−",UDim2.new(1,-96,0,10),UDim2.fromOffset(28,34))
    local maximize=button(scope,header,"□",UDim2.new(1,-64,0,10),UDim2.fromOffset(28,34))
    local close=button(scope,header,"×",UDim2.new(1,-32,0,10),UDim2.fromOffset(28,34))
    self._sidebar=create(scope,"Frame",{Position=UDim2.fromOffset(0,54),Size=UDim2.new(0,145,1,-58),BorderSizePixel=0},panel)
    self:_bindColor(self._sidebar,"BackgroundColor3","Surface")
    self._nav=create(scope,"ScrollingFrame",{Position=UDim2.fromOffset(6,10),Size=UDim2.new(1,-12,1,-20),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y},self._sidebar)
    create(scope,"UIListLayout",{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},self._nav)
    self._content=create(scope,"Frame",{BackgroundTransparency=1,ClipsDescendants=true},panel)
    local grip=button(scope,panel,"◢",UDim2.new(1,-24,1,-24),UDim2.fromOffset(24,24))
    grip.ZIndex=5
    local capsule=create(scope,"Frame",{Size=UDim2.fromOffset(148,36),Position=UDim2.fromOffset(12,12),BorderSizePixel=0,Active=true,Visible=false},self._root)
    self._capsule=capsule
    self:_bindColor(capsule,"BackgroundColor3","Surface")
    corner(scope,capsule,18)
    local cs=create(scope,"UIStroke",{Thickness=1,Transparency=0.2},capsule)
    self:_bindColor(cs,"Color","Accent")
    local capLogo=create(scope,"ImageLabel",{Image=LOGO,Size=UDim2.fromOffset(26,26),Position=UDim2.fromOffset(5,5),BackgroundTransparency=1},capsule)
    corner(scope,capLogo,13)
    local capFallback=label(scope,capsule,"SC",10,UDim2.fromOffset(5,5),UDim2.fromOffset(26,26))
    capFallback.TextXAlignment=Enum.TextXAlignment.Center
    self:_bindColor(capFallback,"TextColor3","Accent")
    scope:Connect(capLogo:GetPropertyChangedSignal("IsLoaded"),function() capFallback.Visible=not capLogo.IsLoaded end)
    capFallback.Visible=not capLogo.IsLoaded
    local capText=label(scope,capsule,BRAND,12,UDim2.fromOffset(36,0),UDim2.new(1,-56,1,0))
    local capArrow=label(scope,capsule,"▾",12,UDim2.new(1,-17,0,0),UDim2.fromOffset(13,36))
    self:_bindColor(capArrow,"TextColor3","Accent")
    self._capsuleArrow=capArrow
    capText.Font=Enum.Font.GothamMedium
    self:_bindColor(capText,"TextColor3","Accent")
    self:_initInput()
    self:_attachDrag(drag,panel,"Move")
    self:_attachDrag(grip,panel,"Resize")
    self:_attachDrag(capsule,capsule,"Move",function() self:SetVisible(true) end)
    scope:Connect(fold.Activated,function()
        self._sidebarCollapsed=not self._sidebarCollapsed
        self:_layout(false)
        local control=self._preferenceControls and self._preferenceControls.SidebarCollapsed
        if control then control:SetValue(self._sidebarCollapsed,true) end
    end)
    scope:Connect(minimize.Activated,function() self:SetVisible(false) end)
    scope:Connect(maximize.Activated,function() self._maximized=not self._maximized; self:_layout(true) end)
    scope:Connect(close.Activated,function()
        self:Confirm({Title="Unload interface?",Callback=function() self:Destroy() end})
    end)
    scope:Connect(self._root:GetPropertyChangedSignal("AbsoluteSize"),function() self:_layout(false) end)
    self._language="English"
    self._opacity=100
    self._animationSpeed=0.15
    self._capsuleMode="Full"
    self._draggable=true
    self._refreshInterval=1
    self._lowPerformance=false
    self._capsuleText=capText
    local home=self:CreateTab({Name="Home"})
    local settings=self:CreateTab({Name="Settings"})
    self:_buildHome(home,options)
    self:_buildSettings(settings)
    scope:Delay(0,function()
        if not self._restoredPositions then self:Center(); self:ResetCapsulePosition() end
    end)
    self:SelectTab("Home")
    self._notificationHost=create(self._scope,"Frame",{AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,-10,1,-10),Size=UDim2.fromOffset(245,214),BackgroundTransparency=1},self._root)
    create(self._scope,"UIListLayout",{VerticalAlignment=Enum.VerticalAlignment.Bottom,Padding=UDim.new(0,6)},self._notificationHost)
    self._tabs.Settings:CreateConfigManager()
    local search=self:CreateTab({Name="Search",Icon="list"})
    local input=search:CreateInput({Name="Find features",Default="",Placeholder="Search all tabs"})
    local results={}
    search:CreateButton({Name="Search",Callback=function()
        for _,e in ipairs(results) do e:Destroy() end
        table.clear(results)
        local found=self:Search(input:GetValue())
        for i=1,math.min(#found,50) do
            local item=found[i]
            table.insert(results,search:CreateButton({Name=item.Tab.." / "..item.Name,Callback=function()
                if item.Element:IsAlive() then
                    self:SelectTab(item.Tab)
                    local page=self._tabs[item.Tab].Page
                    page.CanvasPosition=Vector2.new(0,math.max(0,item.Element._row.AbsolutePosition.Y-page.AbsolutePosition.Y+page.CanvasPosition.Y))
                end
            end}))
        end
        if #found==0 then table.insert(results,search:CreateLabel("No results")) end
    end})
    self:SelectTab("Home")
    self._notificationsEnabled=true
    local settings=self._tabs.Settings
    self._preferenceControls.Notifications=settings:CreateToggle({Name="Notifications",Default=true,Callback=function(v) self._notificationsEnabled=v end})
    self:_localized(self._preferenceControls.Notifications,"Notifications","การแจ้งเตือน")
    local config=options.ConfigurationSaving
    local profile=type(config)=="table" and config.FileName or "default"
    if not profileName(profile) then profile="default" end
    local enable=type(config)=="table" and config.Enabled~=false and config.AutoSave==true
    self:SetAutoSave(enable,profile)
    local toggle=settings:CreateToggle({Name="Auto save (selected profile)",Default=enable,Callback=function(v) self:SetAutoSave(v) end})
    self._autoSaveControl=toggle
    self:_localized(toggle,"Auto save (selected profile)","บันทึกอัตโนมัติ (โปรไฟล์ที่เลือก)")
    self:_startAutoSave()
end

-- Explicit Studio test runner; it creates and destroys a temporary window.
function SC:RunUITests()
    assert(not active,"Close the current window before running UI tests")
    local results={}
    local w
    local function test(name,fn)
        local ok,err=pcall(fn)
        local result={Name=name,Passed=ok}
        if not ok then result.Error=tostring(err) end
        table.insert(results,result)
    end
    test("Create window",function() w=self:CreateWindow() end)
    if not w then return results end
    local tab
    test("Create tab",function() tab=w:CreateTab("Test") end)
    if not tab then w:Destroy(); return results end
    test("Toggle and duplicate flags",function()
        local t=tab:CreateToggle({Name="Test",Flag="test",Default=false})
        assert(t:SetValue(true,true) and t:GetValue()==true)
        assert(not pcall(function() tab:CreateToggle({Flag="test"}) end))
        assert(not t:SetValue("invalid",true))
    end)
    test("Range clamp",function()
        local r=tab:CreateRangeSlider({Min=0,Max=100,Default={20,80}})
        assert(r:SetValue({-1,101},true))
        assert(r:GetValue()[1]==0 and r:GetValue()[2]==100)
    end)
    test("Color validation",function()
        local c=tab:CreateColorPicker({Default="#D9BC7C"})
        assert(c:SetValue("#FF0000",true))
        assert(not c:SetValue("bad",true))
    end)
    test("Profile round trip",function()
        local raw=w:ExportConfig()
        assert(w:ImportConfig(raw,false))
        assert(not w:ImportConfig("{broken",false))
    end)
    test("Theme and visibility",function()
        for _,name in ipairs({"Midnight","Emerald","Classic","BlackGold"}) do assert(w:SetTheme(name)) end
        for i=1,100 do w:SetVisible(false); w:SetVisible(true) end
    end)
    test("Loading cleanup",function()
        local loading=w:CreateLoading({Default=25})
        assert(loading:SetValue(100))
        loading:Destroy()
        assert(not loading:SetValue(0))
    end)
    test("Profile equality",function()
        assert(sameProfileJson('{"a":1,"b":2}','{"b":2,"a":1}'))
        assert(not sameProfileJson('{"a":1}','{"a":2}'))
    end)
    test("Tab lifecycle",function()
        local temporary=w:CreateTab("Temporary")
        local control=temporary:CreateToggle({Flag="temporary",Default=false})
        assert(w:SelectTab("Temporary"))
        assert(temporary:Destroy())
        assert(not control:IsAlive())
        assert(w._state.Entries.temporary==nil)
        assert(not w:SelectTab("Temporary"))
    end)
    test("Destroy",function()
        w:Destroy()
        assert(not w:IsAlive())
        assert(w._scope:Size()==0)
    end)
    if w:IsAlive() then w:Destroy() end
    return results
end

return SC
