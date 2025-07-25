local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local services = require("@shared/network/services")
local RequestMethods = require("@shared/network/requestMethods")
local ServerRequestMethod = RequestMethods.Server
local ClientRequestMethod = RequestMethods.Client

local Log = require("@shared/log")
local Functions = require("@shared/functions")
local HashLib = require("@shared/hashLib")
local Protection = require("@shared/protection")

local Network = {}
Network.attributeName, Network.attributeValue = string.sub(tostring(math.random()), 3), math.random()

local registeredEvents: { [string]: (...unknown) -> nil } = {}
function Network:RegisterEvent(name: string, callback: (...unknown) -> nil)
	if registeredEvents[name] then
		Log.warn(`Network event "{name}" was overwritten.`)
	end

	registeredEvents[name] = callback
end

local registeredFunctions: { [string]: (...unknown) -> ...unknown } = {}
function Network:RegisterFunction(name: string, callback: (...unknown) -> ...unknown)
	if registeredFunctions[name] then
		Log.warn(`Network function "{name}" was overwritten.`)
	end

	registeredFunctions[name] = callback
end

local keys: { [Player]: string } = {}
local usedHashes: { [Player]: { [string]: boolean } } = {} -- Prevent replay attacks

local function isValidRequestKey(player: Player, requestKey): boolean
	if type(requestKey) ~= "table" then
		return false
	end

	local hash, salt = requestKey[1], requestKey[2]
	if type(hash) ~= "string" or type(salt) ~= "string" then
		return false
	end

	local playerUsedHashes = usedHashes[player]
	if not playerUsedHashes then
		playerUsedHashes = {}
		usedHashes[player] = playerUsedHashes
	end

	if playerUsedHashes[hash] then
		return false
	end

	if hash == HashLib.hmac(HashLib.sha256, keys[player], salt) then
		playerUsedHashes[hash] = true

		return true
	end

	return false
end

local function generateRequestKey(player: Player): { string }
	local playerUsedHashes = usedHashes[player]
	if not playerUsedHashes then
		playerUsedHashes = {}
		usedHashes[player] = playerUsedHashes
	end

	local salt = Functions.randomString(64)
	local hash = HashLib.hmac(HashLib.sha256, keys[player], salt)

	if playerUsedHashes[hash] then -- It's very unlikely this would ever happen, but ¯\_(ツ)_/¯
		return generateRequestKey(player)
	end

	playerUsedHashes[hash] = true
	return { hash, salt }
end

local connectedPlayers: { [Player]: boolean } = {} -- We keep track of players that have successfully connected to the remote, so we don't accidentally send stuff to them without them actually listening to the remote
local lockedKeys: { [Player]: boolean } = {} -- We lock keys after the first handshake

local remote: RemoteFunction, remoteParent: Instance

local function onRequest(player: Player, requestType, requestKey, ...)
	-- Key exchange and handshake requests should be the only times we return something from remote functions, the only reason we are using them is to prevent logging
	-- When returning something from remote functions we are risking it never getting sent back to the client if the remote function were to get destroyed while the callback is executing
	-- In that case we just allow the client to resend the request (it's also why we are not locking the key here)

	-- We allow them for the handshake because if the remote gets destroyed the client would have to make another handshake to the new remote anyways, and because if we did a client invoke it could get intercepted

	if requestType == ServerRequestMethod.KeyExchange then
		if lockedKeys[player] then
			return
		end

		-- TODO: Sign key with asymmetric keys (public private keys), so the client can verify the servers identity (and prevent man in the middle attacks)

		local key = Functions.randomString(64) -- 64 is the blocksize for sha256, if it's not exactly 64 then HMAC would either extend the key to be 64 characters, or hash the key to become 64 characters
		keys[player] = key

		return key
	elseif requestType == ServerRequestMethod.Handshake then
		-- Basic handshake to verify the servers identity, is not 100% immune to man in the middle attacks, but checking the time it took for the request to complete compared to your ping should help

		if not isValidRequestKey(player, requestKey) then
			return
		end

		connectedPlayers[player] = true -- We will assume that the handshake succeeds for the client aswell
		lockedKeys[player] = true

		return generateRequestKey(player)
	elseif requestType == ServerRequestMethod.Event then
		-- Minimize the yielding time for the client if the server is calculating stuff
		task.spawn(function(eventName, ...)
			local callback = registeredEvents[eventName]
			if not callback then
				return
			end

			if not isValidRequestKey(player, requestKey) then
				return
			end

			callback(player, ...)
		end, ...)
	elseif requestType == ServerRequestMethod.Invoke then
		-- Minimize the yielding time for the client if the server is calculating stuff
		task.spawn(function(id, functionName, ...)
			local callback = registeredFunctions[functionName]
			if not callback then
				return
			end

			if not isValidRequestKey(player, requestKey) then
				return
			end

			(function(...)
				while not connectedPlayers[player] or not remote or remote.Parent ~= remoteParent do
					task.wait()
				end

				remote:InvokeClient(player, ClientRequestMethod.InvokeResult, generateRequestKey(player), id, ...)
			end)(callback(player, ...))
		end, ...)
	end

	return
end

function Network:FireClient(player: Player, eventName: string, ...: any)
	task.spawn(function(...)
		while not connectedPlayers[player] or not remote or remote.Parent ~= remoteParent do
			task.wait()
		end

		remote:InvokeClient(player, ClientRequestMethod.Event, generateRequestKey(player), eventName, ...)
	end, ...)
end

function Network:FireAllClients(eventName: string, ...: any)
	for _, player: Player in ipairs(Players:GetPlayers()) do
		Network:FireClient(player, eventName, ...)
	end
end

function Network:Init()
	local lastRemoteFix = os.clock() -- We keep track of this so we can recreate the remote every 5 seconds, incase the remote get deleted on someones client
	local function fixRemote()
		lastRemoteFix = os.clock()

		if remote then
			task.delay(0, function(oldRemote)
				Protection.remove(oldRemote)
				oldRemote:Destroy()
			end, remote)
		end

		table.clear(connectedPlayers)

		remote = Instance.new("RemoteFunction")
		remote.Name = Functions.randomInstanceName()
		remote.Archivable = false
		remote:SetAttribute(Network.attributeName, Network.attributeValue)

		Protection.add(remote, "write")

		remoteParent = services[math.random(1, #services)]
		remote.Parent = remoteParent
	end

	fixRemote()
	remote.OnServerInvoke = onRequest

	-- Already leaked magic 🤯 (I know better methods but I don't want to leak them ;) - EwDev)
	local args: any = table.create(80, task.defer)
	table.insert(args, function()
		if
			not remote
			or remote.Parent ~= remoteParent
			or remote:GetAttribute(Network.attributeName) ~= Network.attributeValue
			or #remote:GetChildren() > 2
			or os.clock() - lastRemoteFix >= 5
		then
			fixRemote()
		end

		remote.OnServerInvoke = onRequest
	end)

	RunService.PostSimulation:Connect(function()
		pcall(unpack(args))
	end)
end

return Network
