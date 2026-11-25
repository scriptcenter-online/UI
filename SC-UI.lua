local SC = {}
SC.Version = "1.1.0"
local BRAND = "ScriptCenter"
local LOGO = "rbxassetid://97517292167647"
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

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

local UIS = game:GetService("UserInputService")
local Themes = {
    BlackGold = {19,19,22, 27,27,31, 218,189,126},
}
local Sizes = {Compact = Vector2.new(420,300), Small = Vector2.new(480,340), Medium = Vector2.new(600,400), Large = Vector2.new(720,480)}
local function corner(scope, object, radius)
    return create(scope, "UICorner", {CornerRadius = UDim.new(0,radius)}, object)
end
local IconPaths = {
    ["home"] = {{3,10,12,3},{12,3,21,10},{6,9,6,21},{18,9,18,21},{6,21,18,21},{10,21,10,15},{10,15,14,15},{14,15,14,21}},
    ["settings"] = {{12,2,12,6},{12,18,12,22},{2,12,6,12},{18,12,22,12},{5,5,8,8},{16,16,19,19},{5,19,8,16},{16,8,19,5},{8,8,16,8},{16,8,16,16},{16,16,8,16},{8,16,8,8}},
    ["user"] = {{8,4,16,4},{16,4,18,9},{18,9,12,13},{12,13,6,9},{6,9,8,4},{4,21,4,18},{4,18,8,15},{8,15,16,15},{16,15,20,18},{20,18,20,21}},
    ["list"] = {{5,6,21,6},{5,12,21,12},{5,18,21,18},{2,6,3,6},{2,12,3,12},{2,18,3,18}},
    ["box"] = {{4,4,20,4},{20,4,20,20},{20,20,4,20},{4,20,4,4},{4,8,20,8}},
    ["activity"] = {{2,12,7,12},{7,12,10,5},{10,5,14,19},{14,19,17,12},{17,12,22,12}},
    ["search"] = {{5,4,14,4},{14,4,18,8},{18,8,18,13},{18,13,14,17},{14,17,5,17},{5,17,2,13},{2,13,2,8},{2,8,5,4},{16,15,22,21}},
    ["gamepad"] = {{5,7,19,7},{19,7,22,17},{22,17,19,20},{19,20,15,16},{15,16,9,16},{9,16,5,20},{5,20,2,17},{2,17,5,7},{5,11,11,11},{8,8,8,14},{16,11,18,11}},
    ["folder"] = {{3,6,10,6},{10,6,12,9},{12,9,21,9},{21,9,21,20},{21,20,3,20},{3,20,3,6}},
    ["shield"] = {{12,3,21,7},{21,7,19,16},{19,16,12,21},{12,21,5,16},{5,16,3,7},{3,7,12,3}},
    ["zap"] = {{13,2,4,13},{4,13,11,13},{11,13,10,22},{10,22,20,10},{20,10,13,10},{13,10,13,2}},
    ["code"] = {{8,5,2,12},{2,12,8,19},{16,5,22,12},{22,12,16,19},{14,4,10,20}},
    ["menu"] = {{4,6,20,6},{4,12,20,12},{4,18,20,18}},
    ["minus"] = {{5,12,19,12}},
    ["maximize"] = {{5,5,19,5},{19,5,19,19},{19,19,5,19},{5,19,5,5}},
    ["close"] = {{5,5,19,19},{19,5,5,19}},
    ["resize"] = {{9,20,20,9},{15,20,20,15}},
    ["chevron"] = {{6,9,12,15},{12,15,18,9}},
    ["heart"] = {{12,21,3,12},{3,12,3,7},{3,7,7,4},{7,4,12,8},{12,8,17,4},{17,4,21,7},{21,7,21,12},{21,12,12,21}},
    ["star"] = {{12,2,15,9},{15,9,22,9},{22,9,17,14},{17,14,19,22},{19,22,12,17},{12,17,5,22},{5,22,7,14},{7,14,2,9},{2,9,9,9},{9,9,12,2}},
}
local IconAliases = { ["list-checks"]="list", gift="box", egg="box", dna="activity", bug="activity", clock="activity", globe="search" }
local function drawIcon(scope,parent,name,position,size,color)
    local holder=create(scope,"Frame",{BackgroundTransparency=1,Position=position,Size=UDim2.fromOffset(size,size)},parent)
    local path=IconPaths[IconAliases[name] or name] or IconPaths.folder
    for _,seg in ipairs(path) do
        local x,y,u,v=table.unpack(seg)
        local dx,dy=u-x,v-y
        local line=create(scope,"Frame",{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale((x+u)/48,(y+v)/48),Size=UDim2.fromOffset(math.sqrt(dx*dx+dy*dy)*size/24+0.7,1.6),Rotation=math.deg(math.atan2(dy,dx)),BackgroundColor3=color,BorderSizePixel=0},holder)
        corner(scope,line,2)
    end
    return holder
end
local function tintIcon(holder,color)
    for _,line in ipairs(holder:GetChildren()) do
        if line:IsA("Frame") then line.BackgroundColor3=color end
    end
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
    corner(scope, object, 10)
    return object
end
function Window:_bindColor(object, property, role)
    for _, binding in ipairs(self._colors) do
        if binding.Object==object and binding.Property==property then
            binding.Role=role
            object[property]=self._palette[role]
            return
        end
    end
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
    if self._theme == name then return true end
    local t = Themes[name]
    self._theme = name
    self._palette = {
        Background = Color3.fromRGB(t[1],t[2],t[3]),
        Surface = Color3.fromRGB(t[4],t[5],t[6]),
        Accent = Color3.fromRGB(t[7],t[8],t[9]),
        Text = Color3.fromRGB(235,235,239),
        Muted = Color3.fromRGB(174,174,184),
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
    local margin = math.min(6, math.max(0, (math.min(bounds.X,bounds.Y)-1)/2))
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
    self._capsule.Size = UDim2.fromOffset(math.min(self._capsuleMode=="Logo only" and 44 or 166,math.max(1,bounds.X-12)),math.min(44,math.max(1,bounds.Y-12)))
    local compact = width < 360 or self._sidebarCollapsed
    if self._notificationHost then
        self._notificationHost.Size = UDim2.fromOffset(math.min(245,math.max(1,bounds.X-20)),214)
    end
    local fullCapsule = self._capsuleMode ~= "Logo only" and self._capsule.Size.X.Offset >= 130
    if self._capsuleText then self._capsuleText.Visible = fullCapsule end
    if self._capsuleArrow then self._capsuleArrow.Visible = fullCapsule end
    local sidebarWidth = compact and 52 or (width < 500 and 110 or 144)
    self._sidebar.Size = UDim2.new(0,sidebarWidth,1,-76)
    self._content.Position = UDim2.fromOffset(sidebarWidth+24,66)
    self._content.Size = UDim2.new(1,-sidebarWidth-36,1,-78)
    for _, entry in pairs(self._tabs) do
        entry.Button.Text = ""
        entry.IconLabel.Position = compact and UDim2.new(0.5,-10,0.5,-10) or UDim2.new(0,9,0.5,-10)
        entry.NameLabel.Visible = not compact
    end
    local current = self._panel.Position
    self:_place(self._panel,(center or self._maximized) and Vector2.new((bounds.X-width)/2,(bounds.Y-height)/2) or Vector2.new(current.X.Offset,current.Y.Offset))
    local cp = self._capsule.Position
    self:_place(self._capsule,Vector2.new(cp.X.Offset,cp.Y.Offset))
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
    self:_layout(type(mode)=="string")
    return true
end
function Window:Center()
    if not self:IsAlive() then return false end
    self:_layout(true)
    return true
end
function Window:GetSize()
    if not self:IsAlive() then return nil end
    return self._sizeMode, Vector2.new(self._panel.Size.X.Offset,self._panel.Size.Y.Offset)
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
    if not self:IsAlive() then return false end
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
function Window:_attachDrag(handle, object, mode, tap)
    self._scope:Connect(handle.InputBegan,function(input)
        local kind = input.UserInputType
        if self._dialog or self._loadingScope then return end
        if object==self._panel and mode=="Resize" and self._maximized then return end
        if object==self._panel and mode=="Move" and (self._draggable==false or self._maximized) then return end
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
        tintIcon(entry.IconLabel,key == name and self._palette.Accent or self._palette.Muted)
        entry.NameLabel.TextColor3 = key == name and self._palette.Accent or self._palette.Text
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
    tabButton.LayoutOrder = self._tabCount
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
    local icon = type(options.Icon)=="string" and string.lower(options.Icon) or string.lower(name)
    local entry={Name=name,Page=page,Button=tabButton,_scope=scope,_window=self}
    entry.Title=title
    tabButton.Text=""
    entry.IconLabel=drawIcon(scope,tabButton,icon,UDim2.new(0,9,0.5,-10),20,self._palette.Muted)
    entry.NameLabel=label(scope,tabButton,name,13,UDim2.fromOffset(38,0),UDim2.new(1,-44,1,0))
    entry.NameLabel.Font=Enum.Font.GothamMedium
    entry.Indicator=create(scope,"Frame",{Size=UDim2.fromOffset(3,22),Position=UDim2.fromOffset(0,7),BorderSizePixel=0,Visible=false},tabButton)
    corner(scope,entry.Indicator,2)
    self:_bindColor(entry.Indicator,"BackgroundColor3","Accent")
    self._tabs[name]=entry
    scope:Connect(tabButton.Activated,function() self:SelectTab(name) end)
    if not self._selected then self:SelectTab(name) end
    self:_layout(false)
    return setmetatable(entry,Tab)
end


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
    if self._compactToggle and value~="" then
        self._compactToggle=false
        self._row.AutomaticSize=Enum.AutomaticSize.Y
        self._row.Size=UDim2.new(1,self._row.Size.X.Offset,0,0)
        self._title.Size=UDim2.new(1,0,0,20)
        self._content.Position=UDim2.new()
        self._content.Size=UDim2.new(1,0,0,30)
        create(self._scope,"UIListLayout",{Padding=UDim.new(0,5),SortOrder=Enum.SortOrder.LayoutOrder},self._row)
    end
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
        Size=UDim2.new(1,self._container and 0 or -8,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        BorderSizePixel=0,
    },self.Page)
    w:_bindColor(row,"BackgroundColor3","Surface")
    corner(scope,row,12)
    if self._container then row.BackgroundTransparency=1 end
    create(scope,"UIStroke",{Color=Color3.fromRGB(63,58,49),Transparency=self._container and 1 or 0.78,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},row)
    create(scope,"UIPadding",{PaddingTop=UDim.new(0,8),PaddingBottom=UDim.new(0,8),PaddingLeft=UDim.new(0,12),PaddingRight=UDim.new(0,12)},row)
    create(scope,"UIListLayout",{Padding=UDim.new(0,5),SortOrder=Enum.SortOrder.LayoutOrder},row)
    local title=label(scope,row,text(options.Name or options.Title,"Feature",200),13,UDim2.new(),UDim2.new(1,0,0,20))
    title.Font=Enum.Font.GothamMedium
    title.LayoutOrder=1
    w:_bindColor(title,"TextColor3","Text")
    local desc=label(scope,row,text(options.Desc or options.Description,"",1000),12,UDim2.new(),UDim2.new(1,0,0,0))
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
    e._tabName=self._tabName or self.Name
    e._systemControl=false
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
    corner(self._scope,box,9)
    create(self._scope,"UIStroke",{Color=Color3.fromRGB(100,89,66),Transparency=0.65,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},box)
    create(self._scope,"UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},box)
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
    options=optionsOf(options)
    local e=self:_element(options,0)
    if options.Text~=nil then e:SetDescription(tostring(options.Text)) end
    return e
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
        if e._callback and not e._buttonBusy then
            e._buttonBusy=true
            e._scope:Spawn(function()
                protected("Button.callback",e._callback)
                e._buttonBusy=false
            end)
        end
    end)
    return e
end

function Tab:CreateToggle(options)
    local e=self:_element(options,30)
    if e._description.Text=="" then
        local layout=e._row:FindFirstChildOfClass("UIListLayout")
        if layout then e._scope:Remove(layout) end
        e._row.AutomaticSize=Enum.AutomaticSize.None
        e._row.Size=UDim2.new(1,self._container and 0 or -8,0,50)
        e._title.Size=UDim2.new(1,-112,0,30)
        e._content.Position=UDim2.new(1,-104,0,0)
        e._content.Size=UDim2.fromOffset(104,30)
        e._compactToggle=true
    end
    local b=e:_button("",nil,UDim2.new(1,-48,0,2),UDim2.fromOffset(48,26))
    b.AutoButtonColor=false
    local shape=b:FindFirstChildOfClass("UICorner")
    shape.CornerRadius=UDim.new(1,0)
    local knob=create(e._scope,"Frame",{Size=UDim2.fromOffset(18,18),Position=UDim2.fromOffset(4,4),BackgroundColor3=Color3.fromRGB(225,225,231),BorderSizePixel=0},b)
    corner(e._scope,knob,9)
    local status=label(e._scope,e._content,"Off",12,UDim2.new(),UDim2.new(1,-58,1,0))
    e:_state(firstDefined(e._options.CurrentValue,e._options.Default,false),function(v) return type(v)=="boolean",v end,function(v)
        status.Text=v and "On" or "Off"
        status.TextColor3=v and e._window._palette.Accent or e._window._palette.Muted
        b.BackgroundColor3=v and e._window._palette.Accent or e._window._palette.Control
        knob.BackgroundColor3=v and Color3.fromRGB(43,35,23) or Color3.fromRGB(225,225,231)
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
    local track=e:_button("",nil,UDim2.fromOffset(8,24),UDim2.new(1,-16,0,8))
    track.AutoButtonColor=false
    local fill=create(e._scope,"Frame",{Size=UDim2.fromScale(0,1),BorderSizePixel=0},track)
    e._window:_bindColor(fill,"BackgroundColor3","Accent")
    corner(e._scope,fill,5)
    local thumb=create(e._scope,"Frame",{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0,0.5),Size=UDim2.fromOffset(16,16),BorderSizePixel=0,BackgroundColor3=Color3.fromRGB(245,225,183),ZIndex=track.ZIndex+2},track)
    corner(e._scope,thumb,8)
    local value=label(e._scope,e._content,"",12,UDim2.new(),UDim2.new(1,-82,0,18))
    local edit=e:_textbox("","",e._content,UDim2.new(1,-76,0,0),UDim2.fromOffset(76,20))
    e._edit=edit
    e:_state(firstDefined(options.CurrentValue,options.Default,lo),function(v)
        return finite(v),finite(v) and quantize(v,lo,hi,step) or nil
    end,function(v)
        value.Text=string.format("%g / %g",v,hi)
        edit.Text=string.format("%g",v)
        fill.Size=UDim2.fromScale((v-lo)/(hi-lo),1)
        thumb.Position=UDim2.fromScale((v-lo)/(hi-lo),0.5)
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
    e:_state(firstDefined(options.CurrentKeybind,options.CurrentValue,options.Default,"F6"),validate,function(v) b.Text=v end)
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

local Container = {}
Container.__index = function(_, key) return Container[key] or Tab[key] end

local function makeContainer(tab, options, collapsible)
    options = optionsOf(options)
    local e = tab:_element(options, 0)
    if options.Content then e:SetDescription(tostring(options.Content)) end
    e._title.Font = Enum.Font.GothamBold
    e._window:_bindColor(e._title,"TextColor3","Accent")
    local body = create(e._scope,"Frame",{
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        BackgroundTransparency=1,LayoutOrder=5,
    },e._row)
    create(e._scope,"UIListLayout",{Padding=UDim.new(0,7),SortOrder=Enum.SortOrder.LayoutOrder},body)
    local c=setmetatable({_container=true,_scope=e._scope,_window=e._window,
        _elementHandle=e,Name=tab.Name,_tabName=tab._tabName or tab.Name,Page=body},Container)
    if collapsible then
        local trigger=button(e._scope,e._row,"",UDim2.new(),UDim2.new(1,0,0,28))
        trigger.LayoutOrder=4
        e._window:_bindColor(trigger,"BackgroundColor3","Control")
        c._trigger=trigger
        e._scope:Connect(trigger.Activated,function() c:SetExpanded(not body.Visible) end)
        c:SetExpanded(options.Expanded~=false)
    end
    return c
end
function Container:IsAlive() return self._elementHandle:IsAlive() end
function Container:Destroy() self._elementHandle:Destroy() end
function Container:SetText(v) return self._elementHandle:SetText(v) end
function Container:SetDescription(v) return self._elementHandle:SetDescription(v) end
function Container:SetVisible(v) return self._elementHandle:SetVisible(v) end
function Container:SetExpanded(v)
    if not self:IsAlive() or type(v)~="boolean" then return false end
    self.Page.Visible=v
    if self._trigger then self._trigger.Text=v and "−  Collapse" or "+  Expand" end
    if not v then
        local w=self._window
        if w._popupOwner and w._popupOwner._row:IsDescendantOf(self.Page) then w._popupOwner._closePopup() end
        if w._pointer and w._pointer.Owner and w._pointer.Owner._row:IsDescendantOf(self.Page) then w._pointer=nil end
    end
    return true
end
function Tab:CreateCard(options) return makeContainer(self,options,false) end
function Tab:CreateCollapsible(options) return makeContainer(self,options,true) end

function Tab:Select()
    return self._window:SelectTab(self.Name)
end

function Tab:Destroy()
    if not self._scope.Alive then return end
    local w=self._window
    w._tabs[self.Name]=nil
    self._scope:Destroy()
    if w._selected==self.Name then
        w._selected=nil
        local nextTab=next(w._tabs)
        if nextTab then w:SelectTab(nextTab) end
    end
    return true
end

function Window:SetKeybind(value)
    if not self:IsAlive() then return false end
    if typeof(value)=="EnumItem" and value.EnumType==Enum.KeyCode then value=value.Name end
    if type(value)~="string" then return false end
    local ok,key=pcall(function() return Enum.KeyCode[value] end)
    if not ok or not key or key==Enum.KeyCode.Unknown then return false end
    self._keybind=key
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

function Window:Notify(options)
    if not self:IsAlive() or self._notificationsEnabled==false then return end
    options=optionsOf(options)
    local scope=self._scope:Child("Notification")
    local frame=create(scope,"Frame",{Size=UDim2.new(1,0,0,66),BackgroundColor3=self._palette.Surface,BorderSizePixel=0},self._notificationHost)
    corner(scope,frame,14)
    create(scope,"UIStroke",{Color=self._palette.Accent,Transparency=.65,Thickness=1},frame)
    local accent=create(scope,"Frame",{Position=UDim2.fromOffset(4,12),Size=UDim2.new(0,3,1,-24),BackgroundColor3=self._palette.Accent,BorderSizePixel=0},frame)
    corner(scope,accent,2)
    local title=label(scope,frame,text(options.Title,BRAND,80),14,UDim2.fromOffset(10,5),UDim2.new(1,-38,0,23))
    title.TextColor3=self._palette.Accent
    local content=label(scope,frame,text(options.Content or options.Description,"",240),11,UDim2.fromOffset(10,29),UDim2.new(1,-20,0,32))
    content.TextWrapped=true
    local close=button(scope,frame,"",UDim2.new(1,-26,0,3),UDim2.fromOffset(23,23))
    drawIcon(scope,close,"close",UDim2.new(.5,-7,.5,-7),14,self._palette.Muted)
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
    self._keyCapture=nil
    if self._loadingScope then self._loadingScope:Destroy() end
    if self._popupOwner then self._popupOwner._closePopup() end
    self._pointer=nil
    local scope=self._scope:Child("Dialog")
    self._dialog=scope
    scope:Add(function() if self._dialog==scope then self._dialog=nil end end)
    local overlay=create(scope,"TextButton",{Text="",Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.new(),BackgroundTransparency=0.35,AutoButtonColor=false,ZIndex=30},self._root)
    local panel=create(scope,"Frame",{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.new(0.9,0,0,150),BackgroundColor3=self._palette.Surface,ZIndex=31},overlay)
    create(scope,"UISizeConstraint",{MaxSize=Vector2.new(340,150)},panel)
    corner(scope,panel,16)
    create(scope,"UIStroke",{Color=self._palette.Accent,Transparency=.55,Thickness=1},panel)
    local title=label(scope,panel,text(options.Title,"Confirm",100),16,UDim2.fromOffset(12,8),UDim2.new(1,-24,0,28)); title.ZIndex=32
    local body=label(scope,panel,text(options.Content,"Continue?",250),12,UDim2.fromOffset(12,40),UDim2.new(1,-24,0,55)); body.TextWrapped=true; body.ZIndex=32
    local yes=button(scope,panel,text(options.ConfirmText,"Confirm",24),UDim2.new(.5,4,1,-42),UDim2.new(.5,-16,0,32)); yes.ZIndex=32
    yes.BackgroundColor3=self._palette.Accent; yes.TextColor3=Color3.fromRGB(25,22,17)
    local no=button(scope,panel,text(options.CancelText,"Cancel",24),UDim2.new(0,12,1,-42),UDim2.new(.5,-16,0,32)); no.ZIndex=32
    scope:Connect(no.Activated,function() scope:Destroy() end)
    scope:Connect(yes.Activated,function()
        scope:Destroy()
        if type(options.Callback)=="function" then protected("Dialog.callback",options.Callback) end
    end)
end
function SC:Confirm(options)
    if active then return active:Confirm(options) end
end
function Window:GetValues()
    if not self:IsAlive() then return {} end
    return self._state:Snapshot()
end

function Window:GetValue(flag)
    if not self:IsAlive() then return nil end
    return self._state:Get(flag)
end

function Window:SetValue(flag,value,silent)
    if not self:IsAlive() then return false,"Window closed" end
    for element in pairs(self._elements or {}) do
        if element._flag==flag and element:IsAlive() then
            return element:SetValue(value,silent)
        end
    end
    return false,"Unknown flag"
end

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
    return makeContainer(self,options,false)
end

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
    corner(scope,panel,16)
    create(scope,"UIStroke",{Color=self._palette.Accent,Transparency=.55,Thickness=1},panel)
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
    local timeout=finite(options.Timeout) and math.clamp(options.Timeout,1,120) or 30
    scope:Delay(timeout,function() scope:Destroy() end)
    return handle
end


function Window:_buildSignature(gui,options)
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
    corner(scope,panel,18)
    local stroke=create(scope,"UIStroke",{Thickness=1,Transparency=0.35},panel)
    self:_bindColor(stroke,"Color","Accent")
    local header=create(scope,"Frame",{Position=UDim2.fromOffset(8,8),Size=UDim2.new(1,-16,0,48),BorderSizePixel=0},panel)
    self:_bindColor(header,"BackgroundColor3","Surface")
    corner(scope,header,13)
    local separator=create(scope,"Frame",{Position=UDim2.new(0,12,1,-1),Size=UDim2.new(1,-24,0,1),BorderSizePixel=0,BackgroundTransparency=0.8},header)
    self:_bindColor(separator,"BackgroundColor3","Accent")
    local drag=create(scope,"Frame",{Size=UDim2.new(1,-132,1,0),BackgroundTransparency=1,Active=true},header)
    local fallback=label(scope,drag,"SC",14,UDim2.fromOffset(10,7),UDim2.fromOffset(34,34))
    fallback.TextXAlignment=Enum.TextXAlignment.Center
    self:_bindColor(fallback,"TextColor3","Accent")
    local logo=create(scope,"ImageLabel",{Image=LOGO,BackgroundTransparency=1,Position=UDim2.fromOffset(10,7),Size=UDim2.fromOffset(34,34)},drag)
    corner(scope,logo,9)
    scope:Connect(logo:GetPropertyChangedSignal("IsLoaded"),function() fallback.Visible=not logo.IsLoaded end)
    fallback.Visible=not logo.IsLoaded
    local brand=label(scope,drag,BRAND,15,UDim2.fromOffset(56,7),UDim2.new(1,-60,0,22))
    brand.Font=Enum.Font.GothamBold
    self:_bindColor(brand,"TextColor3","Accent")
    local subtitle=text(options.Game or options.Name or options.Title,"",60)
    local sub=label(scope,drag,subtitle~="" and subtitle or "Signature Interface",10,UDim2.fromOffset(56,29),UDim2.new(1,-60,0,16))
    self:_bindColor(sub,"TextColor3","Muted")
    local fold=button(scope,header,"≡",UDim2.new(1,-128,0,9),UDim2.fromOffset(28,30))
    local minimize=button(scope,header,"−",UDim2.new(1,-96,0,9),UDim2.fromOffset(28,30))
    local maximize=button(scope,header,"□",UDim2.new(1,-64,0,9),UDim2.fromOffset(28,30))
    local close=button(scope,header,"×",UDim2.new(1,-32,0,9),UDim2.fromOffset(28,30))
    for _,item in ipairs({{fold,"menu"},{minimize,"minus"},{maximize,"maximize"},{close,"close"}}) do
        item[1].Text=""
        drawIcon(scope,item[1],item[2],UDim2.new(.5,-8,.5,-8),16,self._palette.Muted)
    end
    self._sidebar=create(scope,"Frame",{Position=UDim2.fromOffset(10,66),Size=UDim2.new(0,144,1,-76),BorderSizePixel=0},panel)
    self:_bindColor(self._sidebar,"BackgroundColor3","Surface")
    corner(scope,self._sidebar,12)
    self._nav=create(scope,"ScrollingFrame",{Position=UDim2.fromOffset(6,10),Size=UDim2.new(1,-12,1,-20),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y},self._sidebar)
    create(scope,"UIListLayout",{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},self._nav)
    self._content=create(scope,"Frame",{BackgroundTransparency=1,ClipsDescendants=true},panel)
    local grip=button(scope,panel,"◢",UDim2.new(1,-24,1,-24),UDim2.fromOffset(24,24))
    grip.Text=""
    local gripIcon=drawIcon(scope,grip,"resize",UDim2.fromOffset(4,4),16,self._palette.Muted)
    grip.ZIndex=5
    gripIcon.ZIndex=6
    for _,part in ipairs(gripIcon:GetChildren()) do if part:IsA("Frame") then part.ZIndex=6 end end
    local capsule=create(scope,"Frame",{Size=UDim2.fromOffset(166,44),Position=UDim2.fromOffset(12,12),BorderSizePixel=0,Active=true,Visible=false},self._root)
    self._capsule=capsule
    self:_bindColor(capsule,"BackgroundColor3","Surface")
    corner(scope,capsule,22)
    capsule.ClipsDescendants=true
    local cs=create(scope,"UIStroke",{Thickness=1,Transparency=0.2},capsule)
    self:_bindColor(cs,"Color","Accent")
    local capLogo=create(scope,"ImageLabel",{Image=LOGO,Size=UDim2.fromOffset(32,32),Position=UDim2.fromOffset(6,6),ScaleType=Enum.ScaleType.Fit,BackgroundTransparency=1},capsule)
    corner(scope,capLogo,16)
    local capFallback=label(scope,capsule,"SC",10,UDim2.fromOffset(6,6),UDim2.fromOffset(32,32))
    capFallback.TextXAlignment=Enum.TextXAlignment.Center
    self:_bindColor(capFallback,"TextColor3","Accent")
    scope:Connect(capLogo:GetPropertyChangedSignal("IsLoaded"),function() capFallback.Visible=not capLogo.IsLoaded end)
    capFallback.Visible=not capLogo.IsLoaded
    local capText=label(scope,capsule,BRAND,12,UDim2.fromOffset(46,0),UDim2.new(1,-68,1,0))
    local capArrow=drawIcon(scope,capsule,"chevron",UDim2.new(1,-23,0.5,-8),16,self._palette.Accent)
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
    end)
    scope:Connect(minimize.Activated,function() self:SetVisible(false) end)
    scope:Connect(maximize.Activated,function() self._maximized=not self._maximized; self:_layout(true) end)
    scope:Connect(close.Activated,function()
        self:Confirm({Title="Unload interface?",Callback=function() self:Destroy() end})
    end)
    scope:Connect(self._root:GetPropertyChangedSignal("AbsoluteSize"),function()
        if self._needsCenter and self:_bounds().X>=20 and self:_bounds().Y>=20 then
            self._needsCenter=false; self:Center(); self:ResetCapsulePosition()
        else self:_layout(false) end
    end)
    self._animationSpeed=0.15
    self._capsuleMode="Full"
    self._draggable=true
    self._capsuleText=capText
    self._notificationsEnabled=true
    self:SetSize(options.Size or "Medium")
    self._needsCenter=self:_bounds().X<20 or self:_bounds().Y<20
    self:Center()
    self:ResetCapsulePosition()
    if options.CapsuleMode == "Logo only" then self:SetCapsuleMode("Logo only"); self:ResetCapsulePosition() end
    self._notificationHost=create(self._scope,"Frame",{AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,-10,1,-10),Size=UDim2.fromOffset(math.min(245,math.max(1,self:_bounds().X-20)),214),BackgroundTransparency=1},self._root)
    create(self._scope,"UIListLayout",{VerticalAlignment=Enum.VerticalAlignment.Bottom,Padding=UDim.new(0,6)},self._notificationHost)

end

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
    test("Theme and visibility",function()
        assert(w:SetTheme("BlackGold")); assert(not w:SetTheme("Midnight"))
        for i=1,100 do w:SetVisible(false); w:SetVisible(true) end
    end)
    test("Size presets and capsule modes",function()
        for _,size in ipairs({"Compact","Small","Medium","Large"}) do assert(w:SetSize(size)) end
        assert(w:SetSize(Vector2.new(500,350)))
        assert(not w:SetSize("Invalid"))
        assert(w:SetCapsuleMode("Logo only"))
        assert(w:SetCapsuleMode("Full"))
        assert(not w:SetCapsuleMode("Invalid"))
        w:Center()
    end)
    test("Loading cleanup",function()
        local loading=w:CreateLoading({Default=25})
        assert(loading:SetValue(100))
        loading:Destroy()
        assert(not loading:SetValue(0))
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
    test("Container lifecycle",function()
        local group=tab:CreateGroup({Name="Group"})
        local child=group:CreateToggle({Flag="group_child",Default=false})
        assert(child:SetValue(true,true))
        group:Destroy()
        assert(not child:IsAlive() and w:GetValue("group_child")==nil)
        local fold=tab:CreateCollapsible({Name="Fold",Expanded=false})
        assert(not fold.Page.Visible and fold:SetExpanded(true) and fold.Page.Visible)
        fold:Destroy()
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
