--[[
	DataStoreService.lua
	This module decides whether to use actual datastores or mock datastores depending on the environment.

	This module is licensed under APLv2, refer to the LICENSE file or:
	https://github.com/buildthomas/MockDataStoreService/blob/master/LICENSE
]]

local MockDataStoreServiceModule = script.MockDataStoreService

-- Return the mock or actual service depending on environment:
if game.PlaceId == 0 then
	warn("INFO: Using MockDataStoreService instead of DataStoreService")
	return require(MockDataStoreServiceModule)
else
	return game:GetService("DataStoreService")
end
