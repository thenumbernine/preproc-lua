local string = require 'ext.string'
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local os = require 'ext.os'
local io = require 'ext.io'
local file = require 'ext.file'
local class = require 'ext.class'

local namepat = '[_%a][_%w]*'

local function isvalidsymbol(s)
	return not not s:match('^'..namepat..'$')
end

local function removeCommentsAndApplyContinuations(code)
	
	-- should line continuations \ affect single-line comments?
	-- if so then do this here
	-- or should they not?  then do this after.
	repeat
		local i, j = code:find('\\%s*\n')
		if not i then break end
		code = code:sub(1,i-1)..' '..code:sub(j+1)
	until false

	-- remove all /* */ blocks first
	repeat
		local i = code:find('/*',1,true)
		if not i then break end
		local j = code:find('*/',i+2,true)
		if not j then
			error("found /* with no */")
		end
		code = code:sub(1,i-1)..code:sub(j+2)
	until false

	-- [[ remove all // \n blocks first
	repeat
		local i = code:find('//',1,true)
		if not i then break end
		local j = code:find('\n',i+2,true) or #code
		code = code:sub(1,i-1)..code:sub(j)
	until false
	--]]

	return code
end


local Preproc = class()

--[[
Preproc(code)
Preproc(args)
args = table of:
	code = code to use
	sysIncludeDirs = include directories to use for ""
	userIncludeDirs = include directories to use for <>
	macros = macros to use
--]]
function Preproc:init(args)
	if args ~= nil then
		self(args)
	end
	self.macros = {}

	self.alreadyIncludedFiles = {}

	self.sysIncludeDirs = table()
	self.userIncludeDirs = table()

	self.generatedEnums = {}


	-- builtin/default macros?
	-- here's some for gcc:
	self:setMacros{__restrict = ''}
	self:setMacros{__restrict__ = ''}


	-- the INCLUDE env var is for <> and not "", right?
	-- not showing up at all in linux 'g++ -xc++ -E -v - < /dev/null' ...
	-- maybe it's just for make?
	-- yup, and make puts INCLUDE as a <> search folder
	local incenv = os.getenv'INCLUDE'
	if incenv then
		self:addIncludeDirs(string.split(incenv, ';'), true)
	end
end

function Preproc:setMacros(args)
	for k,v in pairs(args) do
		self.macros[k] = v
	end
end

function Preproc:addIncludeDir(dir, sys)
	-- should I fix paths of the user-provided userIncludeDirs? or just INCLUDE?
	dir = dir:gsub('\\', '/')
	if sys then
		self.sysIncludeDirs:insert(dir)
	else
		self.userIncludeDirs:insert(dir)
	end
end

function Preproc:addIncludeDirs(dirs, ...)
	for _,dir in ipairs(dirs) do
		self:addIncludeDir(dir, ...)
	end
end


function Preproc:searchForInclude(fn, sys, startHere)
	local includeDirs = sys
		and self.sysIncludeDirs
		
		--[[
		seems "" searches also check <> search paths
		but do <> searches also search "" search paths?
		why even use different search folders?
		--]]
		--or self.userIncludeDirs
		or table():append(self.userIncludeDirs, self.sysIncludeDirs)
	
	local startIndex
	if startHere then
--print('searching '..tolua(includeDirs))
--print('search starting '..tostring(startHere))
		startHere = startHere:match'^(.-)/*$'	-- remove trailing /'s
		for i=1,#includeDirs do
			local dir = includeDirs[i]:match'^(.-)/*$'
--print("does "..tostring(startHere).." match "..tostring(dir).." ? "..tostring(dir == startHere))
			if dir == startHere then
				startIndex = i+1
				break
			end
		end
--print('startIndex '..tostring(startIndex))
		-- if we couldn't find startHere then ... is that good? do we just fallback on default? or do we error?
		-- startHere is set when we are already in a file of a matching name, so we should be finding something, right?
		if not startIndex then
			error'here'
		end
	end
	startIndex = startIndex or 1
	for i=startIndex,#includeDirs do
		d = includeDirs[i]
		local p = d..'/'..fn
		p = p:gsub('//+', '/')
		if os.fileexists(p) then
			return p
		end
	end
end

local function handleMacroWithArgs(l, macros, key, vparams)
	local pat = key..'%s*(%b())'
	local j,k = l:find(pat)
	if not j then return end

	local before = l:sub(j-1,j-1)
	if before:match'[_a-zA-Z0-9]' then return end

--print('found macro', key)
--print('replacing from params '..tolua(vparams))
	
	local paramStr = l:sub(j,k):match(pat)
	paramStr = paramStr:sub(2,-2)	-- strip outer ()'s
--print('found paramStr', paramStr)
	-- so now split by commas, but ignore commas that are out of balance with parenthesis
	local paramIndex = 0
	local paramMap = {}
	if not paramStr:match'^%s*$' then
		local parcount = 0
		local last = 1
		local i = 1
		while i <= #paramStr do
			local ch = paramStr:sub(i,i)
			if ch == '(' then
				parcount = parcount + 1
			elseif ch == ')' then
				parcount = parcount - 1
			elseif ch == '"' then
				-- skip to the end of the quote
				i = i + 1
				while paramStr:sub(i,i) ~= '"' do
					if paramStr:sub(i,i) == '\\' then
						i = i + 1
					end
					i = i + 1
				end
			elseif ch == ',' then
				if parcount == 0 then
					local paramvalue = paramStr:sub(last, i-1)
					paramIndex = paramIndex + 1
					paramMap[vparams[paramIndex]] = paramvalue
					last = i + 1
				end
			end
			i = i + 1
		end
		assert(parcount == 0, "macro mismatched ()'s")
		local paramvalue = paramStr:sub(last)
		paramIndex = paramIndex + 1
		local macrokey = vparams[paramIndex]
--print('substituting the '..paramIndex..'th macro from key '..tostring(macrokey)..' to value '..paramvalue)
		paramMap[macrokey] = paramvalue
	end
	
	assert(paramIndex == #vparams, "expanding macro "..key.." expected "..#vparams.." "..tolua(vparams).." params but found "..paramIndex..": "..tolua(paramMap))

	return j, k, paramMap
end

--[[
returns true if the subset of the line from [j,k] is within a string literal token
j = start index, k = end index
checkingIncludeString = set to "true" only when expanding macros of #include statement -- then we'll check for the macro within "" strings (and ignore escapes) *and* search within <> strings
--]]
local function isInString(line, j, k, checkingIncludeString)
	if k < j then error("bad string range") end
	local n = #line
	if j < 1 or k < 1 or j > n or k > n then error("string range out of bounds") end
	local i = 0
	local inquote = false
	while i <= n do
		i = i + 1
		local c = line:sub(i,i)

		if checkingIncludeString then
			-- #include string -- don't handle escapes, and optionally handle <>'s
			if not inquote then
				if c == '"'
				or c == '<'
				then
					inquote = c
				end
			elseif inquote == '"' then
				if c == '"' then
					inquote = false
				end
			elseif inquote == '<' then
				if c == '>' then
					inquote = false
				end
			end
		else
			-- C string -- handle escapes
			if not inquote then
				if c == '"' then
					inquote = true
				end
			else
				if c == '\\' then
					i = i + 1
				end
				if c == '"' then
					inquote = false
				end
			end
		end

		if i >= j and i <= k then
			if not inquote then
--print('isInString '..line..' '..j..' '..k..' : false')
				return false
			end
		end
	end
--print('isInString '..line..' '..j..' '..k..' : true')
	return true
end

--[[
argsonly = set to true to only expand macros that have arguments
useful for if evaluation
--]]
function Preproc:replaceMacros(l, macros, alsoDefined, checkingIncludeString)
	macros = macros or self.macros
	local found
	repeat
		found = nil
		-- handle builtin 'defined' first, if we are asked to
		if alsoDefined then
			local j, k, paramMap = handleMacroWithArgs(l, macros, 'defined', {'x'})
			if j then
				local query = paramMap.x
				local def = macros[query] and 1 or 0
				l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
				found = true
			else
				-- whoever made the spec for the c preprocessor ... smh
				-- here is the implicit 1 param define
				local j, k, query = l:find('defined%s+('..namepat..')')
				if j and not isInString(l, j, k, checkingIncludeString) then
					local def = macros[query] and 1 or 0
					l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
					found = true
				end
			end
		end
		-- while we're here, how about the C99 _Pragma builtin macro .... bleh
		if not found then
			local j, k, paramMap = handleMacroWithArgs(l, macros, '_Pragma', {'x'})
			if j then
				-- don't do anything with it
				-- looks like I'm not handling the # operator soon enough, and in hdf5 I'm getting
				-- _Pragma (#GCC diagnostic push)
				-- when I should be getting
				--_Pragma ("GCC diagnostic push")
				l = l:sub(1,j-1) .. ' ' .. l:sub(k+1)
				found = true
			end
		end
		if not found then
			for key,v in pairs(macros) do
				if type(v) == 'table' then
					local j, k, paramMap = handleMacroWithArgs(l, macros, key, v.params)
					if j then
--print('replacing with params', tolua(v))
						-- now replace all of v.params strings with params
						local def = self:replaceMacros(v.def, paramMap, alsoDefined)
						--[[
						TODO space or nospace?
						nospace = good for ## operator
						space = good for subsequent tokenizer after replacing A()B(), to prevent unnecessary merges
							gcc stdint.h:
							#define __GLIBC_USE(F)	__GLIBC_USE_ ## F
						I guess this is helping me make up my mind
						--]]
						local concatMarker = '$$$REMOVE_SPACES$$$'	-- something illegal / unused
						def = def:gsub('##', concatMarker)
						l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
						l = l:gsub('%s*'..string.patescape(concatMarker)..'%s*', '')
						found = true
						break
					end
				else
					local j,k = l:find(key)
					if j and not isInString(l, j, k, checkingIncludeString)  then
						-- make sure the symbol before and after is not a name character
						local before = l:sub(j-1,j-1)
						-- technically no need to match 'after' since the greedy match would have included it, right?
						-- same for 'before' ?
						local after = l:sub(k+1,k+1)
						if not before:match'[_a-zA-Z0-9]'
						and not after:match'[_a-zA-Z0-9]'
						then
--print('found macro', key)
--print('replacing with', v)
							
							-- if the macro has params then expect a parenthesis after k
							-- and replace all the instances of v's params in v'def with the values in those parenthesis

							-- also when it comes to replacing macro params, C preproc uses () counting for the replacement
							l = l:sub(1,j-1) .. v .. l:sub(k+1)
							found = true
							break
						end
					end
				end
			end
		end
	until not found
	return l
end

local function castnumber(x)
	if x == nil then return 0 end
	if x == false then return 0 end
	if x == true then return 1 end
	return (assert(tonumber(x), "couldn't cast to number: "..x))
end

-- now to evalute the tree
function Preproc:evalAST(t)
	if t[1] == 'number' then
		assert(#t == 2)
		return assert(tonumber(t[2]), "failed to parse number "..tostring(t[2]))
	elseif t[1] == '!' then
		assert(#t == 2)
		return castnumber(self:evalAST(t[2])) == 0 and 1 or 0
	elseif t[1] == '~' then
		assert(#t == 2)
		-- TODO here we are using ffi's bit lib ...
		return bit.bnot(castnumber(self:evalAST(t[2])))
	elseif t[1] == '^' then
		assert(#t == 3)
		return bit.bxor(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3])))
	elseif t[1] == '&' then
		assert(#t == 3)
		return bit.band(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '|' then
		assert(#t == 3)
		return bit.bor(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '<<' then
		assert(#t == 3)
		return bit.lshift(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '>>' then
		assert(#t == 3)
		return bit.rshift(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '+' then
		assert(#t == 2 or #t == 3)
		if #t == 3 then
			return castnumber(self:evalAST(t[2]))
				+ castnumber(self:evalAST(t[3]))
		elseif #t == 2 then
			return castnumber(self:evalAST(t[2]))
		end
	elseif t[1] == '-' then
		assert(#t == 2 or #t == 3)
		if #t == 3 then
			return castnumber(self:evalAST(t[2]))
				- castnumber(self:evalAST(t[3]))
		elseif #t == 2 then
			return -castnumber(self:evalAST(t[2]))
		end
	elseif t[1] == '*' then
		assert(#t == 3)
		return castnumber(self:evalAST(t[2]))
			* castnumber(self:evalAST(t[3]))
	elseif t[1] == '/' then
		assert(#t == 3)
		return castnumber(self:evalAST(t[2]))
			/ castnumber(self:evalAST(t[3]))
	elseif t[1] == '%' then
		assert(#t == 3)
		return castnumber(self:evalAST(t[2]))
			% castnumber(self:evalAST(t[3]))
	elseif t[1] == '&&' then
		assert(#t == 3)
		if castnumber(self:evalAST(t[2])) ~= 0
		and castnumber(self:evalAST(t[3])) ~= 0
		then
			return 1
		end
		return 0
	elseif t[1] == '||' then
		assert(#t == 3)
		if self:evalAST(t[2]) ~= 0
		or self:evalAST(t[3]) ~= 0
		then
			return 1
		end
		return 0
	elseif t[1] == '==' then
		assert(#t == 3)
		return (castnumber(self:evalAST(t[2])) == castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '>=' then
		assert(#t == 3)
		return (castnumber(self:evalAST(t[2])) >= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '<=' then
		assert(#t == 3)
		return (castnumber(self:evalAST(t[2])) <= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '!=' then
		assert(#t == 3)
		return (castnumber(self:evalAST(t[2])) ~= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '>' then
		assert(#t == 3)
		return (castnumber(self:evalAST(t[2])) > castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '<' then
		assert(#t == 3)
		return (castnumber(self:evalAST(t[2])) < castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '?' then
		assert(#t == 4)
		if castnumber(self:evalAST(t[2])) ~= 0 then
			return castnumber(self:evalAST(t[3]))
		else
			return castnumber(self:evalAST(t[4]))
		end
	else
		error("don't know how to handle this ast entry "..t[1])
	end
end


function Preproc:parseCondInt(origexpr)
	local expr = origexpr
	
	assert(expr)
	--print('evaluating condition:', expr)

	-- does defined() work with macros with args?
	-- if not then substitute macros with args here
	-- if so then substitute it in the eval of macros later ...
	expr = self:replaceMacros(expr, nil, true)
	--print('after macros:', expr)

	local col = 1
	local cond
	local rethrow
	xpcall(function()
		local function readnext(pat)
			local res = expr:sub(col):match('^'..pat)
			if res then
				col = col + #res
				return res
			end
		end

		local function skipwhitespace()
			readnext'%s*'
		end

		local ULhexpat = '0x%x+UL'
		local ULdecpat = '%d+UL'
		local hexpat = '0x%x+[LlU]?'
		local decpat = '%d+[LlU]?'

		local prev, cur
		local function next()
			skipwhitespace()
			if col > #expr then
--print('done')
				cur = ''
				return cur
			end

			for _,pat in ipairs{
				namepat,
				ULhexpat,
				ULdecpat,
				hexpat,
				decpat,
				'&&',
				'||',
				'==',
				'>=',
				'<=',
				'!=',
				'<<',
				'>>',
				'>',
				'<',
				'!',
				'&',
				'|',
				'%+',
				'%-',
				'%*',
				'/',
				'%%',
				'%^',
				'~',
				'%(',
				'%)',
				'%?',
				':',
				',',
			} do
				local symbol = readnext(pat)
				if symbol then
					cur = symbol
--print('cur', cur)
					return symbol
				end
			end

			error("couldn't understand token here: "..('%q'):format(expr:sub(col)))
		end

		next()

		local function canbe(pat)
			if cur:match('^'..pat..'$') then
				prev = cur
				next()
				return prev
			end
		end

		local function mustbe(pat)
			local this = cur
			if not canbe(pat) then error("expected "..pat.." found "..this) end
			return this
		end

		local level1

		local function level13()
			-- make sure you match hexpat first
			if canbe(ULdecpat)
			or canbe(ULhexpat)
			then
				local dec = prev:match'^(%d+)UL$'
				local val
				if dec then
					val = assert(tonumber(dec), "expected number")	-- decimal number
				else
					val = assert(tonumber(prev:match'^(0x%x+)UL$'), "expected number")	-- hex number
				end
				assert(val)
				local result = {'number', val}
--print('got', tolua(result))
				return result
			elseif canbe(hexpat)
			or canbe(decpat)
			then
				local dec = prev:match'^(%d+)[LlU]?$'
				local val
				if dec then
					val = assert(tonumber(dec), "expected number")	-- decimal number
				else
					val = assert(tonumber(prev), "expected number")	-- hex number
				end
				assert(val)
				local result = {'number', val}
--print('got', tolua(result))
				return result
			elseif canbe'%(' then
				local node = level1()
				mustbe'%)'
--print('got', tolua(result))
				return node
			
			-- have to handle 'defined' without () because it takes an implicit 1st arg
			elseif canbe'defined' then
				local name = mustbe(namepat)
				local result = {'number', castnumber(self.macros[namepat])}
--print('got', tolua(result))
				return result
			elseif canbe(namepat) then
				-- since we've already replaced all macros in the line, any unknown/remaining macro variable is going to evaluate to 0
				local result = {'number', 0}
--print('got', tolua(result))
				return result
			else
				error("failed to parse expression: "..cur)
			end
		end

		local function level12()
			if canbe'%+'
			or canbe'%-'
			or canbe'!'
			or canbe'~'
			-- prefix ++ and -- go here in C, but I'm betting not in C preprocessor ...
			then
				local op = prev
				local b = level13()
				local result = {op, b}
--print('got', tolua(result))
				return result
			end
			return level13()
		end

		local function level11()
			local a = level12()
			if canbe'%*'
			or canbe'/'
			or canbe'%%'
			then
				local op = prev
				local b = level11()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level10()
			local a = level11()
			if canbe'%+'
			or canbe'%-'
			then
				local op = prev
				local b = level10()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level9()
			local a = level10()
			if canbe'>>'
			or canbe'<<'
			then
				local op = prev
				local b = level9()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level8()
			local a = level9()
			if canbe'>='
			or canbe'<='
			or canbe'>'
			or canbe'<'
			then
				local op = prev
				local b = level8()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level7()
			local a = level8()
			if canbe'=='
			or canbe'!='
			then
				local op = prev
				local b = level7()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end
	
		local function level6()
			local a = level7()
			if canbe'&'
			then
				local op = prev
				local b = level6()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level5()
			local a = level6()
			if canbe'%^'
			then
				local op = prev
				local b = level5()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level4()
			local a = level5()
			if canbe'|'
			then
				local op = prev
				local b = level4()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level3()
			local a = level4()
			if canbe'&&'
			then
				local op = prev
				local b = level3()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local function level2()
			local a = level3()
			if canbe'||'
			then
				local op = prev
				local b = level2()
				local result = {op, a, b}
--print('got', tolua(result))
				return result
			end
			return a
		end

		level1 = function()
			local a = level2()
			if canbe'%?'
			then
				local op = prev
				local b = level1()
				mustbe':'
				local c = level1()
				local result = {op, a, b, c}
--print('got', tolua(result))
				return result
			end
			return a
		end

		local parse = level1()

--print('got expression tree', tolua(parse))

		mustbe''

		cond = self:evalAST(parse)
--print('got cond', cond)

	end, function(err)
		rethrow =
			' at col '..col..'\n'
			..' for orig expr:\n'
			..origexpr..'\n'
			..' for expr after macros:\n'
			..expr..'\n'
			..err..'\n'..debug.traceback()
	end)
	if rethrow then error(rethrow) end
	
	return cond
end

function Preproc:parseCondExpr(expr)
	return self:parseCondInt(expr) ~= 0
end

function Preproc:__call(args)
	if type(args) == 'string' then
		args = {code=args}
	elseif type(args) ~= 'table' then
		error("can't handle args")
	end

	local code = assert(args.code, "expected code")

	if args.sysIncludeDirs then
		self:addIncludeDirs(args.sysIncludeDirs, true)
	end
	if args.userIncludeDirs then
		self:addIncludeDirs(args.userIncludeDirs, false)
	end

	self.includeStack = table()

	code = removeCommentsAndApplyContinuations(code)
	local lines = string.split(code, '\n')

	if args.macros then
		self:setMacros(args.macros)
	end

	-- table of {current condition, any past if's of this block}
	local ifstack = table()
	local i = 1
	xpcall(function()
		while i <= #lines do
			local l = lines[i]
			local popInc = l:match'^/%* END (.*) %*/$'
			if popInc then
				local last = self.includeStack:remove()
				assert(last == popInc, "end of include "..popInc.." vs includeStack "..last)
			end

			-- nil = no condition present
			-- true = current condition is true
			-- false = current condition is false
			local eval = true
			if #ifstack > 0 then
				for i,b in ipairs(ifstack) do
					if b[1] == false then
						eval = false
						break
					end
				end
			end
--print('eval is', eval, 'line is', l)

			l = string.trim(l)	-- trailing space doesn't matter, right?
			if l:sub(1,1) == '#' then
				local cmd, rest = l:match'^#%s*(%S+)%s*(.-)$'
--print('cmd is', cmd, 'rest is', rest)
				
				local function closeIf()
					assert(#ifstack > 0, 'found an #'..cmd..' without an #if')
					ifstack:remove()
				end

				if cmd == 'define' then
					if eval then
						local k, params, paramdef = rest:match'^(%S+)%(([^)]*)%)%s*(.-)$'
						if k then
							assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
--print('defining with params',k,params,paramdef)
							
-- [[ what if we're defining a macro with args?
-- at this point I probably need to use a parser on #if evaluations
							local paramstr = params
							params =
								paramstr:match'^%s*$'
								and table()
								or string.split(paramstr, ','):mapi(string.trim)
							for i,param in ipairs(params) do
								assert(isvalidsymbol(param) or param == '...', "macro param #"..i.." is an invalid name: "..tostring(param))
							end
						
							self.macros[k] = {
								params = params,
								def = paramdef,
							}
								
							lines:remove(i)
							i = i - 1
						else
						
							local k, v = rest:match'^(%S+)%s+(.-)$'
							if k then
								assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
--print('defining value',k,v)
								self.macros[k] = v
							else
								local k = rest
								v = ''
								assert(k ~= '', "couldn't find what you were defining: "..l)
								assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
								
--print('defining empty',k,v)
								self.macros[k] = v
							end
						
							--if it is a number define
							local isnumber = tonumber(v)	-- TODO also check valid suffixes?
							if isnumber then
--print('line was', l)
								local oldv = self.generatedEnums[k]
								if oldv then
									if oldv ~= v then
										print('warning: redefining '..k)
									end
									lines:remove(i)
									i = i - 1
								else
									self.generatedEnums[k] = v
									l = 'enum { '..k..' = '..v..' };'
									lines[i] = l
								end
--print('line is', l)
							else
								-- macros don't get eval'd until they are used
								-- but to replace them with enums maens evaluating them immediately
								-- ... or it means saving track fo the linenos of all the original defines and then evaluating them last and going back and replacing them
								-- hmmm
								-- but for now, just replace define with enum on immediate values
								--[[
								l = "// couldn't convert "..l
								lines[i] = l
								--]]
								-- [[
								lines:remove(i)
								i = i - 1
								--]]
							end
						end
					else
						lines:remove(i)
						i = i - 1
					end
				elseif cmd == 'if'
				or cmd == 'elif'
				then
					local hasprocessed = false
					if cmd == 'elif' then
						local oldcond = ifstack:last()
						hasprocessed = oldcond[1] or oldcond[2]
						closeIf()
					end

					local cond
					if cmd == 'elif'
					and hasprocessed
					then
						cond = false
					else
						cond = self:parseCondExpr(rest)
						assert(cond ~= nil, "cond must be true or false")
					end
--print('got cond', cond, 'from', rest)
					ifstack:insert{cond, hasprocessed}
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'else' then
					local oldcond = ifstack:last()
					local hasprocessed = oldcond[1] or oldcond[2]
					assert(rest == '', "found trailing characters after "..cmd)
					ifstack[#ifstack] = {not hasprocessed, hasprocessed}
					lines:remove(i)
					i = i - 1
				elseif cmd == 'ifdef' then
--print('ifdef looking for '..rest)
					assert(isvalidsymbol(rest))
					local cond = not not self.macros[rest]
--print('got cond', cond)
					ifstack:insert{cond, false}
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'ifndef' then
--print('ifndef looking for', rest)
					assert(isvalidsymbol(rest), "tried to check ifndef a non-valid symbol "..tolua(rest))
					local cond = not self.macros[rest]
--print('got cond', cond)
					ifstack:insert{cond, false}
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'endif' then
					assert(rest == '', "found trailing characters after "..cmd)
					closeIf()
					ifHandled = nil
					lines:remove(i)
					i = i - 1
				elseif cmd == 'undef' then
					assert(isvalidsymbol(rest))
					self.macros[rest] = nil
					lines:remove(i)
					i = i - 1
				elseif cmd == 'error' then
					if eval then
						error(rest)
					end
					lines:remove(i)
					i = i - 1
				elseif cmd == 'warning' then
					if eval then
						print('warning: '..rest)
					end
					lines:remove(i)
					i = i - 1
				elseif cmd == 'include' then
					lines:remove(i)
					if eval then
						-- ok so should I be replacing macros before handling *all* preprocessor directives? I really hope not.
						rest = self:replaceMacros(rest, nil, true, true)

						local sys = true
						local fn = rest:match'^<(.*)>$'
						if not fn then
							sys = false
							fn = rest:match'^"(.*)"$'
						end
						if not fn then
							error("include expected file: "..l)
						end
					
						local search = fn
						fn = self:searchForInclude(fn, sys)
						if not fn then
							io.stderr:write('sys '..tostring(sys)..'\n')
							if sys then
								io.stderr:write('sys search paths:\n')
								io.stderr:write(self.sysIncludeDirs:concat'\n'..'\n')
							else
								io.stderr:write('user search paths:\n')
								io.stderr:write(self.userIncludeDirs:concat'\n'..'\n')
							end
							io.stderr:flush()
							error("couldn't find "..(sys and "system" or "user").." include file "..search..'\n')
						end
						if not self.alreadyIncludedFiles[fn] then
--print('include '..fn)
							lines:insert(i, '/* END '..fn..' */')
							-- at position i, insert the file
							local newcode = assert(file[fn], "couldn't find file "..fn)

							newcode = removeCommentsAndApplyContinuations(newcode)
							local newlines = string.split(newcode, '\n')
							
							while #newlines > 0 do
								lines:insert(i, newlines:remove())
							end
							
							self.includeStack:insert(fn)
							lines:insert(i, '/* BEGIN '..fn..' */')
							i=i+1	-- don't process the BEGIN comment ... I guess we'll still hit the END comment ... 
						end
					end
					i = i - 1
				elseif cmd == 'include_next' then
					lines:remove(i)
					if eval then
						-- ok so should I be replacing macros before handling *all* preprocessor directives? I really hope not.
						rest = self:replaceMacros(rest, nil, true, true)

						-- same as include .. except use the *next* search path for this file
						local sys = true
						local fn = rest:match'^<(.*)>$'
						if not fn then
							sys = false
							fn = rest:match'^"(.*)"$'
						end
						if not fn then
							error("include expected file: "..l)
						end
					
						local search = fn
--print('include_next search fn='..tostring(fn)..' sys='..tostring(sys))
						-- search through the include stack for the most recent file with the name of what we're looking for ...
						local foundPrevIncludeDir
						for i=#self.includeStack,1,-1 do
							local includeNextFile = self.includeStack[i]
							local dir, prevfn = io.getfiledir(includeNextFile)
--print(includeNextFile, dir, prevfn)
							if prevfn == fn then
								foundPrevIncludeDir = dir
								break
							end
						end
--print('foundPrevIncludeDir '..tostring(foundPrevIncludeDir))
						-- and if we didn't find it, just use nil, and searchForInclude will do a regular search and get the first option
						fn = self:searchForInclude(fn, sys, foundPrevIncludeDir)
						
						if not fn then
							io.stderr:write('sys '..tostring(sys)..'\n')
							if sys then
								io.stderr:write('sys search paths:\n')
								io.stderr:write(self.sysIncludeDirs:concat'\n'..'\n')
							else
								io.stderr:write('user search paths:\n')
								io.stderr:write(self.userIncludeDirs:concat'\n'..'\n')
							end
							io.stderr:flush()
							error("couldn't find include file "..search..'\n')
						end
						if not self.alreadyIncludedFiles[fn] then
--print('include_next '..fn)
							lines:insert(i, '/* END '..fn..' */')
							-- at position i, insert the file
							local newcode = assert(file[fn], "couldn't find file "..fn)

							newcode = removeCommentsAndApplyContinuations(newcode)
							local newlines = string.split(newcode, '\n')
							
							while #newlines > 0 do
								lines:insert(i, newlines:remove())
							end
						
							self.includeStack:insert(fn)
							lines:insert(i, '/* BEGIN '..fn..' */')
							i=i+1	-- don't process the BEGIN comment ... I guess we'll still hit the END comment ... 
						end
					end
					i = i - 1
			
				elseif cmd == 'pragma' then
					if eval then
						if rest == 'once' then
							-- if we #pragma once on a non-included file then nobody cares
							if #self.includeStack > 0 then
								local last = self.includeStack:last()
								self.alreadyIncludedFiles[last] = true
							end
						end
					end
					lines:remove(i)
					i = i - 1
				else
					error("can't handle that preprocessor yet: "..l)
				end
			else
				if eval == false then
					lines:remove(i)
					i = i - 1
				else
					local nl = self:replaceMacros(l)
					if l ~= nl then
--print('line was', l)
						lines[i] = nl
--print('line is', l)
					end
				end
			end
			i = i + 1
		end
	end, function(err)
		print(require 'template.showcode'(lines:sub(1, i+10):concat'\n'))
		-- TODO lines should hold the line, the orig line no, and the inc file
		for _,inc in ipairs(self.includeStack) do
			print(' at '..inc)
		end
		print('at line: '..i)
		print('macros: '..tolua(self.macros))
		print(err..'\n'..debug.traceback())
		os.exit(1)
	end)

	-- remove empty lines
	lines = lines:filter(function(l)
		return l:match'%S'
	end)
	-- remove \r's
	lines = lines:mapi(function(l)
		return string.trim(l)
	end)

	-- join lines that don't end in a semicolon or comment
	for i=#lines,1,-1 do
		if lines[i]:sub(-1) ~= ';'
		and lines[i]:sub(-2) ~= '*/'
		and (i == #lines or lines[i+1]:sub(1,2) ~= '/*')
		then
			lines[i] = lines[i] .. ' ' .. lines:remove(i+1)
		end
	end

	code = lines:concat'\n'

	

	self.code = code
	return code
end

function Preproc:__tostring()
	return self.code
end

function Preproc.__concat(a,b)
	return tostring(a) .. tostring(b)
end

return Preproc
