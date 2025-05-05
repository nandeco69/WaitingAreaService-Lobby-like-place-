---Service references
local Players = game:GetService("Players")
local WorkSpace = game:GetService("Workspace")
local RS = game:GetService("RunService")
local ReS = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local SS = game:GetService("SoundService")
local CS = game:GetService("CollectionService")

---RemoteEvent references
local Remotes = ReS:WaitForChild("Remotes")
local WaitingRemote = Remotes:WaitForChild("WaitingArea")
local LeaveRemote = Remotes:WaitForChild("Leave")

---Shared and Local tables for organizing code logic
local Local = {}
local Shared = {}

---Constants for the game logic
local MAX_PLAYERS = 4
local CHECK_INTERVAL = 0.25
local COUNTDOWN_TIME = 15

---Tables for managing players and timers
local PlayersInArea = {}                                             ---Tracks which players are currently inside a waiting area
local WaitingAreas = {}                                              ---Stores references to all active waiting areas
local CountdownTimers = {}                                           ---Manages the countdown timers for each waiting area
local ActiveCountdowns = {}                                          ---Stores the countdown state to track if it's active
local PlayersOnTimer = {}                                            ---Keeps track of which players are currently involved in the countdown
local TeleportingFlags = {}                                          ---Flag used to prevent double teleportation (to avoid bugs where players might be teleported twice)                         
local LastDisplayedTime = {}                                         ---Stores the last time a countdown value was displayed to avoid redundant updates

function Shared.OnStart()
	local AccumulatedTime = 0                                        ---AccumulatedTime is used to regulate how often area updates occur (every CHECK_INTERVAL seconds)
	
	--[[ 
		Handles the "Leave" action triggered by the client.
		This provides a manual way for players to exit the waiting area.
		It also works as a fallback mechanism to ensure players can leave if any issue arises.
	]]--
	LeaveRemote.OnServerEvent:Connect(function(player: Player, action)               
		if action == "Leave" then                                                            
			Shared.HandleLeaveAction(player)                         ---Call the function that handles player removal and teleportation back to the spawn.
		end
	end)
	
	--[[
		Listens for client requests to start the countdown for a specific waiting area.
		This is triggered by the party leader when they press the "Create" button.
		The area name and desired party size are passed along for validation and countdown initiation.
	]]--
	WaitingRemote.OnServerEvent:Connect(function(player: Player, action, areaname, partysize)
		if action == "StartCountdown" then
			Shared.StartCountDownForArea(areaname, partysize)        ---Initiates countdown logic for the specified area
		end
	end)
	
	--[[
		Scans the workspace for all tagged waiting areas and stores references for runtime use.
		This is done once at the beginning to populate the WaitingAreas table.
		Each area is expected to have specific parts and tags used later for player detection and teleportation.
	]]--
	Shared.RegisterWaitingAreas()

	--[[
		Heartbeat is a frame-by-frame event used here to periodically check player positions.
		To avoid performance issues, the script accumulates time and only runs the update logic
		every CHECK_INTERVAL seconds (e.g., 0.25s).
		
		This periodic check updates which players are inside which waiting areas,
		and helps manage GUI display, countdowns, and area state in real time.
	]]--
	RS.Heartbeat:Connect(function(dt)                                                      
		AccumulatedTime += dt
		if AccumulatedTime >= CHECK_INTERVAL then
			AccumulatedTime = 0
			Shared.UpdateAllWaitingAreas()                           ---Performs area update logic such as checking player presence and updating GUIs
		end
	end)
end

function Shared.HandleLeaveAction(player: Player)
	local Char = player.Character
	
	--[[ 
		First, confirm the player's character exists in the workspace.
		If the character doesn't exist (e.g., during teleport), the function safely exits.
	]]--
	if Char then
		local Root = Char:FindFirstChild("HumanoidRootPart")
		local Spawn = WorkSpace:FindFirstChild("SpawnLocation")
		
		--[[
			We check for both the root part (for teleportation) and the SpawnLocation.
			This guarantees we have valid targets before performing the teleport.
		]]--
		if Root and Spawn then
			
			--[[ 
				Offset the position by +1 Y unit to avoid spawning the player inside the floor mesh.
				This also helps prevent physics issues or getting stuck.
			]]--
			Root.CFrame = Spawn.CFrame + Vector3.new(0, 1, 0)
			print("Player exited manually: " .. player.Name)
		end
	end
end

function Shared.StartCountDownForArea(areaname, partysize)
	
	--[[
		Check if a countdown is already running for this area.
		We don’t want to start overlapping countdowns, as that could lead to bugs like double teleports.
	]]--
	if ActiveCountdowns[areaname] then
		warn("Countdown already running for: " .. areaname)
		return
	end
	print("Initializing countdown for area: " .. tostring(areaname))
	
	--[[ 
		Delegates the countdown setup and management to the core function.
		This keeps entry points clean and separates logic concerns.
	]]--
	Shared.StartCountDown(areaname, partysize)
end

function Shared.RegisterWaitingAreas()
	
	--[[ 
		This function searches the game world for all objects tagged as "WaitingArea".
		Tags are used instead of hardcoding to make the system flexible.
	]]--
	for _, Area in CS:GetTagged("WaitingArea") do
		if Area:IsA("BasePart") then
			
			--[[ 
				Add this area to the global table, accessible during countdown and area checks.
				The name of the part is used as the key.
			]]--
			WaitingAreas[Area.Name] = Area
			
			--[[ 
				Initialize a player tracking list for this area.
				This will later store which players are inside it at a given time.
			]]--
			PlayersInArea[Area.Name] = {}
			print("Area registered (via CollectionService): " .. Area.Name)
		end
	end
end

function Shared.UpdateAllWaitingAreas()
	
	--[[
		Loop through all known waiting areas (previously registered) and check their current state.
		Each area's logic is handled by Shared.UpdateArea, which handles player detection,
		GUI management, and visual feedback.
	]]--
	for Areaname, Part in pairs(WaitingAreas) do
		Shared.UpdateArea(Areaname, Part)
	end
	
	--[[
		After updating player presence in all areas, we then update any active countdowns.
		This is important to sync countdown display and detect when to teleport players.
	]]--
	Shared.UpdateCountDowns()
end

function Shared.UpdateCountDowns()
	
	--[[
		Iterate through all currently running countdowns.
		Each countdown is stored in CountdownTimers with the area name as the key.
	]]--
	for areaname, timeleft in pairs(CountdownTimers) do                                     
		if timeleft > 0 then                             
			
			--[[ 
				Decrease the remaining time by the defined CHECK_INTERVAL (e.g., 0.25 seconds).
				This effectively makes the countdown progress smoothly over time.
			]]--
			CountdownTimers[areaname] -= CHECK_INTERVAL    
			
			--[[ 
				Update the visual billboard display to reflect the remaining countdown time.
				This keeps the GUI in sync with the backend countdown logic.
			]]--
			Shared.UpdateBillBoard(areaname)                                                
		else                                                                               
			print("Countdown completed in the area: " .. areaname)
			
			--[[ 
				This function handles teleporting all players in the specified area to their destination.
			]]--
			Shared.TeleportPlayerInArea(areaname)
			
			--[[ 
				Clear the countdown state for this area.
				This ensures the area is free for new parties to use again later.
			]]--
			ActiveCountdowns[areaname] = nil
			CountdownTimers[areaname] = nil
			PlayersOnTimer[areaname] = nil
			
			--[[ 
				Final GUI update to hide/remove the countdown display after teleportation.
			]]--
			Shared.UpdateBillBoard(areaname)
		end
	end
end

function Shared.StartCountDown(areaname: string, partysize: number)
	
	--[[ 
		Loop through all players currently in the area, and notify their clients
		to show the "Leave" button.
		This gives players the chance to back out before the countdown finishes.
	]]--
	for _, player in ipairs(PlayersInArea[areaname]) do
		WaitingRemote:FireClient(player, "LeaveButton")
	end
	if ActiveCountdowns[areaname] then return end


	--[[ 
		Mark this area as having an active countdown to prevent overlaps.
		Also store the starting time and expected party size.
	]]--
	ActiveCountdowns[areaname] = true                                                      
	CountdownTimers[areaname] = COUNTDOWN_TIME                                              
	PlayersOnTimer[areaname] = partysize                                                  
end

function Shared.UpdateBillBoard(areaname: string)
	
	--[[ 
		Find the specific waiting area part in the workspace based on the given area name.
	]]--
	local Area = workspace.Scene.WaitingAreas:FindFirstChild(areaname)
	if not Area then return end

	--[[ 
		Each waiting area has an "Anchor" part that holds the BillboardGui.
	]]--
	local Anchor = Area:FindFirstChild("Anchor")
	if not Anchor then return end

	--[[ 
		This GUI displays information such as countdown and player count.
	]]--
	local BillBoard = Anchor:WaitForChild("WaitingBillBoard")
	if not BillBoard then return end

	--[[ 
		Get the text label inside the billboard, which we’ll update with display info.
	]]--
	local Label = BillBoard:FindFirstChild("WaitingLabel")
	if not Label then return end

	--[[ 
		Retrieve current players in this area and the required maximum from the timer settings.
		If no custom timer is set, default to MAX_PLAYERS.
	]]--
	local CurrentPlayers = PlayersInArea[areaname] or {}
	local MaxPlayers = PlayersOnTimer[areaname] or MAX_PLAYERS
	local DisplayText = ""

	--[[ 
		If there's an active countdown, format the label to show remaining time and player count.
	]]--
	if CountdownTimers[areaname] then                                                      
		local time = math.ceil(CountdownTimers[areaname])
		DisplayText = string.format("Starting in... %d\n%d/%d", time, #CurrentPlayers, MaxPlayers)
		Label.Text = DisplayText
		
		--[[ 
			Trigger a countdown effect (particles/sound/etc) exactly when the timer hits 4 seconds.
		]]--
		if time == 4 then
			Shared.PlayCountdownEffect(areaname)
		end
		
		--[[ 
			Apply countdown effects during the final 5 seconds.
			This includes text animation and sound feedback.
		]]--
		if time <= 5 then
			if LastDisplayedTime[areaname] ~= time then
				LastDisplayedTime[areaname] = time
				
				--[[
					Create a bounce effect on the label by tweening its TextSize up and back down.
				]]--
				local OriginalSize = Label.TextSize
				local TweenUp = TS:Create(Label, TweenInfo.new(0.15, 
					Enum.EasingStyle.Quad, 
					Enum.EasingDirection.Out), {
						TextSize = OriginalSize + 8
					})
				local TweenDown = TS:Create(Label, TweenInfo.new(0.15, 
					Enum.EasingStyle.Quad, 
					Enum.EasingDirection.In), {
						TextSize = OriginalSize
					})
				
				TweenUp:Play()
				TweenUp.Completed:Connect(function()
					TweenDown:Play()
				end)
				
				--[[
					Play a countdown beep. Use a different sound for "0" as a launch effect.
				]]--
				local Sound = Instance.new("Sound")
				if time == 0 then
					Sound.SoundId = "rbxassetid://5066021887"
				else
					Sound.SoundId = "rbxassetid://646200154"
				end
				
				Sound.Volume = 0.5
				Sound.Parent = Anchor
				Sound:Play()
				game.Debris:AddItem(Sound, 2)
			end	
		end
	else
		
		--[[ 
			If there's no countdown, just display how many players are currently inside the area.
		]]--
		DisplayText = string.format("Waiting for players... \n%d/%d", #CurrentPlayers, MaxPlayers)
		Label.Text = DisplayText
		
		--[[
			Reset countdown so it’s clean next time.
		]]--
		LastDisplayedTime[areaname] = nil
	end
end

function Shared.UpdateArea(areaname: string, part: BasePart)
	
	--[[ 
		Scan all players to check if their characters are currently inside the waiting area part.
		This is done using object-space conversion to measure relative distance from the part center.
	]]--
	local FoundPlayers = {}
	for _, player in ipairs(Players:GetPlayers()) do                                          
		local Char = player.Character 
		if Char then                                                                      
			local Root = Char:FindFirstChild("HumanoidRootPart")
			if Root and Root:IsDescendantOf(WorkSpace) then
				
				--[[
					Convert world position to local space to check if player is within bounds.
				]]--
				local Relative = part.CFrame:PointToObjectSpace(Root.Position) 
				local Bounds = Vector3.new(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
				if math.abs(Relative.X) <= Bounds.X and 
					math.abs(Relative.Y) <= Bounds.Y and 
					math.abs(Relative.Z) <= Bounds.Z then
					table.insert(FoundPlayers, player)
				end
			end
		end
	end
	
	--[[ 
		Remove players who are no longer inside the area from the tracking list.
		This maintains an up-to-date state for each area.
	]]--
	local CurrentPlayers = PlayersInArea[areaname] or {}                                       
	for i = #CurrentPlayers, 1, -1 do                                                        
		local Player = CurrentPlayers[i]
		if not table.find(FoundPlayers, Player) then
			table.remove(CurrentPlayers, i)
			print("Player left the area:" .. Player.Name)
		end
	end
	
	--[[ 
		Check if the area was empty before — this is important for determining whether
		we should show the UI again when the first player joins.
	]]--
	local WasEmpty = #CurrentPlayers == 0

	--[[ 
		Add new players who just entered the area and aren't already tracked.
		If a countdown is active, show them the leave button.
	]]--
	for _, player in ipairs(FoundPlayers) do
		if not table.find(CurrentPlayers, player) and not Shared.IsAreaFull(areaname) then      
			table.insert(CurrentPlayers, player)
			print("Player entered the area:" .. player.Name)
			if ActiveCountdowns[areaname] then                                           
				WaitingRemote:FireClient(player, "LeaveButton")
			end
		end
	end


	--[[ 
		If the area was previously empty but now has at least one player,
		show the full area UI to the first player who entered.
		This prevents the UI from spamming everyone when the area fills.
	]]--
	if WasEmpty and #CurrentPlayers >= 1 then                                                
		local FirstPlayer = CurrentPlayers[1]
		if FirstPlayer then
			WaitingRemote:FireClient(FirstPlayer, "ShowUI", areaname)
		end
	end

	--[[ 
		Update the global tracking table with the current player list.
	]]--
	PlayersInArea[areaname] = CurrentPlayers
	Shared.UpdateBillBoard(areaname)                                                      
	Shared.DebugAreaStatus(areaname)
end

function Shared.TeleportPlayerInArea(areaname: string)
	
	--[[ 
		If this area is already processing a teleport, we skip to prevent overlapping actions.
		This avoids issues like double teleportation or player duplication.
	]]--
	if TeleportingFlags[areaname] then
		warn("Area " .. areaname .. " is already in the process of teleportation")
		return
	end


	--[[ 
		Set the teleporting flag to true for this area to prevent re-entry into this function.
		This acts as a lock while teleportation is in progress.
	]]--
	TeleportingFlags[areaname] = true
	
	--[[ 
		Locate the folder in the workspace that stores all teleport destination points.
	]]--
	local TeleportPointsFolder = WorkSpace.Scene:FindFirstChild("TeleportPoints")
	local Target = TeleportPointsFolder and TeleportPointsFolder:FindFirstChild(areaname) 
	if not Target then
		warn("Folder not found for zone: " .. areaname)
		
		--[[
			Clean up the flag so this area can teleport again in the future.
		]]--
		TeleportingFlags[areaname] = nil
		return
	end

	--[[ 
		Fetch the list of players currently stored in this area.
		If for some reason it's nil (e.g. no players left), cancel the teleport.
	]]--
	local Players = PlayersInArea[areaname]
	if not Players then
		TeleportingFlags[areaname] = nil
		return
	end
	
	--[[ 
		Try to create a visual particle effect before teleporting.
		Only run if we successfully found the Area and Anchor parts.
	]]--
	local Area = WaitingAreas[areaname]
	local Anchor = Area and Area:FindFirstChild("Anchor")
	if Anchor and Area then
		Shared.CreateTeleportParticles(Anchor.Position, Area.Size)
	end

	--[[ 
		Call a function to move all players to the destination.
	]]--
	Shared.PerformTeleport(Players, Target.CFrame)    
	
	--[[ 
		Teleport completed, clear the teleporting flag so this area can be used again.
	]]--
	TeleportingFlags[areaname] = nil
end

function Shared.CreateTeleportParticles(position: Vector3, size: Vector3)
	
	--[[ 
		Get the pre-made glitch particle templates stored in ReplicatedStorage.
		These will be cloned and used to create a visual effect around the area.
	]]--
	local TemplateFolder = ReS.Particles:WaitForChild("Glitch")
	
	--[[ 
		Clamp the height of the particle volume to avoid oversized effects.
		Adjust the particle box to match the area while keeping visuals manageable.
	]]--
	local AdjustHeight = math.min(size.Y, 8)
	local AdjustSize = Vector3.new(size.X, AdjustHeight, size.Z)
	
	
	--[[ 
		Create a transparent, anchored part in the world to host the emitters.
		This part acts as a container for visual effects.
	]]--
	local ParticlePart = Instance.new("Part")
	ParticlePart.Anchored = true
	ParticlePart.CanCollide = false
	ParticlePart.Transparency = 1
	ParticlePart.Size = AdjustSize
	ParticlePart.CFrame = CFrame.new(position - Vector3.new(0, (size.Y / 2) - (AdjustHeight / 2), 0))
	ParticlePart.Parent = WorkSpace
	
	
	--[[ 
		Loop through each template emitter and clone it into our new part.
		Each emitter is enabled and given a unique name.
	]]--
	for _, TemplateEmitter in ipairs(TemplateFolder:GetChildren()) do
		if TemplateEmitter:IsA("ParticleEmitter") then
			local Emitter = TemplateEmitter:Clone()
			Emitter.Parent = ParticlePart
			Emitter.Name = "GlitchEmitter_" .. tostring(TemplateEmitter.Name)
			Emitter.Texture = TemplateEmitter.Texture
			Emitter.Color = TemplateEmitter.Color
			Emitter.Enabled = true
			
			
			--[[ 
				After 3 seconds, we trigger a fade-out by tweening transparency over time.
				This creates a smooth exit effect rather than abruptly cutting off.
			]]--
			task.delay(3, function()
				local FadeObject = Instance.new("NumberValue")
				FadeObject.Value = 0
				local FadeTween = TS:Create(FadeObject, TweenInfo.new(1), {
					Value = 1
				})
				FadeTween:Play()
				
				FadeObject.Changed:Connect(function(value)
					Emitter.Transparency = NumberSequence.new(value)
				end)
			end)
		end
	end
	
	
	--[[ 
		Schedule automatic cleanup after 6 seconds to keep workspace clean.
		Debris service used for auto-destruction of temporary visuals.
	]]--
	game.Debris:AddItem(ParticlePart, 6)
end

function Shared.CreatePlayerParticles(player: Player)
	
	--[[ 
		Get the character model of the player.
	]]--
	local Char = player.Character
	if not Char then return end
	
	--[[ 
		Get the HumanoidRootPart.
		Used to position and weld the visual effect.
	]]--
	local Root = Char:FindFirstChild("HumanoidRootPart")
	if not Root then return end
	
	
	--[[ 
		Create a new invisible part to attach the glitch effect.
		Slightly larger than the character to make the effect more visible.
	]]--
	local EffectPart = Instance.new("Part")
	EffectPart.Anchored = false
	EffectPart.CanCollide = false
	EffectPart.Transparency = 1
	EffectPart.Size = Vector3.new(4, 7, 2)
	EffectPart.CFrame = Root.CFrame
	EffectPart.Parent = Char
	
	
	--[[ 
		Weld the visual part to the character so it moves with them.
		Using WeldConstraint ensures physics stability and performance.
	]]--
	local Weld = Instance.new("WeldConstraint")
	Weld.Part0 = EffectPart
	Weld.Part1 = Root
	Weld.Parent = EffectPart
	
	
	--[[ 
		Clone each emitter from the glitch template and enable it immediately.
		We apply this effect directly to the newly created part.
	]]--
	for _, TemplateEmitter in ipairs(ReS.Particles.Glitch:GetChildren()) do
		if TemplateEmitter:IsA("ParticleEmitter") then
			local Emitter = TemplateEmitter:Clone()
			Emitter.Parent = EffectPart
			Emitter.Enabled = true
			
			
			--[[ 
				After 1.5 seconds, start fading out the emitter with a tweened transparency.
				This gives the effect a natural exit without being abrupt.
			]]--
			task.delay(1.5, function()
				local FadeObject = Instance.new("NumberValue")
				FadeObject.Value = 0
				local FadeTween = TS:Create(FadeObject, TweenInfo.new(1), {
					Value = 1
				})
				FadeTween:Play()
				
				FadeObject.Changed:Connect(function(value)
					Emitter.Transparency = NumberSequence.new(value)
				end)
			end)
		end
	end
	
	--[[ 
		Clean up the effect part after 3 seconds to avoid cluttering the character model.
	]]--
	game.Debris:AddItem(EffectPart, 3)
end

function Shared.PlayCountdownEffect(areaname: string)
	
	--[[
		Locate the area where the countdown effect will be triggered.
	]]--
	local Area = WaitingAreas[areaname]
	if not Area then return end


	--[[
		Ensure that this area isn't already playing the countdown effect.
		This prevents overlapping visuals if the function is called twice rapidly.
	]]--
	if Area:FindFirstChild("CountdownOrb") then return end


	--[[
		Create a visual orb that represents the countdown charging phase.
		This part uses a glowing neon material and grows over time.
	]]--
	local Orb = Instance.new("Part")
	Orb.Name = "CountdownOrb"
	Orb.Shape = Enum.PartType.Ball
	Orb.Anchored = true
	Orb.CanCollide = false
	Orb.Material = Enum.Material.Neon
	Orb.Color = Color3.new(1, 1, 1)
	Orb.Transparency = 0.1
	Orb.Size = Vector3.new(1, 1, 1)
	Orb.CFrame = Area.CFrame
	Orb.Parent = Area

	--[[
		Add a soft point light to the orb for atmospheric visual effect.
		This grows in intensity along with the orb’s size.
	]]--
	local Light = Instance.new("PointLight")
	Light.Color = Color3.new(1, 1, 1)
	Light.Brightness = 0.5
	Light.Range = 1
	Light.Parent = Orb
	
	--[[
		Add a charging sound to enhance feedback during the countdown effect.
	]]--
	local ChargeSound = Instance.new("Sound")
	ChargeSound.SoundId = "rbxassetid://8392900771"
	ChargeSound.Volume = 0.5
	ChargeSound.PlayOnRemove = false
	ChargeSound.Parent = Orb
	ChargeSound:Play()
	game.Debris:AddItem(ChargeSound, 7)

	--[[
		Tween the orb to grow and light up in sync over 4 seconds.
		This creates a charging animation leading to the teleport.
	]]--
	local InitialTweenInfo = TweenInfo.new(4, 
		Enum.EasingStyle.Sine, 
		Enum.EasingDirection.Out)
	local GrowTween = TS:Create(Orb, InitialTweenInfo, {
		Size = Area.Size
	})
	local LightUpTween = TS:Create(Light, InitialTweenInfo, {
		Brightness = 5,
		Range = Area.Size.Magnitude * 1.5
	})
	GrowTween:Play()
	LightUpTween:Play()

	--[[
		Once the orb has grown, delay slightly then shrink and fade it.
		This marks the end of the countdown visual effect.
	]]--
	GrowTween.Completed:Connect(function()
		task.delay(1, function()
			local ShrinkTween = TS:Create(Orb, TweenInfo.new(1), {
				Size = Vector3.new(1, 1, 1),
				Transparency = 1
			})
			local LightFade = TS:Create(Light, TweenInfo.new(1), {
				Brightness = 0,
				Range = 0
			})
			ShrinkTween:Play()
			LightFade:Play()
			ShrinkTween.Completed:Connect(function()
				Orb:Destroy()
			end)
		end)
	end)
end

function Shared.PerformTeleport(Players, targetcframe)
	
	--[[
		Loop through each player assigned to this teleport event.
		Check if their character and HumanoidRootPart are available.
	]]--
	for _, Player in ipairs(Players) do
		local Char = Player.Character
		if Char then
			local Root = Char:FindFirstChild("HumanoidRootPart")
			if Root then
				
				--[[
					Teleport the player slightly above the target CFrame to avoid clipping.
					This uses +Vector3.yAxis to push them upward by 1 stud.
				]]--
				Root.CFrame = targetcframe + Vector3.yAxis
				print("Teleported " .. Player.Name .. " to target zone.")
				
				--[[
					Trigger a remote event telling the client to hide the 'Leave' button.
					Only affects the player being teleported.
				]]--
				WaitingRemote:FireClient(Player, "ForceHideLeave")
				
				
				--[[
					Play a visual effect on the player.
				]]--
				Shared.CreatePlayerParticles(Player)
			end
		end
	end
end

function Shared.IsAreaFull(areaname)          
	
	--[[
		Get the list of players currently inside the specified area.
		If none are found, default to an empty list.
	]]--
	local Players = PlayersInArea[areaname] or {}
	
	--[[
		Check if the number of players has reached or exceeded the maximum allowed.
		Fallback to MAX_PLAYERS if no custom value is set for this area.
	]]--
	return #Players >= (PlayersOnTimer[areaname] or MAX_PLAYERS)
end

local LastDebugTime = {}
function Shared.DebugAreaStatus(areaname)   
	
	--[[
		Throttle debug prints to once every 5 seconds per area.
		This prevents console spam if the function is called repeatedly.
	]]--
	local Now = os.clock()
	local Last = LastDebugTime[areaname] or 0

	if Now - Last >= 5 then
		LastDebugTime[areaname] = Now
		
		--[[
			Print the current player count for the area.
			Useful during testing or diagnosing issues with group formation.
		]]--
		local Players = #PlayersInArea[areaname]
		print(string.format("Area [%s] currently has %d players.", areaname, Players))
	end
end

--[[
	Return the Shared table at the end to expose all its public functions
	to other modules or scripts requiring it.
]]--
return Shared
