--[[	MockDataStoreManager.lua
		This module does bookkeeping of data, interfaces and request limits used by MockDataStoreService and its sub-classes.

		This module is licensed under APLv2, refer to the LICENSE file or:
		https://github.com/buildthomas/MockDataStoreService/blob/master/LICENSE
]]

local MockDataStoreManager = {}

local Utils = require(script.Parent.MockDataStoreUtils)
local Constants = require(script.Parent.MockDataStoreConstants)
local HttpService = game:GetService("HttpService")

local ConstantsMapping = {
	[Enum.DataStoreRequestType.GetAsync] = Constants.BUDGET_GETASYNC;
	[Enum.DataStoreRequestType.GetSortedAsync] = Constants.BUDGET_GETSORTEDASYNC;
	[Enum.DataStoreRequestType.OnUpdate] = Constants.BUDGET_ONUPDATE;
	[Enum.DataStoreRequestType.SetIncrementAsync] = Constants.BUDGET_SETINCRASYNC;
	[Enum.DataStoreRequestType.SetIncrementSortedAsync] = Constants.BUDGET_SETINCRSORTEDASYNC;
}

-- Bookkeeping of all data:
local Data = {
	GlobalDataStore = {};
	DataStore = {};
	OrderedDataStore = {};
}

-- Bookkeeping of all active GlobalDataStore/OrderedDataStore interfaces indexed by data table:
local Interfaces = {}

-- Request limit bookkeeping:
local Budgets = {}

local budgetRequestQueue = {}

local function initBudget()
	for requestType, const in pairs(ConstantsMapping) do
		Budgets[requestType] = const.START
	end
	Budgets[Enum.DataStoreRequestType.UpdateAsync] = math.min(
		Budgets[Enum.DataStoreRequestType.GetAsync],
		Budgets[Enum.DataStoreRequestType.SetIncrementAsync]
	)
end

local function updateBudget(req, const, dt, n)
	local rate = const.RATE + n * const.RATE_PLR
	Budgets[req] = math.min(
		Budgets[req] + dt * rate,
		const.MAX_FACTOR * rate
	)
end

local function stealBudget(budget)
	for _, requestType in pairs(budget) do
		if Budgets[requestType] then
			Budgets[requestType] = math.max(0, Budgets[requestType] - 1)
		end
	end
	Budgets[Enum.DataStoreRequestType.UpdateAsync] = math.min(
		Budgets[Enum.DataStoreRequestType.GetAsync],
		Budgets[Enum.DataStoreRequestType.SetIncrementAsync]
	)
end

local function checkBudget(budget)
	for _, requestType in pairs(budget) do
		if Budgets[requestType] and Budgets[requestType] < 1 then
			return false
		end
	end
	return true
end

if game:GetService("RunService"):IsServer() then
	-- Only do budget updating on server in case required on client

	initBudget()

	delay(0, function() -- Thread that restores budgets periodically
		local lastCheck = tick()
		while wait(Constants.BUDGET_UPDATE_INTERVAL) do
			local now = tick()
			local dt = now - lastCheck
			lastCheck = now
			local n = #game:GetService("Players"):GetPlayers()

			for requestType, const in pairs(ConstantsMapping) do
				updateBudget(requestType, const, dt, n)
			end
			Budgets[Enum.DataStoreRequestType.UpdateAsync] = math.min(
				Budgets[Enum.DataStoreRequestType.GetAsync],
				Budgets[Enum.DataStoreRequestType.SetIncrementAsync]
			)

			for i = #budgetRequestQueue, 1, -1 do
				local thread = budgetRequestQueue[i].Thread
				local budget = budgetRequestQueue[i].Budget
				if checkBudget(budget) then
					table.remove(budgetRequestQueue, i)
					stealBudget(budget)
					--coroutine.resume(thread)
					thread:Fire()
				end
			end
		end
	end)
end

function MockDataStoreManager:GetGlobalData()
	return Data.GlobalDataStore
end

function MockDataStoreManager:GetData(name, scope)
	assert(typeof(name) == "string")
	assert(typeof(scope) == "string")

	if not Data.DataStore[name] then
		Data.DataStore[name] = {}
	end
	if not Data.DataStore[name][scope] then
		Data.DataStore[name][scope] = {}
	end

	return Data.DataStore[name][scope]
end

function MockDataStoreManager:GetOrderedData(name, scope)
	assert(typeof(name) == "string")
	assert(typeof(scope) == "string")

	if not Data.OrderedDataStore[name] then
		Data.OrderedDataStore[name] = {}
	end
	if not Data.OrderedDataStore[name][scope] then
		Data.OrderedDataStore[name][scope] = {}
	end

	return Data.OrderedDataStore[name][scope]
end

function MockDataStoreManager:GetDataInterface(data)
	return Interfaces[data]
end

function MockDataStoreManager:SetDataInterface(data, interface)
	assert(typeof(data) == "table")
	assert(typeof(interface) == "table")

	Interfaces[data] = interface
end

function MockDataStoreManager:StealBudget(...)
	if checkBudget({...}) then
		stealBudget({...})
		return true
	end
end

function MockDataStoreManager:GetBudget(requestType)
	if Budgets[requestType] then
		return math.floor(Budgets[requestType])
	end
	return 0
end

function MockDataStoreManager:TakeBudget(key, ...)
	local budget = {...}
	assert(typeof(key) == "string")
	assert(#budget > 0)

	if checkBudget(budget) then
		if key then
			warn(("Request was queued due to lack of budget. Try sending fewer requests. Key = %s"):format(key))
		else
			warn("Request of GetSortedAsync/AdvanceToNextPageAsync queued due to lack of budget. Try sending fewer requests.")
		end
		--local thread = coroutine.running()
		local thread = Instance.new("BindableEvent")
		table.insert(budgetRequestQueue, 1, {
			Thread = thread;
			Budget = budget;
		})
		--coroutine.yield()
		thread.Event:Wait()
		thread:Destroy()
	else
		stealBudget(budget)
	end
end

function MockDataStoreManager:ExportToJSON()
	local export = {}

	if next(Data.GlobalDataStore) ~= nil then -- GlobalDataStore not empty
		export.GlobalDataStore = Data.GlobalDataStore
	end
	export.DataStore = Utils.prepareDataStoresForExport(Data.DataStore) -- can be nil
	export.OrderedDataStore = Utils.prepareDataStoresForExport(Data.OrderedDataStore) -- can be nil

	return HttpService:JSONEncode(export)
end

function MockDataStoreManager:ImportFromJSON(json, verbose)
	local content
	if typeof(json) == "string" then
		local parsed, value = pcall(function() return HttpService:JSONDecode(json) end)
		if not parsed then
			error("bad argument #1 to 'ImportFromJSON' (string is not valid json)", 2)
		end
		content = value
	elseif typeof(json) == "table" then
		content = Utils.deepcopy(json)
	else
		error(("bad argument #1 to 'ImportFromJSON' (string or table expected, got %s)"):format(typeof(json)), 2)
	end

	local warnFunc = warn -- assume verbose as default
	if verbose == false then -- intentional formatting
		warnFunc = function() end
	end

	if typeof(content.GlobalDataStore) == "table" then
		Utils.importPairsFromTable(
			content.GlobalDataStore,
			Data.GlobalDataStore,
			warnFunc,
			"ImportFromJSON",
			"GlobalDataStore",
			false
		)
	end
	if typeof(content.DataStore) == "table" then
		Utils.importDataStoresFromTable(
			content.DataStore,
			Data.DataStore,
			warnFunc,
			"ImportFromJSON",
			"DataStore",
			false
		)
	end
	if typeof(content.OrderedDataStore) == "table" then
		Utils.importDataStoresFromTable(
			content.OrderedDataStore,
			Data.OrderedDataStore,
			warnFunc,
			"ImportFromJSON",
			"OrderedDataStore",
			true
		)
	end
end

return MockDataStoreManager