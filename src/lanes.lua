--
-- LANES.LUA
--
-- Multithreading and -core support for Lua
--
-- Authors: Asko Kauppi <akauppi@gmail.com>
--          Benoit Germain <bnt.germain@gmail.com>
--
-- History: see CHANGES
--
--[[
===============================================================================

Copyright (C) 2007-10 Asko Kauppi <akauppi@gmail.com>
Copyright (C) 2010-13 Benoit Germain <bnt.germain@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

===============================================================================
]]--

local core = require "lanes.core"
-- Lua 5.1: module() creates a global variable
-- Lua 5.2: module() is gone
-- almost everything module() does is done by require() anyway
-- -> simply create a table, populate it, return it, and be done
local lanes = {}

-- this function is available in the public interface until it is called, after which it disappears
lanes.configure = function( settings_)

	-- This check is for sublanes requiring Lanes
	--
	-- TBD: We could also have the C level expose 'string.gmatch' for us. But this is simpler.
	--
	if not string then
		error( "To use 'lanes', you will also need to have 'string' available.", 2)
	end

	-- 
	-- Cache globals for code that might run under sandboxing
	--
	local assert = assert
	local string_gmatch = assert( string.gmatch)
	local select = assert( select)
	local type = assert( type)
	local pairs = assert( pairs)
	local tostring = assert( tostring)
	local error = assert( error)

	local default_params =
	{
		nb_keepers = 1,
		on_state_create = nil,
		shutdown_timeout = 0.25,
		with_timers = true,
		track_lanes = false,
		verbose_errors = false,
		-- LuaJIT provides a thread-unsafe allocator by default, so we need to protect it when used in parallel lanes
		protect_allocator = (jit and jit.version) and true or false
	}
	local param_checkers =
	{
		nb_keepers = function( _val)
			-- nb_keepers should be a number > 0
			return type( _val) == "number" and _val > 0
		end,
		with_timers = function( _val)
			-- with_timers may be nil or boolean
			if _val then
				return type( _val) == "boolean"
			else
				return true -- _val is either false or nil
			end
		end,
		protect_allocator = function( _val)
			-- protect_allocator may be nil or boolean
			if _val then
				return type( _val) == "boolean"
			else
				return true -- _val is either false or nil
			end
		end,
		on_state_create = function( _val)
			-- on_state_create may be nil or a function
			return _val and type( _val) == "function" or true
		end,
		shutdown_timeout = function( _val)
			-- shutdown_timeout should be a number >= 0
			return type( _val) == "number" and _val >= 0
		end,
		track_lanes = function( _val)
			-- track_lanes may be nil or boolean
			return _val and type( _val) == "boolean" or true
		end,
		verbose_errors = function( _val)
			-- verbose_errors may be nil or boolean
			if _val then
				return type( _val) == "boolean"
			else
				return true -- _val is either false or nil
			end
		end
	}

	local params_checker = function( settings_)
		if not settings_ then
			return default_params
		end
		-- make a copy of the table to leave the provided one unchanged, *and* to help ensure it won't change behind our back
		local settings = {}
		if type( settings_) ~= "table" then
			error "Bad parameter #1 to lanes.configure(), should be a table"
		end
		-- any setting not present in the provided parameters takes the default value
		for key, checker in pairs( param_checkers) do
			local my_param = settings_[key]
			local param
			if my_param ~= nil then
				param = my_param
			else
				param = default_params[key]
			end
			if not checker( param) then
				error( "Bad " .. key .. ": " .. tostring( param), 2)
			end
			settings[key] = param
		end
		return settings
	end
	local settings = core.configure and core.configure( params_checker( settings_)) or core.settings
	local thread_new = assert( core.thread_new)
	local set_singlethreaded = assert( core.set_singlethreaded)
	local max_prio = assert( core.max_prio)

lanes.ABOUT =
{
	author= "Asko Kauppi <akauppi@gmail.com>, Benoit Germain <bnt.germain@gmail.com>",
	description= "Running multiple Lua states in parallel",
	license= "MIT/X11",
	copyright= "Copyright (c) 2007-10, Asko Kauppi; (c) 2011-13, Benoit Germain",
	version = assert( core.version)
}


-- Making copies of necessary system libs will pass them on as upvalues;
-- only the first state doing "require 'lanes'" will need to have 'string'
-- and 'table' visible.
--
local function WR(str)
    io.stderr:write( str.."\n" )
end

local function DUMP( tbl )
    if not tbl then return end
    local str=""
    for k,v in pairs(tbl) do
        str= str..k.."="..tostring(v).."\n"
    end
    WR(str)
end


---=== Laning ===---

-- lane_h[1..n]: lane results, same as via 'lane_h:join()'
-- lane_h[0]:    can be read to make sure a thread has finished (always gives 'true')
-- lane_h[-1]:   error message, without propagating the error
--
--      Reading a Lane result (or [0]) propagates a possible error in the lane
--      (and execution does not return). Cancelled lanes give 'nil' values.
--
-- lane_h.state: "pending"/"running"/"waiting"/"done"/"error"/"cancelled"
--
-- Note: Would be great to be able to have '__ipairs' metamethod, that gets
--      called by 'ipairs()' function to custom iterate objects. We'd use it
--      for making sure a lane has ended (results are available); not requiring
--      the user to precede a loop by explicit 'h[0]' or 'h:join()'.
--
--      Or, even better, 'ipairs()' should start valuing '__index' instead
--      of using raw reads that bypass it.
--
-----
-- lanes.gen( [libs_str|opt_tbl [, ...],] lane_func ) ( [...] ) -> h
--
-- 'libs': nil:     no libraries available (default)
--         "":      only base library ('assert', 'print', 'unpack' etc.)
--         "math,os": math + os + base libraries (named ones + base)
--         "*":     all standard libraries available
--
-- 'opt': .priority:  int (-3..+3) smaller is lower priority (0 = default)
--
--	      .cancelstep: bool | uint
--            false: cancellation check only at pending Linda operations
--                   (send/receive) so no runtime performance penalty (default)
--            true:  adequate cancellation check (same as 100)
--            >0:    cancellation check every x Lua lines (small number= faster
--                   reaction but more performance overhead)
--
--        .globals:  table of globals to set for a new thread (passed by value)
--
--        .required:  table of packages to require
--        ... (more options may be introduced later) ...
--
-- Calling with a function parameter ('lane_func') ends the string/table
-- modifiers, and prepares a lane generator. One can either finish here,
-- and call the generator later (maybe multiple times, with different parameters) 
-- or add on actual thread arguments to also ignite the thread on the same call.

local valid_libs=
{
	["package"] = true,
	["table"] = true,
	["io"] = true,
	["os"] = true,
	["string"] = true,
	["math"] = true,
	["debug"] = true,
	["bit32"] = true, -- Lua 5.2 only, ignored silently under 5.1
	--
	["base"] = true,
	["coroutine"] = true, -- part of "base" in Lua 5.1
	["lanes.core"] = true
}

-- PUBLIC LANES API
local function gen( ... )
    local opt= {}
    local libs= nil
    local lev= 2  -- level for errors

    local n= select('#',...)
    
    if n==0 then
        error( "No parameters!" )
    end

    for i=1,n-1 do
        local v= select(i,...)
        if type(v)=="string" then
            libs= libs and libs..","..v or v
        elseif type(v)=="table" then
            for k,vv in pairs(v) do
                opt[k]= vv
            end
        elseif v==nil then
            -- skip
        else
            error( "Bad parameter: "..tostring(v) )
        end
    end

    local func= select(n,...)
    local functype = type(func)
    if functype ~= "function" and functype ~= "string" then
        error( "Last parameter not function or string: "..tostring(func))
    end

    -- Check 'libs' already here, so the error goes in the right place
    -- (otherwise will be noticed only once the generator is called)
    -- "*" is a special case that doesn't require individual checking
    --
    if libs and libs ~= "*" then
        local found = {}
        -- check that the caller only provides reserved library names
        for s in string_gmatch(libs, "[%a%d.]+") do
            if not valid_libs[s] then
                error( "Bad library name: " .. s)
            else
                found[s] = (found[s] or 0) + 1
                if found[s] > 1 then
                    error( "libs specification contains '" .. s .. "' more than once")
                end
            end
        end
    end
    
    local prio, cs, g_tbl, package_tbl, required

    for k,v in pairs(opt) do
            if k=="priority" then prio= v
        elseif k=="cancelstep" then
            cs = (v==true) and 100 or
                (v==false) and 0 or 
                type(v)=="number" and v or
                error( "Bad cancelstep: "..tostring(v), lev )
        elseif k=="globals" then g_tbl= v
        elseif k=="package" then
            package_tbl = (type( v) == "table") and v or error( "Bad package: " .. tostring( v), lev)
        elseif k=="required" then
            required= (type( v) == "table") and v or error( "Bad 'required' option: expecting table, got " .. type( v), lev)
        --..
        elseif k==1 then error( "unkeyed option: ".. tostring(v), lev )
        else error( "Bad option: ".. tostring(k), lev )
        end
    end

    if not package_tbl then package_tbl = package end
    -- Lane generator
    --
    return function(...)
        return thread_new( func, libs, settings.on_state_create, cs, prio, g_tbl, package_tbl, required, ...)     -- args
    end
end

---=== Lindas ===---

-- We let the C code attach methods to userdata directly

-----
-- lanes.linda(["name"]) -> linda_ud
--
-- PUBLIC LANES API
local linda = core.linda


---=== Timers ===---

-- PUBLIC LANES API
local timer = function() error "timers are not active" end
local timer_lane = nil
local timers = timer

if settings.with_timers ~= false then

local timer_gateway = assert( core.timer_gateway)
--
-- On first 'require "lanes"', a timer lane is spawned that will maintain
-- timer tables and sleep in between the timer events. All interaction with
-- the timer lane happens via a 'timer_gateway' Linda, which is common to
-- all that 'require "lanes"'.
-- 
-- Linda protocol to timer lane:
--
--  TGW_KEY: linda_h, key, [wakeup_at_secs], [repeat_secs]
--
local TGW_KEY= "(timer control)"    -- the key does not matter, a 'weird' key may help debugging
local TGW_QUERY, TGW_REPLY = "(timer query)", "(timer reply)"
local first_time_key= "first time"

local first_time= timer_gateway:get(first_time_key) == nil
timer_gateway:set(first_time_key,true)

--
-- Timer lane; initialize only on the first 'require "lanes"' instance (which naturally
-- has 'table' always declared)
--
if first_time then

	local now_secs = core.now_secs
	assert( type( now_secs) == "function")
	-----
	-- Snore loop (run as a lane on the background)
	--
	-- High priority, to get trustworthy timings.
	--
	-- We let the timer lane be a "free running" thread; no handle to it
	-- remains.
	--
	local timer_body = function()
		set_debug_threadname( "LanesTimer")
		--
		-- { [deep_linda_lightuserdata]= { [deep_linda_lightuserdata]=linda_h, 
		--                                 [key]= { wakeup_secs [,period_secs] } [, ...] },
		-- }
		--
		-- Collection of all running timers, indexed with linda's & key.
		--
		-- Note that we need to use the deep lightuserdata identifiers, instead
		-- of 'linda_h' themselves as table indices. Otherwise, we'd get multiple
		-- entries for the same timer.
		--
		-- The 'hidden' reference to Linda proxy is used in 'check_timers()' but
		-- also important to keep the Linda alive, even if all outside world threw
		-- away pointers to it (which would ruin uniqueness of the deep pointer).
		-- Now we're safe.
		--
		local collection = {}
		local table_insert = assert( table.insert)

		local get_timers = function()
			local r = {}
			for deep, t in pairs( collection) do
				-- WR( tostring( deep))
				local l = t[deep]
				for key, timer_data in pairs( t) do
					if key ~= deep then
						table_insert( r, {l, key, timer_data})
					end
				end
			end
			return r
		end -- get_timers()

		--
		-- set_timer( linda_h, key [,wakeup_at_secs [,period_secs]] )
		--
		local set_timer = function( linda, key, wakeup_at, period)
			assert( wakeup_at == nil or wakeup_at > 0.0)
			assert( period == nil or period > 0.0)

			local linda_deep = linda:deep()
			assert( linda_deep)

			-- Find or make a lookup for this timer
			--
			local t1 = collection[linda_deep]
			if not t1 then
				t1 = { [linda_deep] = linda}     -- proxy to use the Linda
				collection[linda_deep] = t1
			end
		
			if wakeup_at == nil then
				-- Clear the timer
				--
				t1[key]= nil

				-- Remove empty tables from collection; speeds timer checks and
				-- lets our 'safety reference' proxy be gc:ed as well.
				--
				local empty = true
				for k, _ in pairs( t1) do
					if k ~= linda_deep then
						empty = false
						break
					end
				end
				if empty then
					collection[linda_deep] = nil
				end

				-- Note: any unread timer value is left at 'linda[key]' intensionally;
				--       clearing a timer just stops it.
			else
				-- New timer or changing the timings
				--
				local t2 = t1[key]
				if not t2 then
					t2= {}
					t1[key]= t2
				end
		
				t2[1] = wakeup_at
				t2[2] = period   -- can be 'nil'
			end
		end -- set_timer()

		-----
		-- [next_wakeup_at]= check_timers()
		-- Check timers, and wake up the ones expired (if any)
		-- Returns the closest upcoming (remaining) wakeup time (or 'nil' if none).
		local check_timers = function()
			local now = now_secs()
			local next_wakeup

			for linda_deep,t1 in pairs(collection) do
				for key,t2 in pairs(t1) do
					--
					if key==linda_deep then
						-- no 'continue' in Lua :/
					else
						-- 't2': { wakeup_at_secs [,period_secs] }
						--
						local wakeup_at= t2[1]
						local period= t2[2]     -- may be 'nil'

						if wakeup_at <= now then    
							local linda= t1[linda_deep]
							assert(linda)
		
							linda:set( key, now )
				
							-- 'pairs()' allows the values to be modified (and even
							-- removed) as far as keys are not touched

							if not period then
								-- one-time timer; gone
								--
								t1[key]= nil
								wakeup_at= nil   -- no 'continue' in Lua :/
							else
								-- repeating timer; find next wakeup (may jump multiple repeats)
								--
								repeat
										wakeup_at= wakeup_at+period
								until wakeup_at > now

								t2[1]= wakeup_at
							end
						end
										
						if wakeup_at and ((not next_wakeup) or (wakeup_at < next_wakeup)) then
							next_wakeup= wakeup_at
						end 
					end
				end -- t2 loop
			end -- t1 loop

			return next_wakeup  -- may be 'nil'
		end -- check_timers()

		local timer_gateway_batched = timer_gateway.batched
		set_finalizer( function( err, stk)
			if err and type( err) ~= "userdata" then
				WR( "LanesTimer error: "..tostring(err))
			--elseif type( err) == "userdata" then
			--	WR( "LanesTimer after cancel" )
			--else
			--	WR("LanesTimer finalized")
			end
		end)
		while true do
			local next_wakeup = check_timers()

			-- Sleep until next timer to wake up, or a set/clear command
			--
			local secs
			if next_wakeup then
				secs =  next_wakeup - now_secs()
				if secs < 0 then secs = 0 end
			end
			local key, what = timer_gateway:receive( secs, TGW_KEY, TGW_QUERY)

			if key == TGW_KEY then
				assert( getmetatable( what) == "Linda") -- 'what' should be a linda on which the client sets a timer
				local _, key, wakeup_at, period = timer_gateway:receive( 0, timer_gateway_batched, TGW_KEY, 3)
				assert( key)
				set_timer( what, key, wakeup_at, period and period > 0 and period or nil)
			elseif key == TGW_QUERY then
				if what == "get_timers" then
					timer_gateway:send( TGW_REPLY, get_timers())
				else
					timer_gateway:send( TGW_REPLY, "unknown query " .. what)
				end
			--elseif secs == nil then -- got no value while block-waiting?
			--	WR( "timer lane: no linda, aborted?")
			end
		end
	end -- timer_body()
	timer_lane = gen( "*", { package= {}, priority = max_prio}, timer_body)() -- "*" instead of "io,package" for LuaJIT compatibility...
end -- first_time

-----
-- = timer( linda_h, key_val, date_tbl|first_secs [,period_secs] )
--
-- PUBLIC LANES API
timer = function( linda, key, a, period )
    if getmetatable( linda) ~= "Linda" then
        error "expecting a Linda"
    end
    if a == 0.0 then
        -- Caller expects to get current time stamp in Linda, on return
        -- (like the timer had expired instantly); it would be good to set this
        -- as late as possible (to give most current time) but also we want it
        -- to precede any possible timers that might start striking.
        --
        linda:set( key, core.now_secs())

        if not period or period==0.0 then
            timer_gateway:send( TGW_KEY, linda, key, nil, nil )   -- clear the timer
            return  -- nothing more to do
        end
        a= period
    end

    local wakeup_at= type(a)=="table" and core.wakeup_conv(a)    -- given point of time
                                       or (a and core.now_secs()+a or nil)
    -- queue to timer
    --
    timer_gateway:send( TGW_KEY, linda, key, wakeup_at, period )
end

-----
-- {[{linda, slot, when, period}[,...]]} = timers()
--
-- PUBLIC LANES API
timers = function()
	timer_gateway:send( TGW_QUERY, "get_timers")
	local _, r = timer_gateway:receive( TGW_REPLY)
	return r
end

end -- settings.with_timers

---=== Lock & atomic generators ===---

-- These functions are just surface sugar, but make solutions easier to read.
-- Not many applications should even need explicit locks or atomic counters.

--
-- lock_f= lanes.genlock( linda_h, key [,N_uint=1] )
--
-- = lock_f( +M )   -- acquire M
--      ...locked...
-- = lock_f( -M )   -- release M
--
-- Returns an access function that allows 'N' simultaneous entries between
-- acquire (+M) and release (-M). For binary locks, use M==1.
--
-- PUBLIC LANES API
local genlock = function( linda, key, N)
	linda:limit( key, N)
	linda:set( key, nil)  -- clears existing data

	--
	-- [true [, ...]= trues(uint)
	--
	local function trues( n)
		if n > 0 then
			return true, trues( n - 1)
		end
	end

	-- use an optimized version for case N == 1
	return (N == 1) and
	function( M, mode_)
		local timeout = (mode_ == "try") and 0 or nil
		if M > 0 then
			-- 'nil' timeout allows 'key' to be numeric
			return linda:send( timeout, key, true)    -- suspends until been able to push them
		else
			local k = linda:receive( nil, key)
			return k and true or false
		end
	end
	or
	function( M, mode_)
		local timeout = (mode_ == "try") and 0 or nil
		if M > 0 then
			-- 'nil' timeout allows 'key' to be numeric
			return linda:send( timeout, key, trues(M))    -- suspends until been able to push them
		else
			local k = linda:receive( nil, linda.batched, key, -M)
			return k and true or false
		end
	end
end


--
-- atomic_f= lanes.genatomic( linda_h, key [,initial_num=0.0] )
--
-- int= atomic_f( [diff_num=1.0] )
--
-- Returns an access function that allows atomic increment/decrement of the
-- number in 'key'.
--
-- PUBLIC LANES API
local function genatomic( linda, key, initial_val )
    linda:limit(key,2)          -- value [,true]
    linda:set(key,initial_val or 0.0)   -- clears existing data (also queue)

    return
    function(diff)
        -- 'nil' allows 'key' to be numeric
        linda:send( nil, key, true )    -- suspends until our 'true' is in
        local val= linda:get(key) + (diff or 1.0)
        linda:set( key, val )   -- releases the lock, by emptying queue
        return val
    end
end

	-- activate full interface
	lanes.require = core.require
	lanes.gen = gen
	lanes.linda = core.linda
	lanes.cancel_error = core.cancel_error
	lanes.nameof = core.nameof
	lanes.threads = core.threads or function() error "lane tracking is not available" end -- core.threads isn't registered if settings.track_lanes is false
	lanes.set_thread_priority = core.set_thread_priority
	lanes.timer = timer
	lanes.timer_lane = timer_lane
	lanes.timers = timers
	lanes.genlock = genlock
	lanes.now_secs = core.now_secs
	lanes.genatomic = genatomic
	lanes.configure = nil -- no need to call configure() ever again
	return lanes
end -- lanes.configure

-- no need to force calling configure() excepted the first time
if core.settings then
	return lanes.configure()
else
	return lanes
end

--the end
return lanes
