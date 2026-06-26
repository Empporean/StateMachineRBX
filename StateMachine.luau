--[[
	V1.1
	
	Improved code readabillity + fixed stupid mistakes in checkers
	Fixed forcestate bug
	getHistory now read only
	added debug mode
	
	--TODO head/tail for queue
]]

local t = require(script.t)

local StateMachine = {}
StateMachine.__index = StateMachine

type StateName = string
type EventName = string
type Payload = { [any]: any }
type Context = { [any]: any }

type Guard = (machine: any, payload: Payload?) -> boolean
type Action = (machine: any, payload: Payload?) -> ()

type StateHook = (machine: any, payload: Payload?, from: StateName?, to: StateName?, event: EventName?) -> ()

type State = {
	onEnter: StateHook?,
	onExit: StateHook?,
}

type Transition = {
	name: string?,
	from: StateName | "*",
	event: EventName,
	to: StateName,
	guard: Guard?,
	action: Action?,
	reenter: boolean?,
}

type TransitionCallback = (machine: any, transition: Transition, from: StateName, to: StateName, event: EventName, payload: Payload?) -> ()

type HistoryRecord = {
	from: StateName,
	to: StateName,
	event: EventName,
	timestamp: number,
	transitionName: string?,
}

type Options = {
	historyLimit: number?,
}

export type Machine = typeof(StateMachine.new(...))

-- валидаторы

local function nonEmptyStr(v: any): boolean
	return t.string(v) and v ~= ""
end

local function fromStateValid(v: any): boolean
	return v == "*" or nonEmptyStr(v)
end

local function posInt(v: any): boolean
	return t.number(v) and v > 0 and math.floor(v) == v
end

local checkState = t.optional(t.strictInterface({
	onEnter = t.optional(t.callback),
	onExit = t.optional(t.callback),
}))

local checkTransition = t.strictInterface({
	name = t.optional(t.string),
	from = fromStateValid,
	event = nonEmptyStr,
	to = nonEmptyStr,
	guard = t.optional(t.callback),
	action = t.optional(t.callback),
	reenter = t.optional(t.boolean),
})

local checkOptions = t.optional(t.strictInterface({
	historyLimit = t.optional(posInt),
}))

local checkPayload = t.optional(t.table)
local checkContext = t.optional(t.table)

local function check(fn, val, msg)
	if not fn(val) then
		error(msg, 3)
	end
end

local function guardDestroyed(self, where)
	if self._destroyed then
		error(where .. ": machine is destroyed", 3)
	end
end

local function guardStarted(self, where)
	if self._started then
		error(where .. ": already started", 3)
	end
end

local function needState(self, name, where)
	if not self._states[name] then
		error(where .. ': unknown state "' .. name .. '"', 3)
	end
end

local function noState(self, name, where)
	if self._states[name] then
		error(where .. ': state "' .. name .. '" already exists', 3)
	end
end

function StateMachine.new(initialState: StateName, context: Context?, options: Options?)
	check(nonEmptyStr, initialState, "StateMachine.new: need initialState")
	check(checkContext, context, "StateMachine.new: context should be table or nil")
	check(checkOptions, options, "StateMachine.new: invalid options")

	local self = setmetatable({}, StateMachine)

	self._initialState = initialState
	self._currentState = nil
	self._context = context or {}
	self._states = {}
	self._transitions = {}
	self._history = {}
	self._historyLimit = options and options.historyLimit or 100
	self._queue = {}
	self._started = false
	self._destroyed = false
	self._processing = false
	self._beforeTransition = nil
	self._afterTransition = nil
	self._debugMode = options and options.debugMode or false
	self._prefix = script.Name
	
	if self._debugMode then
		print(`[{self._prefix}]: created new machine, initial state: {self._initialState}, context: {self._context}`)
	end

	return self
end

function StateMachine:addState(name: StateName, definition: State?)
	guardDestroyed(self, "addState")
	guardStarted(self, "addState")
	check(nonEmptyStr, name, "addState: need name")
	check(checkState, definition, "addState: invalid definition")
	noState(self, name, "addState")

	self._states[name] = definition or {}
	if self._debugMode then
		print(`[{self._prefix}]: added state {name}, definition: {definition}`)
	end
	return self
end

function StateMachine:addTransition(cfg: Transition)
	guardDestroyed(self, "addTransition")
	guardStarted(self, "addTransition")
	check(checkTransition, cfg, "addTransition: invalid config")

	if cfg.from ~= "*" then
		needState(self, cfg.from, "addTransition")
	end
	needState(self, cfg.to, "addTransition")

	if not self._transitions[cfg.from] then
		self._transitions[cfg.from] = {}
	end
	if not self._transitions[cfg.from][cfg.event] then
		self._transitions[cfg.from][cfg.event] = {}
	end

	table.insert(self._transitions[cfg.from][cfg.event], cfg)
	if self._debugMode then
		print(`[{self._prefix}]: added transition from {cfg.from} on {cfg.event} to {cfg.to}`)
	end
	return self
end

function StateMachine:setBeforeTransition(cb: TransitionCallback?)
	self._beforeTransition = cb
	if self._debugMode then
		print(`[{self._prefix}]: set beforeTransition callback`)
	end
	return self
end

function StateMachine:setAfterTransition(cb: TransitionCallback?)
	self._afterTransition = cb
	if self._debugMode then
		print(`[{self._prefix}]: set afterTransition callback`)
	end
	return self
end

function StateMachine:start(payload: Payload?)
	guardDestroyed(self, "start")
	guardStarted(self, "start")
	check(checkPayload, payload, "start: payload must be table or nil")
	needState(self, self._initialState, "start")

	self._started = true
	self._currentState = self._initialState

	local state = self._states[self._initialState]
	if state and state.onEnter then
		state.onEnter(self, payload, nil, self._initialState, nil)
		if self._debugMode then
			print(`[{self._prefix}]: called onEnter for initial state {self._initialState}`)
		end
	end
	
	if self._debugMode then
		print(`[{self._prefix}]: started, initial state: {self._initialState}`)
	end

	return self
end

function StateMachine:_findTransition(event: EventName, payload: Payload?)
	local currentState = self._currentState
	if not currentState then return nil end

	local function tryList(list)
		if not list then return nil end
		for _, transition in ipairs(list) do
			if transition.guard == nil or transition.guard(self, payload) then
				if self._debugMode then
					print(`[{self._prefix}]: found transition from {currentState} on {event} to {transition.to}`)
				end
				return transition
			end
		end
		return nil
	end

	local byState = self._transitions[currentState]
	if byState then
		local found = tryList(byState[event])
		if found then
			if self._debugMode then
				print(`[{self._prefix}]: found transition from {currentState} on {event} to {found.to}`)
			end
			
			return found 
		end
	end

	local wildcard = self._transitions["*"]
	if wildcard then
		local found = tryList(wildcard[event])
		if found then 
			if self._debugMode then
				print(`[{self._prefix}]: found transition from {currentState} on {event} to {found.to} using wildcard`)
			end
			
			return found 
		end
	end

	return nil
end

function StateMachine:_pushHistory(from, to, event, name)
	table.insert(self._history, {
		from = from,
		to = to,
		event = event,
		timestamp = os.clock(),
		transitionName = name,
	})

	while #self._history > self._historyLimit do
		table.remove(self._history, 1)
	end
end

function StateMachine:_drainQueue()
	while #self._queue > 0 and not self._processing do
		local next = table.remove(self._queue, 1)
		if next then
			self:dispatch(next.event, next.payload)
		end
	end
end

function StateMachine:dispatch(event: EventName, payload: Payload?): (boolean, string?)
	check(nonEmptyStr, event, "dispatch: need event")
	check(checkPayload, payload, "dispatch: payload must be table or nil")

	if self._destroyed then return false, "Destroyed" end
	if not self._started then return false, "NotStarted" end

	if self._processing then
		table.insert(self._queue, { event = event, payload = payload })
		return true, "Queued"
	end

	self._processing = true

	local transition = self:_findTransition(event, payload)
	if not transition then
		self._processing = false
		self:_drainQueue()
		return false, "NoTransition"
	end

	local from = self._currentState
	local to = transition.to
	local selfLoop = from == to
	local runHooks = not selfLoop or transition.reenter == true

	if self._beforeTransition then
		self._beforeTransition(self, transition, from, to, event, payload)
	end

	if runHooks then
		local fromDef = self._states[from]
		if fromDef and fromDef.onExit then
			fromDef.onExit(self, payload, from, to, event)
		end
	end

	if transition.action then
		transition.action(self, payload)
	end

	self._currentState = to

	if runHooks then
		local toDef = self._states[to]
		if toDef and toDef.onEnter then
			toDef.onEnter(self, payload, from, to, event)
		end
	end

	self:_pushHistory(from, to, event, transition.name)

	if self._afterTransition then
		self._afterTransition(self, transition, from, to, event, payload)
	end

	self._processing = false
	self:_drainQueue()

	return true, nil
end

function StateMachine:getState(): StateName?
	return self._currentState
end

function StateMachine:is(state: StateName): boolean
	return self._currentState == state
end

function StateMachine:canDispatch(event: EventName, payload: Payload?): boolean
	if self._destroyed or not self._started then return false end
	return self:_findTransition(event, payload) ~= nil
end

function StateMachine:getAvailableEvents(): { EventName }
	local cur = self._currentState
	if not cur then return {} end

	local seen = {}
	local result = {}

	local function collect(map)
		if not map then return end
		for ev in pairs(map) do
			if not seen[ev] then
				seen[ev] = true
				table.insert(result, ev)
			end
		end
	end

	collect(self._transitions[cur])
	collect(self._transitions["*"])

	return result
end

function StateMachine:getHistory(): { HistoryRecord }
	return table.clone(self._history)
end

function StateMachine:getContext(): Context
	return self._context
end

-- ignore guards
function StateMachine:forceState(targetState: StateName, payload: Payload?, runHooks: boolean?)
	guardDestroyed(self, "forceState")
	check(nonEmptyStr, targetState, "forceState: need state")
	needState(self, targetState, "forceState")

	local from = self._currentState
	local to = targetState
	local hooks = runHooks == true

	if hooks and from then
		local state = self._states[from]
		if state and state.onExit then
			state.onExit(self, payload, from, to, nil)
		end
	end

	self._currentState = to

	if hooks then
		local state = self._states[to]
		if state and state.onEnter then
			state.onEnter(self, payload, from, to, nil)
		end
	end

	if from then
		self:_pushHistory(from, to, "force", nil)
	end

	return self
end

function StateMachine:reset(payload: Payload?)
	guardDestroyed(self, "reset")

	self._queue = {}
	self._processing = false

	if self._currentState then
		self:forceState(self._initialState, payload, true)
	else
		self._currentState = self._initialState
	end

	return self
end

function StateMachine:destroy()
	if self._destroyed then return end

	self._destroyed = true
	self._started = false
	self._processing = false
	self._currentState = nil
	self._queue = {}
	self._history = {}
	self._beforeTransition = nil
	self._afterTransition = nil
end

return StateMachine
