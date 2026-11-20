local FunctionnalityTester = {
    Version = '2.1'
}

local MOTD_URL = 'https://raw.githubusercontent.com/00uxnx/productions/main/extra/motd.txt'
local CHANGELOGS_URL = 'https://raw.githubusercontent.com/00uxnx/productions/main/extra/Changelogs.lua'
local REQUIRE_TEST_URL = 'https://raw.githubusercontent.com/00uxnx/nocturne/main/Assets/req.lua'
local execfuncs = {}

local SECTION_ORDER = { "Loader", "Vantage", "Rivals", "Doors" }

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local FONT = Enum.Font.Code
local AUTO_CLOSE_SECONDS = 5 -- Automatically close the window after five seconds.

local httpRequest = (syn and syn.request)
    or (http and http.request)
    or http_request
    or request

local function httpGet(url)
    if httpRequest then
        local ok, res = pcall(httpRequest, { Url = url, Method = "GET" })
        if ok and res and (res.StatusCode == 200 or res.StatusCode == 0) and type(res.Body) == "string" then
            return res.Body
        end
    end

    -- Some supported environments expose HttpGet instead of request().
    local ok, body = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and type(body) == "string" and body ~= "" then
        return body
    end

    return nil
end

local function newSignal()
    local signal = { _conns = {} }
    function signal:Connect(fn)
        local c = { fn = fn }
        table.insert(self._conns, c)
        function c:Disconnect()
            local i = table.find(signal._conns, c)
            if i then table.remove(signal._conns, i) end
        end
        return c
    end
    function signal:Fire(...)
        for _, c in ipairs(table.clone(self._conns)) do
            task.spawn(c.fn, ...)
        end
    end
    return signal
end

FunctionnalityTester.FuncThisWhenDone = newSignal()

local function make(className, props)
    local instance = Instance.new(className)
    local parent = nil

    -- Set normal properties first. Parent is assigned last so the object is
    -- fully configured before Roblox displays it.
    for property, value in pairs(props or {}) do
        if property == "Parent" then
            parent = value
        else
            local ok, err = pcall(function()
                instance[property] = value
            end)
            if not ok then
                warn("[FunctionnalityTester] Could not set " .. tostring(property)
                    .. " on " .. tostring(className) .. ": " .. tostring(err))
            end
        end
    end

    if parent then
        local ok, err = pcall(function()
            instance.Parent = parent
        end)
        if not ok then
            warn("[FunctionnalityTester] Could not parent " .. tostring(className)
                .. ": " .. tostring(err))
            instance:Destroy()
            return nil
        end
    end

    return instance
end

local function makeDraggable(target, handle)
    local dragging = false
    local startMouse, startPos

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startMouse = input.Position
            startPos = target.Position
            local endConn
            endConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if endConn then endConn:Disconnect() end
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - startMouse
        target.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end)
end

local function lookupFunc(name)
    local aliases = { name }
    if name == "getclipboard" then
        aliases = { "getclipboard", "get_clipboard", "syn_clipboard_get" }
    end

    local env
    pcall(function() env = getfenv(0) end)

    for _, candidate in ipairs(aliases) do
        if env and env[candidate] ~= nil then return env[candidate] end
        if _G and _G[candidate] ~= nil then return _G[candidate] end

        if typeof(getgenv) == "function" then
            local okG, genv = pcall(getgenv)
            if okG and genv and genv[candidate] ~= nil then
                return genv[candidate]
            end
        end

        if shared and shared[candidate] ~= nil then
            return shared[candidate]
        end

        if candidate == "getclipboard" and syn and syn.clipboard_get ~= nil then
            return syn.clipboard_get
        end
    end

    return nil
end

local function runTest(name)
    if type(name) ~= "string" then
        return { Name = tostring(name), Success = false, Reason = "Invalid" }
    end

    local fn = lookupFunc(name)

    if fn == nil then
        return { Name = name, Success = false, Reason = "Not found" }
    end

    if type(fn) ~= "function" then
        return { Name = name, Success = false, Reason = "Not a function" }
    end

    -- Actually call getclipboard. An empty clipboard may legitimately return nil;
    -- a string or nil means the API call itself behaved as expected.
    if name == "getclipboard" then
        local callOk, clipboardValue = pcall(fn)
        if not callOk then
            return {
                Name = name,
                Success = false,
                Reason = "Call failed: " .. tostring(clipboardValue),
            }
        end

        if clipboardValue ~= nil and type(clipboardValue) ~= "string" then
            return {
                Name = name,
                Success = false,
                Reason = "Expected string or empty clipboard; got " .. typeof(clipboardValue),
            }
        end

        return {
            Name = name,
            Success = true,
            Reason = (clipboardValue == nil or clipboardValue == "") and "Clipboard empty" or "Clipboard readable",
        }
    end

    -- Fetch and execute the remote test module as a Lua chunk. This does NOT
    -- call the executor's require(URL), because standard require expects a
    -- ModuleScript/asset identifier rather than a raw GitHub URL.
    if name == "require" then
        local body = httpGet(REQUIRE_TEST_URL)
        if not body or body == "" then
            return {
                Name = name,
                Success = false,
                Reason = "Could not download req.lua (HTTP request unavailable or failed)",
            }
        end

        local compileOk, loader, compileError = pcall(loadstring, body)
        if not compileOk or type(loader) ~= "function" then
            return {
                Name = name,
                Success = false,
                Reason = "req.lua compile failed: " .. tostring(compileError or loader),
            }
        end

        local runOk, result = pcall(loader)
        if not runOk then
            return {
                Name = name,
                Success = false,
                Reason = "req.lua execution failed: " .. tostring(result),
            }
        end

        if type(result) ~= "table" then
            return {
                Name = name,
                Success = false,
                Reason = "req.lua must return a table; got " .. typeof(result),
            }
        end

        return {
            Name = name,
            Success = result.Success == true,
            Reason = tostring(result.Message or "No message returned"),
        }
    end

    return { Name = name, Success = true }
end

local function getOrderedSections(data)
    local out = {}
    local used = {}

    for _, key in ipairs(SECTION_ORDER) do
        local items = data[key]
        if type(items) == "table" and #items > 0 then
            table.insert(out, { name = key, items = items })
        end
        used[key] = true
    end

    for key, items in pairs(data) do
        if key ~= "ver" and key ~= "sections" and not used[key]
            and type(items) == "table" and #items > 0 then
            table.insert(out, { name = key, items = items })
        end
    end

    return out
end

function FunctionnalityTester:Init(funcs)
    execfuncs = funcs or {}

    local Players = game:GetService("Players")
    local localPlayer = Players.LocalPlayer
    if not localPlayer then
        error("FunctionnalityTester must be initialized on the client")
    end

    -- PlayerGui is the supported Roblox UI parent.
    local parentTo = localPlayer:WaitForChild("PlayerGui")

    -- Remove an earlier copy so repeated Init() calls do not stack GUIs.
    local previousGui = parentTo:FindFirstChild("FunctionnalityTester")
    if previousGui then
        previousGui:Destroy()
    end

    local gui = make("ScreenGui", {
        Name = "FunctionnalityTester",
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        ResetOnSpawn = false,
        DisplayOrder = 9999,
        Parent = parentTo,
        Enabled = true
    })

    local mainWindow = make("CanvasGroup", {
        Name = "MainWindow",
        BackgroundTransparency = 1,
        GroupTransparency = 0,
        Visible = true,
        Position = UDim2.new(0.5, -265.5, 0.5, -136),
        Size = UDim2.fromOffset(531, 272),
        Parent = gui,
    })
    local corner = Instance.new("UICorner", mainWindow)
    corner.CornerRadius = UDim.new(0, 7)

    -- Side panel
    local side = make("Frame", {
        Name = "Side",
        BackgroundTransparency = 0.1,
        BackgroundColor3 = Color3.fromRGB(12, 12, 12),
        Position = UDim2.new(0.6476, 0, 0, 0),
        Size = UDim2.new(0.3523, 0, 1, 0),
        BorderSizePixel = 0,
        Parent = mainWindow,
    })

    local sideScroll = make("ScrollingFrame", {
        Active = true,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Size = UDim2.fromOffset(187, 272),
        BackgroundTransparency = 1,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarImageColor3 = Color3.fromRGB(0, 0, 0),
        CanvasSize = UDim2.fromOffset(0, 0),
        BorderSizePixel = 0,
        Parent = side,
    })

    local sideLayout = Instance.new("UIListLayout", sideScroll)
    sideLayout.Padding = UDim.new(0, 7)
    sideLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    sideLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local sidePad = Instance.new("UIPadding", sideScroll)
    sidePad.PaddingBottom = UDim.new(0, 8)
    sidePad.PaddingTop = UDim.new(0, 2)

    local sideHeader = make("TextLabel", {
        Name = "header",
        Text = "Executor Test",
        TextColor3 = Color3.fromRGB(255, 255, 255),
        TextSize = 15,
        Font = FONT,
        TextScaled = true,
        TextWrapped = true,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(0.9634, 0, 0.077, 0),
        Parent = sideScroll,
    })
    local shc = Instance.new("UITextSizeConstraint", sideHeader)
    shc.MaxTextSize = 15

    local resultsHolder = make("Frame", {
        Name = "Results",
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = 1,
        Parent = sideScroll,
    })
    local resultsLayout = Instance.new("UIListLayout", resultsHolder)
    resultsLayout.Padding = UDim.new(0, 3)
    resultsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    resultsLayout.SortOrder = Enum.SortOrder.LayoutOrder

    -- Left holder
    local holder = make("Frame", {
        Name = "Holder",
        BackgroundColor3 = Color3.fromRGB(12, 12, 12),
        Position = UDim2.new(0, 0, 0, 0),
        Size = UDim2.new(0.6476, 0, 1, 0),
        BorderSizePixel = 0,
        Parent = mainWindow,
    })

    make("ImageLabel", {
        Image = "rbxassetid://115666653528030",
        BackgroundTransparency = 1,
        Position = UDim2.new(0.0235, 0, 0.025, 0),
        Size = UDim2.new(0.0997, 0, 0.137, 0),
        ScaleType = Enum.ScaleType.Fit,
        BorderSizePixel = 0,
        Parent = holder,
    })

    make("TextLabel", {
        Text = "Nocturna Productions v" .. tostring(FunctionnalityTester.Version),
        TextColor3 = Color3.fromRGB(255, 255, 255),
        TextSize = 15,
        Font = FONT,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.new(0.1495, 0, 0.049, 0),
        Size = UDim2.new(0.8504, 0, 0.076, 0),
        Parent = holder,
    })

    local motdLabel = make("TextLabel", {
        Name = "MOTD",
        Text = "MOTD: Loading...",
        TextColor3 = Color3.fromRGB(255, 255, 255),
        TextSize = 17,
        Font = FONT,
        TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextXAlignment = Enum.TextXAlignment.Center,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0.679, 0),
        Size = UDim2.new(0.9531, 0, 0.116, 0),
        Parent = holder,
    })

    local changelogFrame = make("ScrollingFrame", {
        Active = true,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 0,
        ScrollBarImageColor3 = Color3.fromRGB(50, 50, 50),
        Size = UDim2.new(0.9531, 0, 0.474, 0),
        Position = UDim2.new(0.0234, 0, 0.189, 0),
        BackgroundTransparency = 1,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.fromOffset(0, 0),
        BorderSizePixel = 0,
        Parent = holder,
    })
    local clLayout = Instance.new("UIListLayout", changelogFrame)
    clLayout.Padding = UDim.new(0, 15)
    clLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    clLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local clStroke = Instance.new("UIStroke", changelogFrame)
    clStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    clStroke.Color = Color3.fromRGB(50, 50, 50)

    -- Simple rotating star glyph instead of the old image asset.
    local twis = make("TextLabel", {
        Name = "SpinnerIcon",
        Text = "✦",
        TextColor3 = Color3.fromRGB(125, 125, 145),
        TextSize = 34,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        BackgroundTransparency = 1,
        Position = UDim2.new(0.4428, 0, 0.819, 0),
        Size = UDim2.new(0.1026, 0, 0.141, 0),
        BorderSizePixel = 0,
        Parent = holder,
    })

    local topDrag = make("TextButton", {
        BackgroundTransparency = 1,
        Text = "",
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.new(0, 0, 0, 0),
        ZIndex = 999,
        Parent = mainWindow,
    })
    makeDraggable(mainWindow, topDrag)

    -- Spinner
    local rotation = 0
    local rotationConn
    rotationConn = RunService.RenderStepped:Connect(function(dt)
        if not twis.Parent then
            if rotationConn then rotationConn:Disconnect() end
            return
        end
        rotation = (rotation + dt * 180) % 360
        twis.Rotation = rotation
    end)

    -- Run executor function tests
    for _, entry in ipairs(execfuncs) do
        local name = entry
        if type(entry) == "table" then name = entry.Name end

        local result = runTest(name)
        if result then
            local color = result.Success
                and Color3.fromRGB(150, 255, 150)
                or Color3.fromRGB(255, 150, 150)

            local text = (result.Success and "✅ " or "❌ ") .. result.Name
            if not result.Success and result.Reason then
                text = text .. " (" .. result.Reason .. ")"
            end

            local resultLabel = make("TextLabel", {
                Text = text,
                TextColor3 = color,
                TextSize = 15,
                Font = FONT,
                TextWrapped = true,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Top,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                AutomaticSize = Enum.AutomaticSize.Y,
                Size = UDim2.new(0.92, 0, 0, 0),
                Parent = resultsHolder,
            })
            local rlc = Instance.new("UITextSizeConstraint", resultLabel)
            rlc.MaxTextSize = 15
        end
    end

    -- MOTD
    task.spawn(function()
        local body = httpGet(MOTD_URL)
        if body and body ~= "" then
            body = body:gsub("^%s+", ""):gsub("%s+$", "")
            motdLabel.Text = "MOTD: " .. body
        else
            motdLabel.Text = "MOTD: (failed to load)"
        end
    end)

    -- Changelogs
    task.spawn(function()
        local body = httpGet(CHANGELOGS_URL)
        if not body then
            make("TextLabel", {
                Text = "Failed to load changelogs",
                TextColor3 = Color3.fromRGB(255, 100, 100),
                TextSize = 15,
                Font = FONT,
                BackgroundTransparency = 1,
                Size = UDim2.fromOffset(325, 20),
                Parent = changelogFrame,
            })
            return
        end

        local loader, err = loadstring(body)
        if not loader then
            warn("[FunctionnalityTester] changelog loadstring: " .. tostring(err))
            return
        end

        local ok, data = pcall(loader)
        if not ok or type(data) ~= "table" then
            warn("[FunctionnalityTester] changelog invalid: " .. tostring(data))
            return
        end

        local ver = tostring(data.ver or "?")
        local header = make("TextLabel", {
            Name = "header",
            Text = "Update Logs for v" .. ver,
            TextColor3 = Color3.fromRGB(255, 255, 255),
            TextSize = 15,
            Font = FONT,
            TextScaled = true,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Size = UDim2.fromOffset(325, 20),
            Parent = changelogFrame,
        })
        local hc = Instance.new("UITextSizeConstraint", header)
        hc.MaxTextSize = 15

        local order = 1
        for _, section in ipairs(getOrderedSections(data)) do
            local sec = make("Frame", {
                Name = section.name,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Size = UDim2.new(1, 0, 0, 20),
                AutomaticSize = Enum.AutomaticSize.Y,
                LayoutOrder = order,
                Parent = changelogFrame,
            })
            order = order + 1

            local secLayout = Instance.new("UIListLayout", sec)
            secLayout.Padding = UDim.new(0, 5)
            secLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            secLayout.SortOrder = Enum.SortOrder.LayoutOrder

            local secHeader = make("TextLabel", {
                Name = "header",
                Text = "- " .. tostring(section.name),
                TextColor3 = Color3.fromRGB(255, 255, 255),
                TextSize = 15,
                Font = FONT,
                TextScaled = true,
                TextWrapped = true,
                TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Size = UDim2.fromOffset(325, 20),
                Parent = sec,
            })
            local shc2 = Instance.new("UITextSizeConstraint", secHeader)
            shc2.MaxTextSize = 20
            local shp = Instance.new("UIPadding", secHeader)
            shp.PaddingLeft = UDim.new(0, 10)
            shp.PaddingRight = UDim.new(0, 10)

            for _, itemText in ipairs(section.items) do
                if type(itemText) == "string" then
                    local color = Color3.fromRGB(255, 255, 255)
                    if itemText:sub(1, 2) == "--" then
                        color = Color3.fromRGB(255, 255, 255)
                    elseif itemText:sub(1, 1) == "+" then
                        color = Color3.fromRGB(0, 255, 0)
                    elseif itemText:sub(1, 1) == "-" then
                        color = Color3.fromRGB(255, 0, 0)
                    elseif itemText:sub(1, 1) == "?" then
                        color = Color3.fromRGB(255, 255, 0)
                    end

                    local item = make("TextLabel", {
                        Text = itemText,
                        TextColor3 = color,
                        TextSize = 15,
                        Font = FONT,
                        TextScaled = true,
                        TextWrapped = true,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        BackgroundTransparency = 1,
                        BorderSizePixel = 0,
                        Size = UDim2.fromOffset(325, 15),
                        Parent = sec,
                    })
                    local ic = Instance.new("UITextSizeConstraint", item)
                    ic.MaxTextSize = 15
                    local ip = Instance.new("UIPadding", item)
                    ip.PaddingLeft = UDim.new(0, 10)
                    ip.PaddingRight = UDim.new(0, 10)
                end
            end
        end
    end)

    -- Auto close (set AUTO_CLOSE_SECONDS to 0 above to disable it).
    if AUTO_CLOSE_SECONDS > 0 then
        task.delay(math.max(0, AUTO_CLOSE_SECONDS - 0.4), function()
            if not gui or not gui.Parent then return end

            if rotationConn then
                rotationConn:Disconnect()
            end

            local tween = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
            TweenService:Create(mainWindow, tween, { GroupTransparency = 1 }):Play()

            task.delay(0.4, function()
                if gui and gui.Parent then
                    gui:Destroy()
                end
                FunctionnalityTester.FuncThisWhenDone:Fire()
            end)
        end)
    end

    return gui
end

return FunctionnalityTester
