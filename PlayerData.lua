-- =======================
-- 放在ServerStorage
-- =======================
local PlayerData = {}
local offlineHeartQueue = {}
-- 結構: offlineHeartQueue["userId_plotIndex"] = { ownerId, plotIndex, totalHeart }

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- 補上這行，抓取萬用廣播
local onDataChangedEvent = ReplicatedStorage:WaitForChild("OnUniversalDataChanged")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local GlobalDataStore = DataStoreService:GetDataStore("PlayerData_Nested_v3")
local dataEvent = ReplicatedStorage:WaitForChild("Universal_Data_Event")

local NotifyPlayer = ReplicatedStorage:WaitForChild("Event"):WaitForChild("E_Notify")
-- ==========================================
-- 🏆 【排行榜底層 - OrderedDataStore】
-- ==========================================
local WealthRankStore = DataStoreService:GetOrderedDataStore("Global_Wealth_Rank") -- 總資產榜 (Coins)
local PotRankStore = DataStoreService:GetOrderedDataStore("Global_Pot_Rank")       -- 肥羊榜 (MoneyInPot)

-- 🚀 獲取音效（嚴禁無聲失敗）
local levelUpSound = SoundService:WaitForChild("LevelUp1")

-- ==========================================
-- 📢 【大聲公系統】(Event / Signal)
-- ==========================================
local OnPotDataChanged = Instance.new("BindableEvent")
-- 把大聲公的「廣播頻道」掛在 PlayerData 模組上，讓 Shipping_Sys 可以訂閱
PlayerData.OnPotDataChanged = OnPotDataChanged.Event

-- ==========================================
-- 📋 【大聲公握手協定】等待登記簿
-- ==========================================
-- 當資料還在 DataStore 載入時，先將回呼函數 (Callback) 記在這裡
local pendingDataRequests = {}

local internalPlayerDataStore = {}
local sessionSaving = {}

-- ==========================================
-- ⚙️ [全域常數設定] 只要改這裡，底下全部自動連動！
-- ==========================================
local DEFAULT_MAX_POT = 3000        -- 錢筒預設上限
local DEFAULT_MAX_COMPOUND = 3      -- 預設最大複利次數
local DEFAULT_COIN = 500            -- 新玩家錢
-- ⚙️ 【核心控制區：離線單利設定】
local OFFLINE_A_SECONDS = 30      -- 每 30 秒跳一次錢 (變數 a)
local OFFLINE_B_RATE = 0.0005        -- 每次跳錢的單利率 0.5% (變數 b)

local AREA_CONFIG = {
	["Backpack"] = {Prefix = "BackpackSlot", Max = 320},
	["Shipping"] = {Prefix = "ShippingSlot", Max = 25},
	["Storage1"] = {Prefix = "Storage1Slot", Max = 25},
	["Storage2"] = {Prefix = "Storage2Slot", Max = 25},
	["Storage3"] = {Prefix = "Storage3Slot", Max = 25},
	["Storage4"] = {Prefix = "Storage4Slot", Max = 25},
	["Storage5"] = {Prefix = "Storage5Slot", Max = 25},
	["Plots"]    = {Prefix = "PlotSlot",      Max = 320},
}

-- ==========================================
-- 🚀 【核心新增：全量代碼手動更新排行榜接口】
-- ==========================================
function PlayerData.updateRanks(player)--寫入 DataStore
	local userId = player.UserId
	local userIdStr = tostring(userId)
	local data = internalPlayerDataStore[userIdStr]
	if not data then 
		warn("⚠️ [RankUpdate] 失敗，記憶體中找不到玩家 " .. player.Name .. " 的資料")
		return 
	end

	task.spawn(function()
		local coins = math.floor(data.Coins or 0)
		local pot = math.floor(data.MoneyInPot or 0)

		-- 1. 更新總資產榜
		local s1, e1 = pcall(function()
			WealthRankStore:SetAsync(userId, coins)
		end)

		-- 2. 更新肥羊榜
		local s2, e2 = pcall(function()
			if pot > 0 then
				PotRankStore:SetAsync(userId, pot)
			else
				PotRankStore:RemoveAsync(userId)
			end
		end)

		if s1 and s2 then
			--print(string.format("🏆 [RankUpdate] 玩家: %s 已成功同步榜單 (Coins:%d / Pot:%d)", player.Name, coins, pot))
		else
			warn("❌ [RankUpdate] 排行榜寫入發生錯誤: ", e1, e2)
		end
	end)
end

-- ============================================================================
-- 🚪 【大聲公握手協定】外部主動敲門
-- ============================================================================
function PlayerData.requestDataAsync(player, callback)
	if not player then 
		warn("⚠️ [PlayerData] 呼叫 requestDataAsync 失敗：傳入的 player 為 nil")
		return 
	end

	local userId = tostring(player.UserId)
	local data = internalPlayerDataStore[userId]

	if data then
		-- 【情況 A】資料已經在記憶體了，直接把熱騰騰的資料丟給 callback！
		--print("📢 [PlayerData] 模組來敲門 " .. player.Name .. " 的資料，記憶體已有，直接回傳！")
		callback(data)
	else
		-- 【情況 B】資料還在 DataStore 飄，先把這個 callback 登記在簿子裡
		if not pendingDataRequests[userId] then
			pendingDataRequests[userId] = {}
		end
		table.insert(pendingDataRequests[userId], callback)
		--print("⏳ [PlayerData] " .. player.Name .. " 資料尚未載入完成，已將外部請求登記在冊。")
	end
end

-- ==========================================
-- 🚀 獲取朋友的農場快照
-- ==========================================
function PlayerData.getFriendSnapshot(friendId)
	local userId = tostring(friendId)

	local success, savedData = pcall(function() return GlobalDataStore:GetAsync(userId) end)

	if success and savedData and savedData.Plots then
		return savedData
	end

	return nil
end

local function verifyData(player)
	local userId = tostring(player.UserId)
	if not internalPlayerDataStore[userId] then
		warn("❌❌❌ [CRITICAL] 玩家 " .. player.Name .. " 資料遺失！")
		return nil
	end
	return internalPlayerDataStore[userId]
end

-- 保留 verifyData 的公開暴露，以防外部有調用
PlayerData.verifyData = verifyData

-- 🚫 【強硬派割除】移除了原先將大量變數同步至 Attribute 的 syncToAttributes 函數！
-- 僅保留極少數，如「格數計算」與「繪製地塊」等引擎/前端直接依賴的屬性。
local function syncToAttributes(player, data)
	-- 只保留地塊加載旗標，供 Plot_Sys 認領
	player:SetAttribute("PlotsLoaded", true)

	-- 為了維持背包動態上限判定，我們保留 MaxBackpackSlots Attribute 的動態計算
	if data.UpgradeLevels and data.UpgradeLevels["BackpackSlots"] then
		local UpgradeConfig = require(ReplicatedStorage:WaitForChild("UpgradeConfig"))
		local bpLevel = data.UpgradeLevels["BackpackSlots"]
		local bpConfig = UpgradeConfig["BackpackSlots"]

		if bpConfig and bpConfig.Levels[bpLevel] then
			player:SetAttribute("MaxBackpackSlots", bpConfig.Levels[bpLevel].Value)
		else
			player:SetAttribute("MaxBackpackSlots", 5)
		end
	else
		player:SetAttribute("MaxBackpackSlots", 5)
	end
end

local function createEmptyData()	
	local newData = {
		["Coins"] = DEFAULT_COIN,
		["SelectedSlot"] = 1, -- 🚀 預設選中第 1 格
		["MoneyInPot"] = 100,
		["LastPotSaveTime"] = 0,
		["CompoundCount"] = 0,
		["MaxPot"] = DEFAULT_MAX_POT,
		["MaxCompound"] = DEFAULT_MAX_COMPOUND,
		["Layout"] = {}, 
		["Warehouse"] = {},

		-- 🚀 保險理賠金額度
		["InsurancePayout"] = 0,

		-- 🚀 偷錢機制數據
		["DailyStealCount"] = 0,
		["DailyStolenCount"] = 0,
		["DailyStealList"] = {},
		
		-- 🚀 【新增】農耕技術系統數據
		["ShipmentCounts"] = {},   -- 格式：{ ["Carrot"] = 0, ["Turnip"] = 0 }
		["TotalFarmingExp"] = 0,   -- 初始農耕經驗值
		["FarmingLevel"] = 1,      -- 初始農耕技術等級
		
		-- 🚀 紀錄玩家各項屬性的「當前等級」
		["UpgradeLevels"] = {
			["FarmPlots"] = 1,
			["WalkSpeed"] = 1,
			["JumpPower"] = 1,
			["MaxPot"] = 1,
			["CompoundLimit"] = 1,
			["StealRate"] = 1,
			["StorageBox"] = 1,
			["BackpackSlots"] = 1,
		}
	}
	for area, config in pairs(AREA_CONFIG) do
		newData[area] = {}
		for i = 1, config.Max do
			-- 🚀 新增 WaterLevel = 0
		newData[area][i] = { Name = "", Count = 0, Time = 0, Stage = 0, WaterLevel = 0, HeartCount = 0, HeartedList = "," }
		end
	end
	return newData
end

-- 🚀 [工具函數] 強制存檔 (通常用於升級或重要變動)
local function forceSave(player)
	local userId = tostring(player.UserId)
	if not internalPlayerDataStore[userId] then return end

	local success, err = pcall(function()
		GlobalDataStore:SetAsync(userId, internalPlayerDataStore[userId])
	end)
	if success then
		-- 只有存檔成功才刷榜
		--PlayerData.updateRanks(player)
	end
end

-- 🚀 玩家下線 或 Server關閉 時用
local function savePlayerData(player)
	local userId = tostring(player.UserId)
	-- 🚀 強化版攔截警告
	if not internalPlayerDataStore[userId] then
		warn("❌ [PlayerData] 存檔失敗！記憶體找不到玩家資料：" .. player.Name)
		return 
	end
	if sessionSaving[userId] then
		warn("🚫 [PlayerData] 存檔被攔截！" .. player.Name .. " 的存檔鎖 (sessionSaving) 尚未解開")
		return 
	end
	sessionSaving[userId] = true
	local success, err = pcall(function()
		-- 這裡執行 MEM -> DATA 的搬運 [cite: 7]
		GlobalDataStore:SetAsync(userId, internalPlayerDataStore[userId])
	end)
	if success then 
		print("✅ [PlayerData] 存檔成功，開始同步排行榜數據...")
		-- 🚀 【核心恢復】：趁 MEM 還在，立刻更新排行榜 DATA
		-- 這樣能確保排行榜上的數字跟剛存好的 DATA 是一致的 [cite: 4]
		PlayerData.updateRanks(player) 
	else
		warn("❌ [PlayerData] 存檔失敗！原因: ", err)
	end
	sessionSaving[userId] = nil
end

-- 🚀 角色生成時，將 DataStore 的等級轉換為實質物理能力的函數
local function applyPhysicalUpgrades(player, character)
	local data = verifyData(player)
	if not data then
		warn("⚠️ [PlayerData] 套用實體能力失敗，找不到玩家資料: " .. player.Name)
		return
	end

	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		warn("❌ [PlayerData] 套用實體能力失敗，找不到玩家的 Humanoid: " .. player.Name)
		return
	end

	local UpgradeConfig = require(ReplicatedStorage:WaitForChild("UpgradeConfig"))

	-- 確保 Humanoid 的物理屬性可以由伺服器腳本完全控制
	humanoid.UseJumpPower = true

	-- 1. 處理 WalkSpeed
	local wsLevel = data.UpgradeLevels and data.UpgradeLevels["WalkSpeed"] or 1
	local wsConfig = UpgradeConfig["WalkSpeed"]
	if wsConfig then
		local wsLevelData = wsConfig.Levels[wsLevel]
		if wsLevelData then
			humanoid.WalkSpeed = wsLevelData.Value
			--print(string.format("👟 [PlayerData] 已套用 %s 的走路速度為: %d (Lv.%d)", player.Name, wsLevelData.Value, wsLevel))
		else
			warn("❌ [PlayerData] 找不到 WalkSpeed 的 Lv." .. tostring(wsLevel) .. " 設定！")
		end
	end

	-- 2. 處理 JumpPower
	local jpLevel = data.UpgradeLevels and data.UpgradeLevels["JumpPower"] or 1
	local jpConfig = UpgradeConfig["JumpPower"]
	if jpConfig then
		local jpLevelData = jpConfig.Levels[jpLevel]
		if jpLevelData then
			humanoid.JumpPower = jpLevelData.Value
			--print(string.format("🦘 [PlayerData] 已套用 %s 的跳躍高度為: %d (Lv.%d)", player.Name, jpLevelData.Value, jpLevel))
		else
			warn("❌ [PlayerData] 找不到 JumpPower 的 Lv." .. tostring(jpLevel) .. " 設定！")
		end
	end
end

-- ==========================================
-- 📥 【讀取與離線利息結算】
-- ==========================================
local function loadPlayerData(player)
	local userId = tostring(player.UserId)
	local success, savedData = pcall(function() return GlobalDataStore:GetAsync(userId) end)

	if success and savedData then
		-- 🚀 【新增】農耕系統欄位補齊
		if savedData.ShipmentCounts == nil then 
			savedData.ShipmentCounts = {} 
		end
		if savedData.TotalFarmingExp == nil then 
			savedData.TotalFarmingExp = 0 
		end
		if savedData.FarmingLevel == nil then 
			savedData.FarmingLevel = 1 
		end
		-- 🚀 [PlayerData.lua] 修正後的補齊邏輯
		-- 1. 處理 Layout (地圖上的東西)
		if not savedData.Layout or #savedData.Layout == 0 then
			savedData.Layout = {} -- 確保它是 Table，不讓 Plot_Sys 報錯 
		end

		-- 2. 處理 Warehouse (口袋裡的東西)
		if not savedData.Warehouse or #savedData.Warehouse == 0 then
			savedData.Warehouse = {
				{["Name"] = "StoneLatern", ["Count"] = 10} -- 補給舊帳號的裝修禮包
			}
			print("📦 [PlayerData] 已為玩家 " .. player.Name .. " 初始化 Warehouse")
		end
		
		
		
		
		-- 🚀 [修正後的補齊邏輯]
		for area, config in pairs(AREA_CONFIG) do
			if not savedData[area] then
				savedData[area] = {}
			end

			-- 在 loadPlayerData 補齊格子的迴圈裡
			for i = 1, config.Max do
				if not savedData[area][i] then
					savedData[area][i] = { Name = "", Count = 0, Time = 0, Stage = 0, WaterLevel = 0 }
				else
					-- 🚀 關鍵：如果格子已經存在，但沒有 WaterLevel，也要補給它
					if savedData[area][i].WaterLevel == nil then
						savedData[area][i].WaterLevel = 0
					end
					if savedData[area][i].HeartedList == nil then
						savedData[area][i].HeartedList = ","
					end
				end
			end
		end

		if savedData.CompoundCount == nil then savedData.CompoundCount = 0 end
		if savedData.MaxPot == nil then savedData.MaxPot = DEFAULT_MAX_POT end
		if savedData.MaxCompound == nil then savedData.MaxCompound = DEFAULT_MAX_COMPOUND end
		if savedData.DailyStealCount == nil then savedData.DailyStealCount = 0 end
		if savedData.DailyStolenCount == nil then savedData.DailyStolenCount = 0 end
		if savedData.DailyStealList == nil then savedData.DailyStealList = {} end
		if savedData.InsurancePayout == nil then savedData.InsurancePayout = 0 end
		-- layout
		if not savedData.Layout or #savedData.Layout == 0 then
			savedData.Layout = {} -- 確保它是 Table
			-- savedData.Layout = { {"StoneLatern", 5, 0, 5, 1} } -- 你目前的測試開關
		end
		if savedData.Warehouse == nil then
			-- 🚀 這是給舊帳號的「開工禮包」，確保他們一進去就有東西可以裝修
			savedData.Warehouse = {
				{["Name"] = "StoneLatern", ["Count"] = 10} 
			}
			print("📦 [PlayerData] 已為舊玩家補齊 Warehouse 測試資料")
		end
		
		if not savedData.UpgradeLevels then
			savedData.UpgradeLevels = {
				["FarmPlots"] = 1, ["WalkSpeed"] = 1, ["JumpPower"] = 1, ["MaxPot"] = 1,
				["CompoundLimit"] = 1, ["StealRate"] = 1, ["StorageBox"] = 1, ["BackpackSlots"] = 1,
			}
		else
			local list = {"FarmPlots", "WalkSpeed", "JumpPower", "MaxPot", "CompoundLimit", "StealRate", "StorageBox", "BackpackSlots"}
			for _, k in ipairs(list) do
				if not savedData.UpgradeLevels[k] then savedData.UpgradeLevels[k] = 1 end
			end
		end

		-- 🚀 【2026 核心修正：離線利息處理 - 支援溢出轉入錢包】
		if savedData.MoneyInPot and savedData.MoneyInPot > 0 and savedData.LastPotSaveTime and savedData.LastPotSaveTime > 0 then
			local timePassed = os.time() - savedData.LastPotSaveTime

			-- 💡 判斷是否超過跳錢週期 (a)
			if timePassed >= OFFLINE_A_SECONDS then
				-- 1. 算出總共「跳了幾次」利息
				local compoundTimes = math.floor(timePassed / OFFLINE_A_SECONDS)

				-- 2. 計算單利：本金 × 利率(b) × 次數
				local interestEarned = math.floor(savedData.MoneyInPot * OFFLINE_B_RATE * compoundTimes)

				local oldAmount = savedData.MoneyInPot
				local maxLimit = savedData.MaxPot or 3000
				local newTotal = oldAmount + interestEarned
				local overflowMoney = 0

				-- 3. 處理溢出邏輯：補上利息並判斷是否進錢包
				if newTotal > maxLimit then
					overflowMoney = newTotal - maxLimit
					savedData.MoneyInPot = maxLimit
					-- 將溢出部分直接加進玩家錢包
					savedData.Coins = (savedData.Coins or 0) + overflowMoney
				else
					savedData.MoneyInPot = newTotal
				end

				-- 4. 更新時間戳
				savedData.LastPotSaveTime = os.time() 
				-- 🚀 【新功能：Notify 提示玩家】
				-- 使用 task.delay 避開玩家 Loading 時間，確保前端 NotifyHandler 已啟動
				task.delay(3, function()
					if player and player.Parent then
						local notifyMsg = ""
						if overflowMoney > 0 then
							notifyMsg = string.format("🌙 歡迎回來！離線利息 $%d 已結算。錢箱已滿，溢出的 $%d 已存入錢包！", interestEarned, overflowMoney)
						else
							notifyMsg = string.format("🌙 歡迎回來！離線利息 $%d 已存入錢箱！", interestEarned)
						end

						-- 觸發你的 Notify 遠端事件
						-- 參數：(玩家, 訊息內容, 顏色, 音效名稱)
						NotifyPlayer:FireClient(player, notifyMsg, Color3.fromRGB(255, 215, 0), "OrderSuccess1")
					end
				end)
				-- 🚀 【協議要求：單利 Debug Print】嚴禁無聲失敗！
				print(string.format("🌙 [離線結算 Debug] 玩家 %s 離線了 %d 秒，產生利息 $%d。錢箱補至 $%d，溢出 $%d 已匯入錢包！", 
					player.Name, timePassed, interestEarned, savedData.MoneyInPot, overflowMoney))
			end
		end

		internalPlayerDataStore[userId] = savedData
	else
		-- [ 空資料初始化 ]
		local emptyData = createEmptyData()
		internalPlayerDataStore[userId] = emptyData
		savedData = emptyData
	end

	-- [ 大聲公協定與屬性同步 ]
	local userIdStr = tostring(player.UserId)
	if pendingDataRequests[userIdStr] then
		for _, callback in ipairs(pendingDataRequests[userIdStr]) do
			task.spawn(callback, savedData)
		end
		pendingDataRequests[userIdStr] = nil 
	end

	syncToAttributes(player, internalPlayerDataStore[userId])
	
	print("🔍 [DEBUG] 玩家 " .. player.Name .. " 的 Warehouse:", game:GetService("HttpService"):JSONEncode(internalPlayerDataStore[userId].Warehouse))
end

-- ==========================================
-- 🛠️ 【萬用 Key 讀寫配套】
-- ==========================================

-- 1. 萬用讀取器
function PlayerData.get(player, key)
	local data = verifyData(player)
	if not data then 
		warn("❌ [PlayerData.get] 失敗，找不到玩家資料: " .. player.Name)
		return nil 
	end

	if data[key] == nil then
		warn("⚠️ [PlayerData.get] 嘗試讀取一個不存在於資料庫的 Key: " .. tostring(key))
		return nil
	end

	return data[key]
end

-- 2. 萬用寫入器
function PlayerData.set(player, key, value)
	local data = verifyData(player)
	if not data then 
		warn("❌ [PlayerData.set] 失敗，找不到玩家資料: " .. player.Name)
		return false 
	end

	data[key] = value

	-- 📢 【連動處理】錢箱
	if key == "MoneyInPot" then
		local cpCount = data.CompoundCount or 0
		local mPot = data.MaxPot or DEFAULT_MAX_POT
		local mCompound = data.MaxCompound or DEFAULT_MAX_COMPOUND

		OnPotDataChanged:Fire(player.UserId, value, cpCount, mPot, mCompound)

		if value > 0 then
			data.LastPotSaveTime = os.time()
		else
			data.LastPotSaveTime = 0
			data.CompoundCount = 0 
		end
	end

	-- 📢 【廣播通知】
	if key == "Backpack" then
		onDataChangedEvent:FireClient(player)
	end

	-- 💾 【存檔防護】
	if key == "InsurancePayout" then
		task.spawn(function() forceSave(player) end)
	end

	return true
end

-- ==========================================
-- 🚀 [外掛監聽]
-- ==========================================
game.Players.PlayerAdded:Connect(function(player)
	loadPlayerData(player)

	print("🏃 [PlayerAdded] 玩家 " .. player.Name )
	-- 🚀 【新增】：資料載入後，立即執行初次農耕數據同步（不加經驗，純廣播）
	-- 這樣你一進遊戲點開 FarmBook 就不會是 0 了
	PlayerData.updateFarmingExp(player, nil, 0, nil)

	if player.Character then
		applyPhysicalUpgrades(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		applyPhysicalUpgrades(player, character)
	end)
end)
-- ==========================================
-- 🚪 【離線與關服的協調邏輯】
-- ==========================================

function PlayerData.queueOfflineHeart(ownerId, plotIndex, senderId, heartPower)
	-- 1. Key 只用玩家 ID，這樣同一個人的所有作物都會進同一個桶子
	local key = tostring(ownerId)

	if not offlineHeartQueue[key] then
		-- 結構改為：一個 ownerId 對應多個 plots
		offlineHeartQueue[key] = { 
			ownerId = ownerId, 
			plotsData = {} -- 用來存多個地號的愛心
		}
	end

	-- 2. 處理特定地號的資料
	if not offlineHeartQueue[key].plotsData[plotIndex] then
		offlineHeartQueue[key].plotsData[plotIndex] = { totalHeart = 0, senderList = "," }
	end

	local targetPlot = offlineHeartQueue[key].plotsData[plotIndex]
	local senderStr = tostring(senderId) .. ","

	-- 3. 檢查重複（維持你原本的邏輯）
	if string.find(targetPlot.senderList, "," .. senderStr) then
		return false
	end

	targetPlot.totalHeart += heartPower
	targetPlot.senderList = targetPlot.senderList .. senderStr
	return true
end
-- 1. 玩家離開：這是最常見的存檔點
game.Players.PlayerRemoving:Connect(function(player)
	print("🏃 [PlayerRemoving] 玩家 " .. player.Name .. " 準備離開，啟動存檔...")

	-- 執行存檔
	savePlayerData(player)

	internalPlayerDataStore[tostring(player.UserId)] = nil
end)
-- 2. 整台伺服器關閉：這是最後的防線
game:BindToClose(function()
	print("🛑 [BindToClose] 伺服器即將關閉，進行最後清場...")

	local players = game.Players:GetPlayers()

	for _, p in ipairs(players) do
		local userId = tostring(p.UserId)

		-- 🚀 重點：檢查有沒有「鎖」。
		-- 如果 sessionSaving[userId] 是 nil，代表剛才的 PlayerRemoving 沒跑或跑完了
		-- 我們才幫他呼叫最後一次。
		if not sessionSaving[userId] then
			task.spawn(function()
				print("⏳ [BindToClose伺服器關閉]savePlayerData")
				savePlayerData(p)
			end)
		else
			print("⏳ [BindToClose伺服器關閉] 玩家 " .. p.Name .. " 已經在存檔中，跳過重複請求。")
		end
	end
	-- 🚀 離線愛心寫入 (修改版)
	for ownerIdKey, data in pairs(offlineHeartQueue) do
		print("💖[BindToClose]離線愛心UpdateAsync"..ownerIdKey)
		pcall(function()
			GlobalDataStore:UpdateAsync(tostring(data.ownerId), function(oldData)
				if not oldData or not oldData.Plots then return nil end

				-- 在這一次 UpdateAsync 裡面，跑遍這個玩家所有有變動的作物
				for plotIndex, heartData in pairs(data.plotsData) do
					local plot = oldData.Plots[plotIndex]

					if plot and plot.Name ~= "" then
						-- 疊加愛心
						plot.HeartCount = (plot.HeartCount or 0) + heartData.totalHeart

						-- 合併送禮名單
						local currentList = plot.HeartedList or ","
						plot.HeartedList = currentList .. heartData.senderList:sub(2)
					end
				end

				return oldData -- 這邊回傳一次，就同時存好了 10 個作物的資料
			end)
		end)
	end
	-- 🚀 這裡至少等 2 秒，因為 SetAsync 是非同步的，不等會直接斷氣
	task.wait(2) 
end)
-- 🚀 [新增接口]：專門處理加錢，並觸發 UI 廣播
function PlayerData.addMoney(player, amount)
	local data = verifyData(player)
	if not data then return false end

	-- 1. 執行加錢邏輯
	local oldCoins = data.Coins or 0
	data.Coins = oldCoins + amount

	-- 2. 🚀 重要：使用 OnUniversalDataChanged 廣播，這樣 HotbarUI 才會更新錢數
	if onDataChangedEvent then
		onDataChangedEvent:FireClient(player)
	end

	-- 3. 備援：觸發舊有的 Universal_Data_Event
	if dataEvent then
		dataEvent:FireClient(player)
	end

	--print(string.format("💰 [PlayerData] 玩家 %s 獲得金幣: %d, 當前總額: %d", player.Name, amount, data.Coins))
	return true
end

function PlayerData.adjustCurrency(player, amount)
	local data = verifyData(player)
	if not data then return false end
	data.Coins = math.max(0, (data.Coins or 0) + amount)
	dataEvent:FireClient(player)
	return true
end

function PlayerData.addItem(player, itemName, amount)
	local data = verifyData(player)
	if not data then return false end

	local maxSlots = player:GetAttribute("MaxBackpackSlots") or 5

	for i = 1, maxSlots do
		if data.Backpack[i] and data.Backpack[i].Name == itemName then
			data.Backpack[i].Count += amount
			onDataChangedEvent:FireClient(player)
			return true
		end
	end

	for i = 1, maxSlots do
		if data.Backpack[i] and data.Backpack[i].Name == "" then
			data.Backpack[i].Name = itemName
			data.Backpack[i].Count = amount
			onDataChangedEvent:FireClient(player)
			return true
		end
	end

	return false
end

function PlayerData.moveBetweenAreas(player, fromArea, fromIdx, toArea, toIdx)
	local data = verifyData(player)
	if not data or not data[fromArea] or not data[toArea] then return end
	local source = data[fromArea][fromIdx]
	local target = data[toArea][toIdx]
	data[fromArea][fromIdx], data[toArea][toIdx] = target, source

	if data[fromArea][fromIdx].Count <= 0 then data[fromArea][fromIdx].Name = "" end
	if data[toArea][toIdx].Count <= 0 then data[toArea][toIdx].Name = "" end

	if fromArea == "Backpack" or toArea == "Backpack" then
		onDataChangedEvent:FireClient(player)
	end
end

function PlayerData.updatePlot(player, index, seedName, startTime, waterLevel, heartCount, heartedList)
	if not player then return end
	--print("📥 [DEBUG 2] PlayerData 收到資料更新: ", seedName)
	local data = verifyData(player)
	-- 🚀 監視器：看看到底是 data 沒了，還是地塊編號超標了
	if not data then 
		print("❌ [CRITICAL] 找不到玩家記憶體資料！") 
	elseif not data.Plots[index] then
		print("❌ [CRITICAL] 找不到地塊編號: ", index, " (目前 Plots 總數: ", #data.Plots, ")")
	end
	
	if not data or not data.Plots[index] then return end
	data.Plots[index].Name = seedName
	data.Plots[index].Time = startTime
	-- 🚀 關鍵：把水位存進 Table
	data.Plots[index].WaterLevel = waterLevel or 0
	if heartCount ~= nil then
		data.Plots[index].HeartCount = heartCount
	end
	if heartedList ~= nil then
		data.Plots[index].HeartedList = heartedList
	end
	--print("🔍 [Heart Debug] Plots[" .. index .. "] HeartCount =", data.Plots[index].HeartCount, "| HeartedList =", data.Plots[index].HeartedList)
end

function PlayerData.getBackpackTotal(player, itemName)
	local data = verifyData(player)
	if not data then return 0 end
	local total = 0
	for i = 1, 20 do
		if data.Backpack[i] and data.Backpack[i].Name == itemName then
			total = total + data.Backpack[i].Count
		end
	end
	return total
end

function PlayerData.consumeFromBackpack(player, itemName, amountToConsume)
	local data = verifyData(player)
	if not data then return false end
	local remaining = amountToConsume
	for i = 1, 20 do
		if data.Backpack[i] and data.Backpack[i].Name == itemName then
			if data.Backpack[i].Count >= remaining then
				data.Backpack[i].Count = data.Backpack[i].Count - remaining
				remaining = 0
			else
				remaining = remaining - data.Backpack[i].Count
				data.Backpack[i].Count = 0
			end

			if data.Backpack[i].Count <= 0 then data.Backpack[i].Name = "" end
		end
		if remaining <= 0 then break end
	end

	if remaining == 0 then
		onDataChangedEvent:FireClient(player)
	end

	return remaining == 0
end

function PlayerData.clearShippingBox(player)
	local data = verifyData(player)
	if not data or not data.Shipping then return end
	local config = AREA_CONFIG["Shipping"]

	for i = 1, config.Max do
		data.Shipping[i] = { Name = "", Count = 0, Time = 0, Stage = 0 }
	end

	--print("🧹 [PlayerData] 已徹底清空玩家 " .. player.Name .. " 的出貨箱 DataStore 紀錄！")
end

function PlayerData.resetDailyStats(player)
	local data = verifyData(player)
	if not data then return end

	data.DailyStealCount = 0
	data.DailyStolenCount = 0
	data.DailyStealList = {}

	--print("⏰ [PlayerData] 每日數據已重置: " .. player.Name)
end

function PlayerData.adminSetLevel(player, attributeName, targetLevel)
	local data = verifyData(player)
	if not data then return false end

	if not data.UpgradeLevels then data.UpgradeLevels = {} end
	data.UpgradeLevels[attributeName] = targetLevel

	local UpgradeConfig = require(ReplicatedStorage:WaitForChild("UpgradeConfig"))
	local attrConfig = UpgradeConfig[attributeName]

	if attrConfig then
		local levelConfig = attrConfig.Levels[targetLevel]
		if attributeName == "MaxPot" and levelConfig then
			data.MaxPot = levelConfig.Value
		elseif attributeName == "CompoundLimit" and levelConfig then
			data.MaxCompound = levelConfig.Value
		elseif attributeName == "BackpackSlots" and levelConfig then
			player:SetAttribute("MaxBackpackSlots", levelConfig.Value)
		end
	end

	local character = player.Character
	if character and (attributeName == "WalkSpeed" or attributeName == "JumpPower") then
		applyPhysicalUpgrades(player, character)
	end

	task.spawn(function() forceSave(player) end)

	return true
end

function PlayerData.saveAfterShipping(player)
	local userId = tostring(player.UserId)
	if not internalPlayerDataStore[userId] then return end

	task.spawn(function()
		local success, err = pcall(function()
			-- 這裡把出貨後的錢存進主要資料 DATA 
			GlobalDataStore:SetAsync(userId, internalPlayerDataStore[userId])
		end)

		if success then
			--print("💰 [PlayerData] 18:00 結算完成，正式同步排行榜...")
			-- 🚀 執行同步，確保排行榜反映出貨後的身價
			PlayerData.updateRanks(player) 
		else
			warn("❌ [PlayerData] 結算存檔失敗，取消刷榜: " .. err)
		end
	end)
end

-- ==========================================
-- 🛡️ 【理賠金與離線接口】
-- ==========================================

function PlayerData.getInsurancePayout(player)
	return PlayerData.get(player, "InsurancePayout") or 0
end

function PlayerData.addInsurancePayout(player, amount)
	local current = PlayerData.get(player, "InsurancePayout") or 0
	PlayerData.set(player, "InsurancePayout", current + amount)
end

function PlayerData.clearInsurancePayout(player)
	PlayerData.set(player, "InsurancePayout", 0)
end

function PlayerData.modifyOfflinePot(targetUserId, stolenAmountPercent)
	local userId = tostring(targetUserId)
	local success, err = pcall(function()
		GlobalDataStore:UpdateAsync(userId, function(oldData)
			if oldData and oldData.MoneyInPot > 0 then

				local timePassed = os.time() - (oldData.LastPotSaveTime or os.time())
				local compoundTimes = math.floor(timePassed / OFFLINE_A_SECONDS)	
				local interest = math.floor(oldData.MoneyInPot * OFFLINE_B_RATE * compoundTimes)
				local currentMax = oldData.MaxPot or 3000
				local potBeforeSteal = math.min(currentMax, oldData.MoneyInPot + interest)

				local finalStolen = math.floor(potBeforeSteal * stolenAmountPercent)
				oldData.MoneyInPot = math.max(0, potBeforeSteal - finalStolen)
				oldData.LastPotSaveTime = os.time()

				-- 🚀 修正對接：離線偷竊後的資料同步
				task.spawn(function()
					local finalPot = math.floor(oldData.MoneyInPot)
					if finalPot > 0 then
						PotRankStore:SetAsync(tonumber(userId), finalPot)
					else
						PotRankStore:RemoveAsync(tonumber(userId))
					end
				end)

				return oldData
			end
			return nil
		end)
	end)

	return success
end

function PlayerData.modifyOfflineInsurance(targetUserId, compensationAmount)
	local userId = tostring(targetUserId)

	local success, err = pcall(function()
		GlobalDataStore:UpdateAsync(userId, function(oldData)
			if oldData then
				local currentInsurance = oldData.InsurancePayout or 0
				oldData.InsurancePayout = currentInsurance + compensationAmount
				return oldData
			end
			return nil 
		end)
	end)
	return success
end
function PlayerData.updateFarmingExp(player, cropName, gainedExp, newCount)
	local data = verifyData(player)
	if not data then 
		print("❌ [updateFarmingExp] 根本找不到 PlayerData")
		return 
	end

	--print("🔍 [updateFarmingExp] 進入同步函數 | 玩家:", player.Name, "| 作物:", tostring(cropName))

	if cropName ~= nil then
		data.ShipmentCounts[cropName] = newCount
		data.TotalFarmingExp = (data.TotalFarmingExp or 0) + (gainedExp or 0)
		--print("✅ [updateFarmingExp] 數據已寫入記憶體:", cropName, "數量:", newCount)
	else
		--print("ℹ️ [updateFarmingExp] cropName 為 nil，跳過寫入，執行純同步")
	end

	if onDataChangedEvent then
		-- 檢查噴出去的 Table 到底有沒有貨
		local sample = data.ShipmentCounts["Carrot"] or 0
		--print("📢 [updateFarmingExp] 大聲公準備噴發 | Carrot 數量:", sample, "| 總經驗:", data.TotalFarmingExp)

		onDataChangedEvent:FireClient(player, "FarmingUpdate", {
			["ShipmentCounts"] = data.ShipmentCounts or {},
			["TotalFarmingExp"] = data.TotalFarmingExp or 0,
			["FarmingLevel"] = data.FarmingLevel or 1
		})
	end
end

-- 放在 PlayerData.lua 底部，或任何 Server Script
local onDataChangedEvent = ReplicatedStorage:WaitForChild("OnUniversalDataChanged")

onDataChangedEvent.OnServerEvent:Connect(function(player, category)
	if category == "RequestFarmingSync" then
		print("📡 [Server] 收到 " .. player.Name .. " 的農耕數據同步請求")
		-- 等資料確實載入後再回應
		PlayerData.requestDataAsync(player, function(data)
			onDataChangedEvent:FireClient(player, "FarmingUpdate", {
				["ShipmentCounts"] = data.ShipmentCounts or {},
				["TotalFarmingExp"] = data.TotalFarmingExp or 0,
				["FarmingLevel"]    = data.FarmingLevel or 1
			})
		end)
	end
end)
--------------------  裝修   裝修   裝修   裝修   裝修   裝修   裝修   裝修   裝修 --------------------
---------------------------------------------------------
-- [建築系統專用函式庫] 
---------------------------------------------------------

-- 🚀 1. 倉庫管理：增減口袋裡的家具數量
function PlayerData.updateWarehouse(player, itemName, amount)
	local data = verifyData(player) -- 確保使用你現有的驗證機制
	if not data then return end

	if not data.Warehouse then data.Warehouse = {} end

	local found = false
	for _, item in ipairs(data.Warehouse) do
		if item.Name == itemName then
			-- 數量增減，math.max 確保不會變成負數
			item.Count = math.max(0, item.Count + amount)
			found = true
			break
		end
	end

	-- 如果是新家具（且是增加），則插入新項目
	if not found and amount > 0 then
		table.insert(data.Warehouse, {["Name"] = itemName, ["Count"] = amount})
	end

	-- 📣 觸發你原本的大聲公，通知前端刷新 UI
	ReplicatedStorage.OnUniversalDataChanged:FireClient(player)
	print("📦 [Warehouse] " .. player.Name .. " 的 " .. itemName .. " 變動量: " .. amount)
end

-- 🚀 2. 擺放家具：將家具種到地圖，並自動扣除倉庫存量
function PlayerData.addItemToLayout(player, itemName, gx, gy, gz, rot)
	local data = verifyData(player)
	if not data then return end

	if not data.Layout then data.Layout = {} end

	-- 插入座標資料
	table.insert(data.Layout, {itemName, gx, gy, gz, rot})

	-- 📢 連動：從倉庫扣除 1 個
	PlayerData.updateWarehouse(player, itemName, -1)

	-- 💾 異步存檔：確保蓋下去就存檔，防止跳號
	task.spawn(function()
		local userId = tostring(player.UserId)
		local success, err = pcall(function()
			GlobalDataStore:SetAsync(userId, data)
		end)
		if success then
			print("💾 [PlayerData] " .. player.Name .. " 的佈局已成功寫入 DataStore")
		else
			warn("❌ [PlayerData] 存檔失敗: " .. tostring(err))
		end
	end)
end

-- 🚀 3. 回收家具：從地圖移除，並補回倉庫存量
function PlayerData.removeItemFromLayout(player, index)
	local data = verifyData(player)
	if not data or not data.Layout or not data.Layout[index] then return end

	local itemName = data.Layout[index][1] -- 取得家具名稱 (索引 1)

	-- 從 Layout 陣列中移除
	table.remove(data.Layout, index)

	-- 📢 連動：加回倉庫 1 個
	PlayerData.updateWarehouse(player, itemName, 1)

	print("♻️ [Warehouse] 已回收 " .. itemName .. " 回玩家口袋")
end

-- 🚀 修正：改用 OnServerEvent (因為它是 RemoteEvent)
ReplicatedStorage.Event.GetWarehouseData.OnServerEvent:Connect(function(player)
	local data = verifyData(player)
	local warehouseData = data and data.Warehouse or {}

	-- 直接噴回給前端
	ReplicatedStorage.OnUniversalDataChanged:FireClient(player, "WarehouseUpdate", warehouseData)
end)

--==============================================================================


return PlayerData

-- [[ 檔案名稱: PlayerData.lua ]]
-- [[ 時間: 2026-04-07 19:22 ]]
