-- VEYSELL HUB | Vox Seas 0.5
-- Dev: VeySell / GGSIHLUH
-- UI: Fluent (tema gelap biru malam) + ikon buka/tutup (asset 13026626364)
--
-- Nama objek game dicari otomatis lewat kata kunci. Kalau ada yang tidak
-- terdeteksi, ubah bagian [SESUAIKAN]. Kalau Farming Level / Story / Quest
-- gagal atau error, script otomatis jatuh ke Farming Nearest.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

if not game:IsLoaded() then game.Loaded:Wait() end
local LP = Players.LocalPlayer
if not LP then return end

-- ================= [SESUAIKAN] =================
local ICON_ID = 13026626364
local ENEMY_FOLDERS = { "Enemies", "Mobs", "NPCs", "Monsters", "Enemy" }
local QUEST_WORDS = { "quest", "mission" }
local STORY_WORDS = { "story" }
local LEVEL_PATTERNS = { "[Ll]v%.?%s*(%d+)", "[Ll]evel%s*(%d+)" }

-- ================= CLEANUP =================
local env = (getgenv and getgenv()) or _G
if env.__VeySellCleanup then pcall(env.__VeySellCleanup) end

-- ================= STATE =================
local S = {
	farmNearest = false, farmLevel = false, farmStory = false, autoQuest = false,
	weapon = "Melee", method = "Above",
	killAuraGun = false, noCDGun = false, fastAttack = false, bring = false,
	noEffect = false, resetAttack = false,
	force = 200, mode = "Smooth", height = 7, bringRange = 100,
}
local flags, gens, conns, frozen = {}, {}, {}, {}
local currentTarget, lastPick, orbitAngle = nil, 0, 0

-- ================= HELPER =================
local function getChar() return LP.Character end
local function getRoot() local c = getChar() return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum() local c = getChar() return c and c:FindFirstChildOfClass("Humanoid") end

local function startLoop(name, fn, interval)
	if flags[name] then return end
	flags[name] = true
	gens[name] = (gens[name] or 0) + 1
	local my = gens[name]
	task.spawn(function()
		while flags[name] and gens[name] == my do
			local ok, err = pcall(fn)
			if not ok then warn("[VeySell] " .. name .. ": " .. tostring(err)) task.wait(1) end
			task.wait(interval or 0.1)
		end
	end)
end
local function stopLoop(name) flags[name] = false end

local function farmActive()
	return S.farmNearest or S.farmLevel or S.farmStory
end

-- ================= ENEMY =================
local enemyCache, enemyLast = {}, 0
local function getEnemies()
	if os.clock() - enemyLast < 0.4 then return enemyCache end
	enemyLast = os.clock()
	local out, roots = {}, {}
	for _, n in ipairs(ENEMY_FOLDERS) do
		local f = workspace:FindFirstChild(n)
		if f then table.insert(roots, f) end
	end
	if #roots == 0 then roots = { workspace } end
	local myChar = getChar()
	for _, root in ipairs(roots) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("Humanoid") and d.Health > 0 then
				local m = d.Parent
				if m and m:IsA("Model") and m ~= myChar and not Players:GetPlayerFromCharacter(m)
					and m:FindFirstChild("HumanoidRootPart")
					and not m:FindFirstChildWhichIsA("ProximityPrompt", true) then
					table.insert(out, m)
				end
			end
		end
	end
	enemyCache = out
	return out
end

local function distTo(model)
	local me, r = getRoot(), model and model:FindFirstChild("HumanoidRootPart")
	if me and r then return (r.Position - me.Position).Magnitude end
	return math.huge
end

local function nearest(list)
	local best, bd
	for _, m in ipairs(list) do
		local d = distTo(m)
		if not bd or d < bd then best, bd = m, d end
	end
	return best
end

local function getMyLevel()
	local v = LP:GetAttribute("Level")
	if v then return tonumber(v) end
	local data = LP:FindFirstChild("Data")
	local lv = (data and data:FindFirstChild("Level")) or (LP:FindFirstChild("leaderstats") and LP.leaderstats:FindFirstChild("Level"))
	return lv and tonumber(lv.Value) or nil
end

local function enemyLevel(m)
	local a = m:GetAttribute("Level")
	if a then return tonumber(a) end
	local v = m:FindFirstChild("Level")
	if v and v:IsA("ValueBase") then return tonumber(v.Value) end
	for _, pat in ipairs(LEVEL_PATTERNS) do
		local n = m.Name:match(pat)
		if n then return tonumber(n) end
	end
	local hum = m:FindFirstChildOfClass("Humanoid")
	if hum and hum.DisplayName then
		for _, pat in ipairs(LEVEL_PATTERNS) do
			local n = hum.DisplayName:match(pat)
			if n then return tonumber(n) end
		end
	end
	return nil
end

-- Farming Level: cari npc level tertinggi yang <= level kita
local function pickByLevel(list)
	local lv = getMyLevel()
	if not lv then return nil end
	local bestLv, group = -1, {}
	for _, m in ipairs(list) do
		local el = enemyLevel(m)
		if el and el <= lv then
			if el > bestLv then bestLv, group = el, { m }
			elseif el == bestLv then table.insert(group, m) end
		end
	end
	return nearest(group)
end

local function pickStory(list)
	local group = {}
	for _, m in ipairs(list) do
		local cur = m
		while cur and cur ~= workspace do
			local n = cur.Name:lower()
			for _, w in ipairs(STORY_WORDS) do
				if n:find(w, 1, true) then table.insert(group, m) break end
			end
			cur = cur.Parent
		end
	end
	return nearest(group)
end

local function pickTarget()
	local list = getEnemies()
	local t
	if S.farmLevel then
		local ok, r = pcall(pickByLevel, list)
		t = ok and r or nil
	end
	if not t and S.farmStory then
		local ok, r = pcall(pickStory, list)
		t = ok and r or nil
	end
	if not t then t = nearest(list) end -- fallback: Nearest
	return t
end

-- ================= WEAPON =================
local function toolMatches(tool, kind)
	local tip = (tool.ToolTip or ""):lower()
	local n = tool.Name:lower()
	if kind == "Melee" then
		return tip == "melee" or n:find("combat") or n:find("fist") or n:find("melee")
	elseif kind == "Sword" then
		return tip == "sword" or n:find("sword") or n:find("katana") or n:find("blade")
	elseif kind == "Gun" then
		return tip == "gun" or n:find("gun") or n:find("flintlock") or n:find("pistol") or n:find("musket")
	else -- Vox Fruit
		return tip:find("fruit") or n:find("fruit") or n:find("vox")
	end
end

local function findWeapon(kind)
	local c = getChar()
	local bp = LP:FindFirstChildOfClass("Backpack")
	for _, box in ipairs({ c, bp }) do
		if box then
			for _, t in ipairs(box:GetChildren()) do
				if t:IsA("Tool") and toolMatches(t, kind) then return t end
			end
		end
	end
end

local function equip(tool)
	local hum = getHum()
	if tool and hum and tool.Parent ~= getChar() then hum:EquipTool(tool) end
end

local function clearCooldowns(tool)
	local function wipe(inst)
		for k, v in pairs(inst:GetAttributes()) do
			local n = k:lower()
			if n:find("cooldown") or n:find("debounce") or n == "cd" or n:find("reload") then
				pcall(function() inst:SetAttribute(k, type(v) == "boolean" and false or 0) end)
			end
		end
		for _, d in ipairs(inst:GetChildren()) do
			if d:IsA("ValueBase") then
				local n = d.Name:lower()
				if n:find("cooldown") or n:find("debounce") or n == "cd" or n:find("reload") then
					pcall(function()
						if d:IsA("BoolValue") then d.Value = false else d.Value = 0 end
					end)
				end
			end
		end
	end
	if tool then wipe(tool) end
	wipe(LP)
	local c = getChar()
	if c then wipe(c) end
end

local function click()
	local cam = workspace.CurrentCamera
	if VIM and cam then
		local vp = cam.ViewportSize
		pcall(function()
			VIM:SendMouseButtonEvent(vp.X / 2, vp.Y / 2, 0, true, game, 0)
			VIM:SendMouseButtonEvent(vp.X / 2, vp.Y / 2, 0, false, game, 0)
		end)
	end
end

local attackCount = 0
local function attackOnce()
	local tool = findWeapon(S.weapon)
	if not tool then return end
	equip(tool)
	pcall(function() tool:Activate() end)
	click()
	attackCount += 1
	if S.resetAttack then
		clearCooldowns(tool)
		-- reset: lepas lalu pasang lagi tiap 3 serangan
		if attackCount % 3 == 0 then
			local hum = getHum()
			if hum then
				pcall(function() hum:UnequipTools() end)
				task.wait()
				equip(tool)
			end
		end
	end
end

-- ================= GERAK =================
local MODE_MULT = { Slow = 0.35, Smooth = 0.7, Medium = 1, Fast = 1.8 }

local function stepTo(root, goal, dt)
	if S.mode == "Instant" then
		root.CFrame = goal
		return
	end
	local cur = root.Position
	local d = goal.Position - cur
	local maxStep = S.force * (MODE_MULT[S.mode] or 1) * dt
	local newPos
	if d.Magnitude <= maxStep then
		newPos = goal.Position
	else
		newPos = cur + d.Unit * maxStep
	end
	if S.mode == "Smooth" and d.Magnitude <= maxStep * 8 then
		newPos = cur:Lerp(goal.Position, 0.35)
	end
	root.CFrame = CFrame.lookAt(newPos, newPos + goal.LookVector)
end

local function goalFor(tr, dt)
	local h = S.height
	local p = tr.Position
	if S.method == "Above" then
		return CFrame.lookAt(p + Vector3.new(0, h, 0), p)
	elseif S.method == "Down" then
		return CFrame.lookAt(p - Vector3.new(0, h, 0), p)
	elseif S.method == "Side" then
		local pos = p + tr.CFrame.RightVector * h
		return CFrame.lookAt(pos, p)
	elseif S.method == "Orbit" then
		orbitAngle += dt * 3
		local pos = p + Vector3.new(math.cos(orbitAngle) * h, 2, math.sin(orbitAngle) * h)
		return CFrame.lookAt(pos, p)
	else -- Kill Aura: dekati sampai dalam jangkauan
		local me = getRoot()
		if me and (me.Position - p).Magnitude > 50 then
			return CFrame.lookAt(p + Vector3.new(0, h, 0), p)
		end
		return nil
	end
end

local function freezeEnemy(m, on)
	local r = m and m:FindFirstChild("HumanoidRootPart")
	local hum = m and m:FindFirstChildOfClass("Humanoid")
	if not r then return end
	if on then
		r.Anchored = true
		if hum then hum.WalkSpeed = 0 end
		frozen[m] = true
	else
		r.Anchored = false
		frozen[m] = nil
	end
end

local function unfreezeAll()
	for m in pairs(frozen) do
		pcall(function() freezeEnemy(m, false) end)
	end
	table.clear(frozen)
end

-- Heartbeat: gerak farming + bring
table.insert(conns, RunService.Heartbeat:Connect(function(dt)
	if not farmActive() then
		if next(frozen) then unfreezeAll() end
		return
	end
	local root = getRoot()
	if not root then return end

	if os.clock() - lastPick > 0.4 or not currentTarget or not currentTarget.Parent
		or not currentTarget:FindFirstChild("HumanoidRootPart")
		or (currentTarget:FindFirstChildOfClass("Humanoid") and currentTarget:FindFirstChildOfClass("Humanoid").Health <= 0) then
		lastPick = os.clock()
		local ok, t = pcall(pickTarget)
		if not ok then t = nearest(getEnemies()) end
		if t ~= currentTarget and currentTarget then freezeEnemy(currentTarget, false) end
		currentTarget = t
	end

	local t = currentTarget
	local tr = t and t:FindFirstChild("HumanoidRootPart")
	if not tr then return end

	if S.fastAttack then
		freezeEnemy(t, true)
	end

	local goal = goalFor(tr, dt)
	if goal then
		stepTo(root, goal, dt)
	end
	root.AssemblyLinearVelocity = Vector3.zero

	-- Bring: tarik musuh sekitar pelan-pelan ke target (biar kena hit semua)
	if S.bring then
		for _, m in ipairs(getEnemies()) do
			if m ~= t then
				local r = m:FindFirstChild("HumanoidRootPart")
				if r and (r.Position - root.Position).Magnitude <= S.bringRange then
					r.CFrame = r.CFrame:Lerp(CFrame.new(tr.Position + Vector3.new(0, 0.5, 0)), 0.3)
					r.AssemblyLinearVelocity = Vector3.zero
					if S.fastAttack then freezeEnemy(m, true) end
				end
			end
		end
	end
end))

pcall(function()
	if sethiddenproperty then sethiddenproperty(LP, "SimulationRadius", math.huge) end
	if setsimulationradius then setsimulationradius(math.huge, math.huge) end
end)

-- ================= LOOP SERANGAN =================
local function attackLoop()
	if not farmActive() then return end
	local t = currentTarget
	local hum = getHum()
	if not hum then return end

	if S.fastAttack then
		for _, tr in ipairs(hum:GetPlayingAnimationTracks()) do pcall(function() tr:Stop(0) end) end
	end

	if S.method == "Kill Aura" then
		local any = false
		for _, m in ipairs(getEnemies()) do
			if distTo(m) <= 60 then any = true break end
		end
		if any then attackOnce() end
	elseif t and distTo(t) <= 45 then
		attackOnce()
	end
end

local function refreshFarm()
	if farmActive() then
		startLoop("attack", attackLoop, S.fastAttack and 0.03 or 0.15)
	else
		stopLoop("attack")
		if currentTarget then freezeEnemy(currentTarget, false) end
		unfreezeAll()
		currentTarget = nil
	end
end

-- ================= GUN =================
local function gunLoop()
	if not (S.killAuraGun or S.noCDGun) then return end
	local gun = findWeapon("Gun")
	if not gun then return end
	if S.noCDGun then clearCooldowns(gun) end
	if S.killAuraGun then
		local t
		local bd
		for _, m in ipairs(getEnemies()) do
			local d = distTo(m)
			if d <= 250 and (not bd or d < bd) then t, bd = m, d end
		end
		local tr = t and t:FindFirstChild("HumanoidRootPart")
		if tr then
			equip(gun)
			local cam = workspace.CurrentCamera
			if cam then cam.CFrame = CFrame.lookAt(cam.CFrame.Position, tr.Position) end
			pcall(function() gun:Activate() end)
			click()
		end
	end
end

local function refreshGun()
	if S.killAuraGun or S.noCDGun then
		startLoop("gun", gunLoop, S.noCDGun and 0.04 or 0.2)
	else
		stopLoop("gun")
	end
end

-- ================= QUEST =================
local function promptPos(p)
	local par = p.Parent
	if not par then return nil end
	if par:IsA("Attachment") then return par.WorldPosition end
	if par:IsA("BasePart") then return par.Position end
	if par:IsA("Model") then return par:GetPivot().Position end
	local m = par:FindFirstAncestorOfClass("Model")
	return m and m:GetPivot().Position
end

local function matchesWords(p, words)
	local text = (p.ObjectText .. " " .. p.ActionText):lower()
	local cur = p.Parent
	for _ = 1, 4 do
		if cur and cur ~= workspace then text = text .. " " .. cur.Name:lower() cur = cur.Parent end
	end
	for _, w in ipairs(words) do
		if text:find(w, 1, true) then return true end
	end
	return false
end

local function takeQuest(words)
	local root = getRoot()
	if not root then return end
	local best, bd, bp
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Enabled and matchesWords(d, words) then
			local p = promptPos(d)
			if p then
				local dist = (p - root.Position).Magnitude
				if not bd or dist < bd then best, bd, bp = d, dist, p end
			end
		end
	end
	if not best then return end
	local back = root.CFrame
	root.CFrame = CFrame.new(bp + Vector3.new(0, 3, 4))
	task.wait(0.3)
	pcall(function() best.HoldDuration = 0 end)
	if fireproximityprompt then fireproximityprompt(best) end
	task.wait(0.4)
	root = getRoot()
	if root then root.CFrame = back end
end

local function questLoop()
	if S.farmStory then pcall(takeQuest, STORY_WORDS) end
	pcall(takeQuest, QUEST_WORDS)
	task.wait(20)
end

-- ================= NO EFFECT =================
local effectConn
local function killEffect(d)
	if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke")
		or d:IsA("Fire") or d:IsA("Sparkles") then
		d.Enabled = false
	elseif d:IsA("Explosion") then
		d.Visible = false
	end
end
local function setNoEffect(on)
	if effectConn then effectConn:Disconnect() effectConn = nil end
	if on then
		for _, d in ipairs(workspace:GetDescendants()) do pcall(killEffect, d) end
		effectConn = workspace.DescendantAdded:Connect(function(d) pcall(killEffect, d) end)
	end
end

-- ================= UI =================
local okLib, Fluent = pcall(function()
	return loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
end)
if not okLib or type(Fluent) ~= "table" then
	warn("[VeySell] Gagal memuat Fluent: " .. tostring(Fluent))
	return
end
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()

local Window = Fluent:CreateWindow({
	Title = "VeySell Hub",
	SubTitle = "Vox Seas 0.5 • by VeySell/GGSIHLUH",
	TabWidth = 150,
	Size = UDim2.fromOffset(520, 400),
	Acrylic = false,
	Theme = "Darker",            -- paling dekat dengan Midnight di Fluent
	MinimizeKey = Enum.KeyCode.RightControl,
})

local Tabs = {
	Farming = Window:AddTab({ Title = "Farming", Icon = "swords" }),
	Setting = Window:AddTab({ Title = "Setting", Icon = "sliders-horizontal" }),
	Config = Window:AddTab({ Title = "UI Config", Icon = "settings" }),
}
local Options = Fluent.Options

local function toggle(tab, id, title, desc, fn)
	local t = tab:AddToggle(id, { Title = title, Description = desc, Default = false })
	t:OnChanged(function() fn(Options[id].Value) end)
	return t
end

-- ---------- FARMING ----------
Tabs.Farming:AddSection("Farming")
toggle(Tabs.Farming, "FarmNearest", "Farming Nearest", "Serang musuh terdekat", function(v)
	S.farmNearest = v refreshFarm()
end)
toggle(Tabs.Farming, "FarmLevel", "Farming Level", "Scan level kamu lalu cari NPC yang sesuai (gagal → Nearest)", function(v)
	S.farmLevel = v refreshFarm()
end)
toggle(Tabs.Farming, "Auto Story", "Farming Story", "Farm musuh story (gagal → Nearest)", function(v)
	S.farmStory = v refreshFarm()
end)
toggle(Tabs.Farming, "AutoQuest", "Auto Quest", "Ambil quest otomatis lalu kembali", function(v)
	S.autoQuest = v
	if v then startLoop("quest", questLoop, 0.5) else stopLoop("quest") end
end)

Tabs.Farming:AddSection("Weapon & Metode")
local wd = Tabs.Farming:AddDropdown("Weapon", {
	Title = "Select Weapon", Values = { "Melee", "Sword", "Gun", "Vox Fruit" }, Multi = false, Default = 1,
})
wd:OnChanged(function(v) S.weapon = v end)

local md = Tabs.Farming:AddDropdown("Method", {
	Title = "Player Metode", Values = { "Above", "Side", "Orbit", "Down", "Kill Aura" }, Multi = false, Default = 1,
})
md:OnChanged(function(v) S.method = v end)

Tabs.Farming:AddSection("Combat")
toggle(Tabs.Farming, "KillAuraGun", "Kill Aura Gun", "Tembak musuh dalam jarak 250 stud", function(v)
	S.killAuraGun = v refreshGun()
end)
toggle(Tabs.Farming, "NoCDGun", "No Cooldown Gun Flintlock", "Hapus cooldown gun terus-menerus", function(v)
	S.noCDGun = v refreshGun()
end)
toggle(Tabs.Farming, "FastAttack", "Fast Attack", "Auto tap, tanpa animasi, target di-freeze", function(v)
	S.fastAttack = v
	if not v then unfreezeAll() end
	if farmActive() then stopLoop("attack") refreshFarm() end
end)
toggle(Tabs.Farming, "Bring", "Bring", "Tarik musuh dalam 100 stud dengan smooth", function(v)
	S.bring = v
end)
toggle(Tabs.Farming, "NoEffect", "No Effect Attack", "Matikan efek partikel serangan", function(v)
	S.noEffect = v setNoEffect(v)
end)

-- ---------- SETTING ----------
Tabs.Setting:AddSection("Gerak Paksa")
Tabs.Setting:AddSlider("Force", {
	Title = "Setting Force", Description = "Kecepatan gerak paksa (100-500)",
	Default = 200, Min = 100, Max = 500, Rounding = 0,
	Callback = function(v) S.force = v end,
})
Tabs.Setting:AddSlider("Height", {
	Title = "Jarak dari NPC", Description = "Above/Down/Side/Orbit (6-8 paling aman)",
	Default = 7, Min = 4, Max = 15, Rounding = 0,
	Callback = function(v) S.height = v end,
})
Tabs.Setting:AddSlider("BringRange", {
	Title = "Jarak Bring", Default = 100, Min = 30, Max = 200, Rounding = 0,
	Callback = function(v) S.bringRange = v end,
})

Tabs.Setting:AddSection("Mode")
local fm = Tabs.Setting:AddDropdown("FarmMode", {
	Title = "Farming Mode", Values = { "Slow", "Smooth", "Medium", "Fast", "Instant" }, Multi = false, Default = 2,
})
fm:OnChanged(function(v) S.mode = v end)

toggle(Tabs.Setting, "ResetAttack", "Reset Attack", "Hapus cooldown tiap serangan lalu hit lagi", function(v)
	S.resetAttack = v
end)

-- ---------- UI CONFIG ----------
SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
SaveManager:IgnoreThemeSettings()
InterfaceManager:SetFolder("VeySellHub")
SaveManager:SetFolder("VeySellHub/VoxSeas")
InterfaceManager:BuildInterfaceSection(Tabs.Config)
SaveManager:BuildConfigSection(Tabs.Config)

Window:SelectTab(1)

-- ================= ICON BUKA/TUTUP =================
local iconGui = Instance.new("ScreenGui")
iconGui.Name = "VeySellIcon"
iconGui.ResetOnSpawn = false
iconGui.DisplayOrder = 999
do
	local ok = pcall(function() iconGui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
	if not ok or not iconGui.Parent then iconGui.Parent = LP:WaitForChild("PlayerGui") end
end

local iconBtn = Instance.new("ImageButton")
iconBtn.Name = "Toggle"
iconBtn.Size = UDim2.fromOffset(52, 52)
iconBtn.Position = UDim2.new(0, 16, 0.5, -26)
iconBtn.BackgroundColor3 = Color3.fromRGB(12, 16, 30)
iconBtn.Image = "rbxassetid://" .. ICON_ID
iconBtn.ScaleType = Enum.ScaleType.Fit
iconBtn.AutoButtonColor = true
iconBtn.Parent = iconGui
Instance.new("UICorner", iconBtn).CornerRadius = UDim.new(0, 14)
local stroke = Instance.new("UIStroke", iconBtn)
stroke.Color = Color3.fromRGB(70, 110, 220)
stroke.Thickness = 1.5

do
	local dragging, moved, startMouse, startPos
	iconBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved, startMouse, startPos = true, false, input.Position, iconBtn.Position
		end
	end)
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - startMouse
			if d.Magnitude > 6 then moved = true end
			if moved then
				iconBtn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			if not moved then pcall(function() Window:Minimize() end) end
		end
	end))
end

-- ================= CLEANUP =================
env.__VeySellCleanup = function()
	for k in pairs(flags) do flags[k] = false end
	unfreezeAll()
	setNoEffect(false)
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	pcall(function() iconGui:Destroy() end)
	pcall(function() Fluent:Destroy() end)
end

SaveManager:LoadAutoloadConfig()
Fluent:Notify({ Title = "VeySell Hub", Content = "Vox Seas 0.5 dimuat", Duration = 4 })
