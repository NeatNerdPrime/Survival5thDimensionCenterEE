-- Based on Survival Extreme V3FA script
-- First modified by Brock Samson
-- Then modified by Phelom, Spoon and Duck_42
-- And finally modified by EntropyWins

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua');
local ScenarioFramework = import('/lua/ScenarioFramework.lua');
local Utilities = import('/lua/utilities.lua');

local Survival_TickInterval = 0.50; -- how much delay between each script iteration

local Survival_NextSpawnTime = 0;
local Survival_CurrentTime = 0;

local Survival_GameState = 0; -- 0 pre-spawn, 1 post-spawn, 2 player win, 3 player defeat
local Survival_PlayerCount = 0; -- how many edge players there are
local Survival_PlayerCount_Total = 0; -- how many total players there are

local Survival_MarkerRefs = {{}, {}, {}, {}, {}}; -- 1 center / 2 waypoint / 3 spawn / 4 arty / 5 nuke

local Survival_UnitCountPerMinute = 0; -- how many units to spawn per minute (taking into consideration player count)
local Survival_UnitCountPerWave = 0; -- how many units to spawn with each wave (taking into consideration player count)

local Survival_MinWarnTime = 0;

local Survival_DefUnit = nil;
local Survival_DefCheckHP = 0.0;
local Survival_DefLastHP = 0;

local Survival_ObjectiveTime = 2400;

local function localImport(fileName)
	return import('/maps/survival_5th_dimension_center_ee.v0005/src/' .. fileName)
end

local waveTables = localImport('WaveTables.lua').getWaveTables()
local textPrinter = localImport('lib/TextPrinter.lua').newInstance()
local unitCreator = localImport('lib/UnitCreator.lua').newUnitCreator()

local function defaultOptions()
	if (ScenarioInfo.Options.opt_Survival_BuildTime == nil) then
		ScenarioInfo.Options.opt_Survival_BuildTime = 300;
	end

	if (ScenarioInfo.Options.opt_Survival_EnemiesPerMinute == nil) then
		ScenarioInfo.Options.opt_Survival_EnemiesPerMinute = 32;
	end

	if (ScenarioInfo.Options.opt_Survival_WaveFrequency == nil) then
		ScenarioInfo.Options.opt_Survival_WaveFrequency = 10;
	end

    if (ScenarioInfo.Options.opt_CenterAutoReclaim == nil) then
        ScenarioInfo.Options.opt_CenterAutoReclaim = 0;
    end

    if (ScenarioInfo.Options.opt_CenterAllFactions == nil) then
        ScenarioInfo.Options.opt_CenterAllFactions = 0;
    end
end

local function setupAutoReclaim()
	local percentage = ScenarioInfo.Options.opt_CenterAutoReclaim

	if percentage > 0 then
		unitCreator.onUnitCreated(function(unit, unitInfo)
			if unitInfo.isSurvivalSpawned then
				unit.CreateWreckage = function() end
			end
		end)

		ForkThread(
			localImport('lib/AutoReclaim.lua').AutoResourceThread,
			percentage / 100,
			percentage / 100
		)
	end
end

local function isPlayerArmy(armyName)
    return armyName == "ARMY_1" or armyName == "ARMY_2" or armyName == "ARMY_3" or armyName == "ARMY_4"
            or armyName == "ARMY_5" or armyName == "ARMY_6" or armyName == "ARMY_7" or armyName == "ARMY_8"
end

local function setupAllFactions()
    if ScenarioInfo.Options.opt_CenterAllFactions ~= 0 then
        local allFactions = localImport('lib/AllFactions.lua')

        for armyIndex, armyName in ListArmies() do
            if isPlayerArmy(armyName) then
                if ScenarioInfo.Options.opt_CenterAllFactions == 1 then
                    allFactions.spawnExtraEngineers(ArmyBrains[armyIndex])
                else
                    allFactions.spawnExtraAcus(ArmyBrains[armyIndex])
                end
            end
        end
    end
end

local function setBotColor()
	ForkThread(function()
		SetArmyColor("ARMY_SURVIVAL_ENEMY", 110, 90, 90)

		WaitSeconds(900 + 10) -- Start just after wave set 16

		textPrinter.print("DISCO MODE RANGEBOTS!", {size = 22})

		local colorChanger = localImport('lib/ColorChanger.lua').newInstance("ARMY_SURVIVAL_ENEMY")
		colorChanger.start()

		WaitSeconds(60) -- Duration of wave set 16

		colorChanger.stop()
		SetArmyColor("ARMY_SURVIVAL_ENEMY", 110, 90, 90)
	end)
end

local function showWelcomeMessages()
	local welcomeMessages = localImport('WelcomeMessages.lua').newInstance(
		textPrinter,
		ScenarioInfo.Options,
		ScenarioInfo.map_version
	)

	welcomeMessages.startDisplay()
end

local function vanguardify()
	unitCreator.onUnitCreated(function(unit, unitInfo)
		if unitInfo.isSurvivalSpawned and unitInfo.blueprintName == "DEL0204" then
			unit:SetCustomName("Minion of Vanguard")
		end
	end)
end

function OnPopulate()
	ScenarioUtils.InitializeArmies()

	defaultOptions()

	setBotColor()
    setupAutoReclaim()
    setupAllFactions()
	vanguardify()

	Survival_InitGame()

	showWelcomeMessages()
end

local function createSurvivalUnit(blueprint, x, z, y)
    local unit = unitCreator.spawnSurvivalUnit({
        blueprintName = blueprint,
        armyName = "ARMY_SURVIVAL_ENEMY",
        x = x,
        z = z,
        y = y
    })

    return unit
end

-- econ adjust based on who is playing
-- taken from original survival/Jotto
--------------------------------------------------------------------------
function ScenarioUtils.CreateResources()

	local Markers = ScenarioUtils.GetMarkers();

	for i, tblData in pairs(Markers) do -- loop marker list

		local SpawnThisResource = false; -- default to no

		if (tblData.resource and not tblData.SpawnWithArmy) then -- if this is a regular resource
			SpawnThisResource = true;
		elseif (tblData.resource and tblData.SpawnWithArmy) then -- if this is an army-specific resource

			if (tblData.SpawnWithArmy == "ARMY_0") then
				SpawnThisResource = true;
			else
				for x, army in ListArmies() do -- loop through army list

					if (tblData.SpawnWithArmy == army) then -- if this army is present
						SpawnThisResource = true; -- spawn this resource
						break;
					end
				end
			end
		end

		if (SpawnThisResource) then -- if we can spawn the resource do it

			local bp, albedo, sx, sz, lod;

			if (tblData.type == "Mass") then
				albedo = "/env/common/splats/mass_marker.dds";
				bp = "/env/common/props/massDeposit01_prop.bp";
				sx = 2;
				sz = 2;
				lod = 100;
			else
				albedo = "/env/common/splats/hydrocarbon_marker.dds";
				bp = "/env/common/props/hydrocarbonDeposit01_prop.bp";
				sx = 6;
				sz = 6;
				lod = 200;
			end

			-- create the resource
			CreateResourceDeposit(tblData.type,	tblData.position[1], tblData.position[2], tblData.position[3], tblData.size);

			-- create the resource graphic on the map
			CreatePropHPR(bp, tblData.position[1], tblData.position[2], tblData.position[3], Random(0,360), 0, 0);

			-- create the resource icon on the map
			CreateSplat(
				tblData.position,           -- Position
				0,                          -- Heading (rotation)
				albedo,                     -- Texture name for albedo
				sx, sz,                     -- SizeX/Z
				lod,                        -- LOD
				0,                          -- Duration (0 == does not expire)
				-1,                         -- army (-1 == not owned by any single army)
				0							-- ???
			);
		end
	end
end



function OnStart(self)
	ForkThread(Survival_Tick);
end



-- initializes the game settings
--------------------------------------------------------------------------
Survival_InitGame = function()

	LOG("----- Survival MOD: Configuring match settings...");


	Survival_NextSpawnTime = ScenarioInfo.Options.opt_Survival_BuildTime; -- set first wave time to build time
	Survival_MinWarnTime = Survival_NextSpawnTime - 60; -- set time for minute warning


	ScenarioInfo.Options.Victory = 'sandbox'; -- force sandbox in order to implement our own rules

	Survival_PlayerCount = 0;
	
	local Armies = ListArmies();
	Survival_PlayerCount_Total = table.getn(Armies) - 2;

	-- loop through armies
	for i, Army in ListArmies() do
		if (Army == "ARMY_1" or Army == "ARMY_2" or Army == "ARMY_3" or Army == "ARMY_4") then
			Survival_PlayerCount = Survival_PlayerCount + 1; -- save player count (ignore players in the middle)
		end
	
		-- Add build restrictions
		if (Army == "ARMY_1" or Army == "ARMY_2" or Army == "ARMY_3" or Army == "ARMY_4" or Army == "ARMY_5" or Army == "ARMY_6" or Army == "ARMY_7" or Army == "ARMY_8") then 

			ScenarioFramework.AddRestriction(Army, categories.WALL); -- don't allow them to build walls
			ScenarioFramework.AddRestriction(Army, categories.AIR - categories.ENGINEER); -- don't allow them to build air stuff

			-- loop through other armies to ally with other human armies
			for x, ArmyX in ListArmies() do
				-- if human army
				if (ArmyX == "ARMY_1" or ArmyX == "ARMY_2" or ArmyX == "ARMY_3" or ArmyX == "ARMY_4" or ArmyX == "ARMY_5" or ArmyX == "ARMY_6" or ArmyX == "ARMY_7" or ArmyX == "ARMY_8") then 
					SetAlliance(Army, ArmyX, 'Ally'); 
				end
			end			

			SetAlliance(Army, "ARMY_SURVIVAL_ALLY", 'Ally'); -- friendly AI team
			SetAlliance(Army, "ARMY_SURVIVAL_ENEMY", 'Enemy');  -- enemy AI team

			SetAlliedVictory(Army, true); -- can win together of course :)
		end
	end

	SetAlliance("ARMY_SURVIVAL_ALLY", "ARMY_SURVIVAL_ENEMY", 'Enemy'); -- the friendly and enemy AI teams should be enemies

	SetIgnoreArmyUnitCap('ARMY_SURVIVAL_ENEMY', true); -- remove unit cap from enemy AI team

	Survival_InitMarkers(); -- find and reference all the map markers related to survival
	Survival_SpawnDef();
	Survival_SpawnPrebuild();

	Survival_CalcWaveCounts(); -- calculate how many units per wave

end



-- spawns a specified unit
--------------------------------------------------------------------------
Survival_InitMarkers = function()

	LOG("----- Survival MOD: Initializing marker lists...");

	local MarkerRef = nil;
	local Break = 0;
	local i = 1;

	while (Break < 3) do

		Break = 0; -- reset break counter

		-- center
		MarkerRef = GetMarker("SURVIVAL_CENTER_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[1], MarkerRef);
--			Survival_MarkerCounts[1] = Survival_MarkerCounts[1] + 1;
		else
			Break = Break + 1;
		end

		-- path
		MarkerRef = GetMarker("SURVIVAL_PATH_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[2], MarkerRef);
--			Survival_MarkerCounts[2] = Survival_MarkerCounts[2] + 1;
		else
			Break = Break + 1;
		end

		-- spawn
		MarkerRef = GetMarker("SURVIVAL_SPAWN_" .. i);

		if (MarkerRef ~= nil) then
			for x, army in ListArmies() do -- loop through army list
				if (MarkerRef.SpawnWithArmy == army) then -- if this army is present
					table.insert(Survival_MarkerRefs[3], MarkerRef);
					break;
				end
			end
			
--			Survival_MarkerCounts[3] = Survival_MarkerCounts[3] + 1;
		else
			Break = Break + 1;
		end

		i = i + 1; -- increment counter

	end

	LOG("----- Survival MOD: Marker counts:     CENTER(" .. table.getn(Survival_MarkerRefs[1]) .. ")     PATHS(" .. table.getn(Survival_MarkerRefs[2]) .. ")     SPAWN(" .. table.getn(Survival_MarkerRefs[3]) .. ")     ARTY(" .. table.getn(Survival_MarkerRefs[4]) .. ")     NUKE(" .. table.getn(Survival_MarkerRefs[5]) .. ")");

end

Survival_SpawnDef = function()

	LOG("----- Survival MOD: Initializing defense object...");

	local POS = ScenarioUtils.MarkerToPosition("SURVIVAL_CENTER_1");
	Survival_DefUnit = CreateUnitHPR('XRB3301', "ARMY_SURVIVAL_ALLY", POS[1], POS[2], POS[3], 0,0,0);

	Survival_DefUnit:SetReclaimable(false);
	Survival_DefUnit:SetCapturable(false);
	Survival_DefUnit:SetProductionPerSecondEnergy((Survival_PlayerCount_Total * 100) + 0);
	Survival_DefUnit:SetConsumptionPerSecondEnergy(0);

	local defenseObjectHealth = 9000 - (Survival_PlayerCount_Total * 1000);
	Survival_DefUnit:SetMaxHealth(defenseObjectHealth);
	Survival_DefUnit:SetHealth(nil, defenseObjectHealth);
	Survival_DefUnit:SetRegenRate(defenseObjectHealth / 180.0); --It takes 3 minutes for the defense object to fully regenerate.

	local Survival_DefUnitBP = Survival_DefUnit:GetBlueprint();
	Survival_DefUnitBP.Intel.MaxVisionRadius = 350;
	Survival_DefUnitBP.Intel.MinVisionRadius = 350;
	Survival_DefUnitBP.Intel.VisionRadius = 350;

	Survival_DefUnit:SetIntelRadius('Vision', 350)

	-- when the def object dies
	Survival_DefUnit.OldOnKilled = Survival_DefUnit.OnKilled;

	Survival_DefUnit.OnKilled = function(self, instigator, type, overkillRatio)
		if (Survival_GameState ~= 2) then -- If the timer hasn't expired yet...
			LOG("----------- SCEE: OnKilled")
			self.OldOnKilled(self, instigator, type, overkillRatio)
			LOG("----------- SCEE: OnKilled 2")

			textPrinter.print(
				"The defense object has been destroyed. You have lost!",
				{ color = "ffff5555", duration = 8 }
			)
		
			LOG("----------- SCEE: OnKilled 3")

			Survival_GameState = 3;

			for i, army in ListArmies() do

				if (army == "ARMY_1" or army == "ARMY_2" or army == "ARMY_3" or army == "ARMY_4" or army == "ARMY_5" or army == "ARMY_6" or army == "ARMY_7" or army == "ARMY_8") then
					GetArmyBrain(army):OnDefeat();
				end
			end
			GetArmyBrain("ARMY_SURVIVAL_ENEMY"):OnVictory();
		end
	end

	Survival_DefLastHP = Survival_DefUnit:GetHealth();

end



-- spawns a specified unit
--------------------------------------------------------------------------
Survival_SpawnPrebuild = function()

	LOG("----- Survival MOD: Initializing pre-build objects...");

	local FactionID = nil;

	local MarkerRef = nil;
	local POS = nil;
	local FactoryRef = nil;

	for i, Army in ListArmies() do
		if (Army == "ARMY_1" or Army == "ARMY_2" or Army == "ARMY_3" or Army == "ARMY_4" or Army == "ARMY_5" or Army == "ARMY_6" or Army == "ARMY_7" or Army == "ARMY_8") then 

			FactionID = GetArmyBrain(Army):GetFactionIndex();

			MarkerRef = GetMarker("SURVIVAL_FACTORY_" .. Army);

			if (MarkerRef ~= nil) then
				POS = MarkerRef.position;

				if (FactionID == 1) then -- uef
					FactoryRef = CreateUnitHPR('UEB0101', Army, POS[1], POS[2], POS[3], 0,0,0);
				elseif (FactionID == 2) then -- aeon
					FactoryRef = CreateUnitHPR('UAB0101', Army, POS[1], POS[2], POS[3], 0,0,0);
				elseif (FactionID == 3) then -- cybran
					FactoryRef = CreateUnitHPR('URB0101', Army, POS[1], POS[2], POS[3], 0,0,0);
				elseif (FactionID == 4) then -- seraphim
					FactoryRef = CreateUnitHPR('XSB0101', Army, POS[1], POS[2], POS[3], 0,0,0);
				end
			end
		end
	end
end


local function SecondsToTime(Seconds)
	return string.format("%02d:%02d", math.floor(Seconds / 60), math.mod(Seconds, 60));
end


-- loops every TickInterval to progress main game logic
--------------------------------------------------------------------------
Survival_Tick = function(self)

	while (Survival_GameState < 2) do

		Survival_CurrentTime = GetGameTimeSeconds();

		Survival_UpdateWaves(Survival_CurrentTime);

		if (Survival_CurrentTime >= Survival_ObjectiveTime) then

			Survival_GameState = 2;
			BroadcastMSG("The Defence Object is complete! You have won!", 4);
			Survival_DefUnit:SetCustomName("CHUCK NORRIS MODE!"); -- update defense object name

			for i, army in ListArmies() do
				if (army == "ARMY_1" or army == "ARMY_2" or army == "ARMY_3" or army == "ARMY_4" or army == "ARMY_5" or army == "ARMY_6" or army == "ARMY_7" or army == "ARMY_8") then
					GetArmyBrain(army):OnVictory();
				end
			end

			GetArmyBrain("ARMY_SURVIVAL_ENEMY"):OnDefeat();
		else

			if (Survival_GameState == 0) then -- build stage

				if (Survival_CurrentTime >= Survival_NextSpawnTime) then -- if build period is over

					LOG("----- Survival MOD: Build state complete. Proceeding to combat state.");
					Sync.ObjectiveTimer = 0; -- clear objective timer
					Survival_GameState = 1; -- update game state to combat mode
					BroadcastMSG("Space Vikings are attacking!", 4);
					Survival_SpawnWave()
					Survival_NextSpawnTime = Survival_NextSpawnTime + ScenarioInfo.Options.opt_Survival_WaveFrequency; -- update next wave spawn time by wave frequency

				else -- build period still active

					Sync.ObjectiveTimer = math.floor(Survival_NextSpawnTime - Survival_CurrentTime); -- update objective timer
					Survival_DefUnit:SetCustomName(SecondsToTime(Sync.ObjectiveTimer)); -- update defense object name

					if ((Survival_MinWarnTime > 0) and (Survival_CurrentTime >= Survival_MinWarnTime)) then -- display 2 minute warning if we're at 2 minutes and it's appropriate to do so
						LOG("----- Survival MOD: Sending 1 minute warning.");
						BroadcastMSG("1 minute warning!", 2);
						Survival_MinWarnTime = 0; -- reset 2 minute warning time so it wont be displayed again
					end

				end

			elseif (Survival_GameState == 1) then -- combat stage

				Sync.ObjectiveTimer = math.floor(Survival_ObjectiveTime - Survival_CurrentTime); -- update objective timer

				if (Survival_CurrentTime >= Survival_NextSpawnTime) then -- ready to spawn a wave
					Survival_SpawnWave()
					Survival_NextSpawnTime = Survival_NextSpawnTime + ScenarioInfo.Options.opt_Survival_WaveFrequency; -- update next wave spawn time by wave frequency
				end

				Survival_DefUnit:SetCustomName('Level ' ..  (waveTables[1] - 1) .. "/" .. (table.getn(waveTables) - 1) );
			end

			Survival_DefCheckHP = Survival_DefCheckHP - Survival_TickInterval;

			if (Survival_DefCheckHP <= 0) then
				if (Survival_DefUnit:GetHealth() < Survival_DefLastHP) then
					local health = Survival_DefUnit:GetHealth();
					local maxHealth = Survival_DefUnit:GetMaxHealth();
					local defUnitPercent = health / maxHealth;
					BroadcastMSG("The Defence Object is taking damage! (" .. math.floor(defUnitPercent * 100) .. "%)", 0.5);

					Survival_DefCheckHP = 2;
				end
			end

			Survival_DefLastHP = Survival_DefUnit:GetHealth();

			WaitSeconds(Survival_TickInterval);
		end
	end
	
	--End the game the correct way
	WaitSeconds(15);
	import('/lua/victory.lua').CallEndGame(true, false);
	KillThread(self);
end



-- updates spawn waves
--------------------------------------------------------------------------
Survival_UpdateWaves = function(GameTime)
	for waveIndex = waveTables[1], table.getn(waveTables) do -- loop through each wave table within the category

		if (GameTime >= (waveTables[waveIndex][1] * 60)) then -- compare spawn time against the first entry spawn time for each wave table
			if (waveTables[1] < waveIndex) then -- should only update a wave once
			
				waveTables[1] = waveIndex; -- update the wave id for this wave category
			end
		else
			break;
		end
	end
end



-- spawns a wave of units
--------------------------------------------------------------------------
local function spawnWaveTable(waveTable)
	-- pick a random unit table from within this wave set
	local UnitTable = waveTable[math.random(2, table.getn(waveTable))]; -- reference that unit table

	Survival_SpawnUnit(
		Survival_GetUnitFromTable(UnitTable), -- pick a random unit id from this table
		UnitTable[2] -- get the order id from this unit table (always 2nd entry)
	);
end

Survival_SpawnWave = function()
	-- for the amount of units we spawn in per wave
	if (table.getn(waveTables[waveTables[1]]) > 1) then -- only do a wave spawn if there is a wave table available
		-- for the amount of units we spawn in per wave
		for z = 1,Survival_UnitCountPerWave do
			spawnWaveTable(waveTables[waveTables[1]])
		end
	end
end



-- spawns a specified unit
--------------------------------------------------------------------------
Survival_SpawnUnit = function(UnitID, OrderID) -- blueprint, army, position, order
    local POS = Survival_GetPOS(3, 25)

--	LOG("----- Survival MOD: SPAWNUNIT: Start function...");
	local PlatoonList = {};

	local NewUnit = createSurvivalUnit(UnitID, POS[1], POS[2], POS[3])

	-- prevent wreckage from enemy units
--	local BP = NewUnit:GetBlueprint();
--	if (BP ~= nil) then
--		BP.Wreckage = nil;
--	end

	NewUnit:SetProductionPerSecondEnergy(325);

	table.insert(PlatoonList, NewUnit); -- add unit to a platoon
	Survival_PlatoonOrder("ARMY_SURVIVAL_ENEMY", PlatoonList, OrderID); -- give the unit orders

end



-- returns a random unit from within a specified unit table
--------------------------------------------------------------------------
Survival_GetUnitFromTable = function(UnitTable)

	local RandID = math.random(3, table.getn(UnitTable));
	local UnitID = UnitTable[RandID];

	return UnitID;

end



-- returns a random spawn position
--------------------------------------------------------------------------
Survival_GetPOS = function(MarkerType, Randomization)

	local RandID = 1;
--	local MarkerName = nil;

	RandID = math.random(1, table.getn(Survival_MarkerRefs[MarkerType]));  -- get a random value from the selected marker count
--	LOG("----- Survival MOD: GetPOS: RandID[" .. RandID .. "]");

	if (RandID == 0) then
		return nil;
	end

 	local POS = Survival_MarkerRefs[MarkerType][RandID].position;
 
 	if (MarkerType == 4) then
 		table.remove(Survival_MarkerRefs[4], RandID);
 	elseif (MarkerType == 5) then
 		table.remove(Survival_MarkerRefs[5], RandID);
 	end

	return POS;

end



-- test platoon order function
--------------------------------------------------------------------------
Survival_PlatoonOrder = function(ArmyID, UnitList, OrderID)	

	if (UnitList == nil) then
		return;
	end

	local aiBrain = GetArmyBrain(ArmyID); --"ARMY_SURVIVAL_ENEMY");
	local aiPlatoon = aiBrain:MakePlatoon('','');
	aiBrain:AssignUnitsToPlatoon(aiPlatoon, UnitList, 'Attack', 'None'); -- platoon, unit list, "mission" and formation

 	-- 1 center / 2 waypoint / 3 spawn
 
 	if (OrderID == 4) then -- attack move / move

		-- attack move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:AggressiveMoveToLocation(POS);

		-- move to random center
		POS = Survival_GetPOS(1, 25);
		aiPlatoon:MoveToLocation(POS, false);

 	elseif (OrderID == 3) then -- patrol paths

		-- move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:MoveToLocation(POS, false);

		-- patrol to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:Patrol(POS);

	elseif (OrderID == 2) then -- attack move

		-- attack move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:AggressiveMoveToLocation(POS);

		-- attack move to random center
		POS = Survival_GetPOS(1, 25);
		aiPlatoon:AggressiveMoveToLocation(POS);

	else -- default/order 1 is move

		-- move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:MoveToLocation(POS, false);

		-- move to random center
		POS = Survival_GetPOS(1, 25);
		aiPlatoon:MoveToLocation(POS, false);
	end

end



-- calculates how many units to spawn per wave
--------------------------------------------------------------------------
function Survival_CalcWaveCounts()

	local WaveMultiplier = ScenarioInfo.Options.opt_Survival_WaveFrequency / 60;
	Survival_UnitCountPerMinute = ScenarioInfo.Options.opt_Survival_EnemiesPerMinute * Survival_PlayerCount;
	Survival_UnitCountPerWave = Survival_UnitCountPerMinute * WaveMultiplier;
	LOG("----- Survival MOD: CalcWaveCounts = ((" .. ScenarioInfo.Options.opt_Survival_EnemiesPerMinute .. " EPM * " .. Survival_PlayerCount .. " Players = " .. Survival_UnitCountPerMinute .. ")) * ((" .. ScenarioInfo.Options.opt_Survival_WaveFrequency .. " Second Waves / 60 = " .. WaveMultiplier .. ")) = " .. Survival_UnitCountPerWave .. " Units Per Wave     (( with Waves Per Minute of " .. (60 / ScenarioInfo.Options.opt_Survival_WaveFrequency) .. " = " .. (Survival_UnitCountPerWave * (60 / ScenarioInfo.Options.opt_Survival_WaveFrequency)) .. " of " .. Survival_UnitCountPerMinute .. " Units Per Minute.");

end


-- broadcast a text message to players
-- modified version of original survival script function
BroadcastMSG = function(MSG, Fade, TextColor)
	PrintText(MSG, 20, TextColor, Fade, 'center') ;	
end

-- gets map marker reference by name
-- taken from forum post by Saya
function GetMarker(MarkerName)
	return Scenario.MasterChain._MASTERCHAIN_.Markers[MarkerName]
end

-- returns a random spawn position
Survival_RandomizePOS = function(POS, x)

	local NewPOS = {0, 0, 0};

	NewPOS[1] = POS[1] + ((math.random() * (x * 2)) - x);
	NewPOS[3] = POS[3] + ((math.random() * (x * 2)) - x);

	return NewPOS;

end