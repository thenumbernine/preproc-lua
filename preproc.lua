local string = require 'ext.string'
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local path = require 'ext.path'
local class = require 'ext.class'

local namepat = '[_%a][_%w]*'

local function isvalidsymbol(s)
	return not not s:match('^'..namepat..'$')
end

local Preproc = class()

--static method
function Preproc.removeCommentsAndApplyContinuations(code)

	-- dos -> unix file format ... always?
	-- what about just \r's?
	code = code:gsub('\r\n', '\n')

	-- should line continuations \ affect single-line comments?
	-- if so then do this here
	-- or should they not?  then do this after.
	repeat
		local i, j = code:find('\\\n')
		if not i then break end
--print('was', tolua(code))
		code = code:sub(1,i-1)..' '..code:sub(j+1)
--print('is', tolua(code))
	until false

	-- remove all /* */ blocks first
	repeat
		local i = code:find('/*',1,true)
		if not i then break end
		local j = code:find('*/',i+2,true)
		if not j then
			error("found /* with no */")
		end
--print('was', tolua(code))
		code = code:sub(1,i-1)..code:sub(j+2)
--print('is', tolua(code))
	until false

	-- [[ remove all // \n blocks first
	repeat
		local i = code:find('//',1,true)
		if not i then break end
		local j = code:find('\n',i+2,true) or #code
--print('was', tolua(code))
		code = code:sub(1,i-1)..code:sub(j)
--print('is', tolua(code))
	until false
	--]]

	return code
end


-- whether, as a final pass, we combine non-semicolon lines
Preproc.joinNonSemicolonLines = true

--[[
Preproc(code)
Preproc(args)
args = table of:
	code = code to use
	sysIncludeDirs = include directories to use for <>
	userIncludeDirs = include directories to use for ""
	macros = macros to use
--]]
function Preproc:init(args)
	self.macros = {}

	self.alreadyIncludedFiles = {}

	self.sysIncludeDirs = table()
	self.userIncludeDirs = table()

	self.generatedEnums = {}

	-- builtin/default macros?
	-- here's some for gcc:
	-- TODO move these to outside preproc?
	self:setMacros{
		__restrict = '',
		__restrict__ = '',
	}

	-- the INCLUDE env var is for <> and not "", right?
	-- not showing up at all in linux 'g++ -xc++ -E -v - < /dev/null' ...
	-- maybe it's just for make?
	-- yup, and make puts INCLUDE as a <> search folder
	local incenv = os.getenv'INCLUDE'
	if incenv then
		self:addIncludeDirs(string.split(incenv, ';'), true)
	end

	if args ~= nil and (type(args) == 'string' or args.code) then
		self(args)
	end
end

function Preproc:getIncludeFileCode(fn, search, sys)
	-- at position i, insert the file
	return assert(path(fn):read(), "couldn't find file "..(
		sys and ('<'..fn..'>') or ('"'..fn..'"')
	))
end

function Preproc:getDefineCode(k, v, l)
--print('getDefineCode setting '..k..' to '..tolua(v))
	self.macros[k] = v
	
	if type(v) == 'string' then	-- exclude the arg-based macros from this -- they will have table values
		
		-- try to evaluate the value
		-- TODO will this mess with incomplete macros
		--v = self:replaceMacros(v)
	
		-- ok if it's a preprocessor expression then we need it evaluated
		-- but it could be a non-preproc expression as well, in which case maybe it's a float?
		local origv = v
		pcall(function()
			v = ''..self:parseCondInt(v)
			-- parseCondExpr returns bool
		end)

		-- if the value string is a number define
		local isnumber = tonumber(v)	-- TODO also check valid suffixes? l L etc
		if isnumber then
			-- ok Lua tonumber hack ...
			-- tonumber'0x10' converts from base 16 ..
			-- tonumber'010' converts from base 10 *NOT* base 8 ...
--print('line was', l)
			local replaceline
			
			local oldv = self.generatedEnums[k]
			if oldv then
				if oldv ~= v then
					print('/* WARNING: redefining '..k..' from '..tostring(oldv)..' to '..tostring(v).. ' (originally '..tostring(origv)..') */')
					-- redefine the enum value as well?
					-- I think in the macro world doing a #define a 1 #define a 2 will get a == 2, albeit with a warning.
				
					replaceline = true
				else
					return '/* redefining matching value: '..l..' */'
				end
			else
				replaceline = true
			end
			self.generatedEnums[k] = v
		
			if replaceline then
				assert(type(v) == 'string')
				-- [[ insert in-place? this will cause a luajit error
				if not v:match'%.'		-- no floats
				and not v:match'%de[+-]%d'	-- no exps
				then
					return 'enum { '..k..' = '..v..' };'
				else
					return '/* '..l..' ### string, number, replaceline '..tolua(v)..' */'
				end
				--]]
			else
				return '/* '..l..' ### string, number, not replaceline '..tolua(v)..' */'
			end
		else
			-- string but not number ...
			if v == '' then
				return 'enum { '..k..' = 1 };'
			else
				return '/* '..l..' ### string, not number '..tolua(v)..' */'
			end
		end
	-- otherwise if not a string then it's a macro with args or nil
	else
-- non-strings are most likely nil for undef or tables for arg macros
--		return '/* '..l..' ### '..tolua(v, {indent=false})..' */'
	end
		
	return ''
end

-- external API.  internal should use 'getDefineCode' for codegen
function Preproc:setMacros(args)
	--[[
	for k,v in pairs(args) do
	--]]
	-- [[
	for _,k in ipairs(table.keys(args):sort()) do
		local v = args[k]
	--]]
--print('setMacros setting '..k..' to '..tolua(v))
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
		if path(p):exists() then
			return p
		end
	end
end

function Preproc:handleMacroWithArgs(l, key, vparams)
	-- TODO multiline support
	-- look for 'key' whatsoever
	-- if we find it then switch to start expecting that opening parenthesis
	-- and then tokenize or something.

	local keyj,keyk = l:find(key)
	if not keyj then return end
	
	local beforekey = l:sub(keyj-1,keyj-1)
	local afterkey = l:sub(keyk+1,keyk+1)
	if beforekey:match'[_a-zA-Z0-9]'
	or afterkey:match'[_a-zA-Z0-9]'
	then
		--[[
		-- not a proper key , just a substring of one
		-- TODO won't this skip some macros .. like if we have
#define ABC ( x )
#define EDABC ( x )
		and then we do
EDABC(x)
		--]]
		return
	end

	local pat = key..'%s*(%b())'
	local j,k = l:find(pat)
	 -- if we found KEY
	 -- but not KEY( ... )
	 -- but we did find KEY(
	 -- then ...
	if not j then

		-- because 'defined' is special, skip it, and I guess hope nobody has its arg on a newline (what a mess)
		if key ~= 'defined' then
			if l:find(key..'%s*%(') then
				--print("/* ### INCOMPLETE ARG MACRO ### "..key..' ### IN LINE ### '..l..' */')
				self.foundIncompleteMacroWarningMessage = "/* ### INCOMPLETE ARG MACRO ### "..key
					..' ### IN LINE ### '
					..l:gsub('/%*', '/ *'):gsub('%*/', '* /')
					..' */'
				-- ok in this case, how about we store the previous line
				-- and then include it when processing macros the next time around?
				-- seems like a horrible hack
				-- just use a tokenizer or something
				self.foundIncompleteMacroLine = l
			end
		end

		return
	end

	local before = l:sub(j-1,j-1)
	if before:match'[_a-zA-Z0-9]' then
		return
	end

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

local function overlaps(a, b)
	return a[1] <= b[2] and b[1] <= a[2]
end

--[[
argsonly = set to true to only expand macros that have arguments
useful for if evaluation

TODO THIS NEEDS TO HAVE STATE
in the latest stdio.h there is a multiple-line-spanning-macro, so I can't get around it any more

and that also might mean I need a tokenizer of some sort, to know when the parenthesis arguments begin and end
--]]
function Preproc:replaceMacros(l, macros, alsoDefined, checkingIncludeString)
--print('replaceMacros begin: '..l)
	macros = macros or self.macros
	-- avoid infinite-recursive macros
	local alreadyReplaced = {}
	local found
	repeat
		found = nil
		-- handle builtin 'defined' first, if we are asked to
		if alsoDefined then
			local j, k, paramMap = self:handleMacroWithArgs(l, 'defined', {'x'})
			if j then
				local query = paramMap.x
--print('defined() querying '..query)
				local def = macros[query] and 1 or 0
--print('self.macros[query] = '..tolua(self.macros[query]))
--print('macros[query] = '..def)
--local oldl = l
				l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
--print('from', oldl, 'to', l)
				found = true
			else
				-- whoever made the spec for the c preprocessor ... smh
				-- here is the implicit 1 param define
				local j, k, query = l:find('defined%s+('..namepat..')')
				if j and not isInString(l, j, k, checkingIncludeString) then
					local def = macros[query] and 1 or 0
--local oldl = l
					l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
--print('from', oldl, 'to', l)
					found = true
				end
			end
		end
		-- while we're here, how about the C99 _Pragma builtin macro .... bleh
		if not found then
			local j, k, paramMap = self:handleMacroWithArgs(l, '_Pragma', {'x'})
			if j then
				-- don't do anything with it
				-- looks like I'm not handling the # operator soon enough, and in hdf5 I'm getting
				-- _Pragma (#GCC diagnostic push)
				-- when I should be getting
				--_Pragma ("GCC diagnostic push")
--local oldl = l
				l = l:sub(1,j-1) .. ' ' .. l:sub(k+1)
--print('from', oldl, 'to', l)
				found = true
			end
		end
		if not found then
			--[[
			for key,v in pairs(macros) do
			--]]
			-- [[
			for _,key in ipairs(table.keys(macros):sort()) do
				do--if not alreadyReplaced[key] then
					local v = macros[key]
				--]]

					-- handle macro with args
					if type(v) == 'table' then
						local j, k, paramMap = self:handleMacroWithArgs(l, key, v.params)
						if j then
							if alreadyReplaced[key]
							and overlaps(alreadyReplaced[key], {j,k})
							then
--print('...but its in a previously-recursively-expanded location')
							else
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
								local origl = l
								l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
								l = l:gsub('%s*'..string.patescape(concatMarker)..'%s*', '')
--print('from', origl, 'to', l)
								-- sometimes you get #define x x ... which wants you to keep the original and not replace forever
								if l ~= origl then
									found = true
								end
								break
							end
						end
					else
						local j,k
						k = 0
						while true do
							j = k+1
							-- handle macro without args
							j,k = l:find(key,j)
							if not j then break end
							if not isInString(l, j, k, checkingIncludeString)  then
								-- make sure the symbol before and after is not a name character
								local before = l:sub(j-1,j-1)
								-- technically no need to match 'after' since the greedy match would have included it, right?
								-- same for 'before' ?
								local after = l:sub(k+1,k+1)
								if not before:match'[_a-zA-Z0-9]'
								and not after:match'[_a-zA-Z0-9]'
								then
--print('found macro', key)
									if alreadyReplaced[key]
									and overlaps(alreadyReplaced[key], {j,k})
									then
--print('...but its in a previously-recursively-expanded location')
										-- don't expand
									else
--print('replacing with', v)
										-- if the macro has params then expect a parenthesis after k
										-- and replace all the instances of v's params in v'def with the values in those parenthesis

										-- also when it comes to replacing macro params, C preproc uses () counting for the replacement
--local origl = l
										l = l:sub(1,j-1) .. v .. l:sub(k+1)
--print('from', origl, 'to', l)
										-- sometimes you get #define x x ... which wants you to keep the original and not replace forever
										if l ~= origl then
											found = true
										end
										-- but this won't stop if you have #define x A.x ... in which case you could still get stuck in a loop
										-- instead I gotta make it so it just doesn't expand a second time
										-- TODO do this for parameter-based macros also? #define x(y) A.x(y+1) ?
										--
										-- ok this is causing trouble with expressions, because it's preventing multiple expressions of the same macro from being expanded.
										-- which makes me suspicious maybe I have to evaluate expressions macro-at-a-time?  but that means buliding a giant macro-dependency graph?
										-- so I really only want to do this in self-referencing macros
										--
										-- so really we want to only not twice replace in the string region that the first macro expanded ....
										-- ... smh
										alreadyReplaced[key] = {j, j+#v-1}
										break
									end
								end
							end
						end
					end
				end
			end
		end
	until not found
--print('replaceMacros done: '..l)
	return l
end

local function cliteralintegertonumber(x)
	-- ok Lua tonumber hack ...
	-- tonumber'0x10' converts from base 16 ..
	-- tonumber'010' converts from base 10 *NOT* base 8 ...
	-- and because now i'm using macro-evaluation to convert my #define's into enum {} 's ...
	-- it's important here
	local n = tonumber(x)
	if not n then return nil end
	-- if it's really base 8 then lua will interpret it (successfully) as base-10
	if type(x) == 'string'
	and x:match'^0%d'
	then
		n = tonumber(x, 8)
	end
	return n
end

local function castnumber(x)
	if x == nil then return 0 end
	if x == false then return 0 end
	if x == true then return 1 end
	local n = cliteralintegertonumber(x)
	if not n then error("couldn't cast to number: "..x) end
	return n
end

-- now to evalute the tree
function Preproc:evalAST(t)
	if t[1] == 'number' then
		assert(#t == 2)
		return assert(cliteralintegertonumber(t[2]), "failed to parse number "..tostring(t[2]))
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
		local LLhexpat = '0x%x+LL'
		local LLdecpat = '%d+LL'
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
				LLhexpat,
				LLdecpat,
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
					val = assert(cliteralintegertonumber(dec), "expected number")	-- decimal number
				else
					val = assert(cliteralintegertonumber(prev:match'^(0x%x+)UL$'), "expected number")	-- hex number
				end
				assert(val)
				local result = {'number', val}
--print('got', tolua(result))
				return result
			elseif canbe(LLdecpat)
			or canbe(LLhexpat)
			then
				local dec = prev:match'^(%d+)LL$'
				local val
				if dec then
					val = assert(cliteralintegertonumber(dec), "expected number")	-- decimal number
				else
					val = assert(cliteralintegertonumber(prev:match'^(0x%x+)LL$'), "expected number")	-- hex number
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
					val = assert(cliteralintegertonumber(dec), "expected number")	-- decimal number
				else
					val = cliteralintegertonumber(prev:match'^(0x%x+)[LlU]?$')
					if not val then
						error("expected number from "..prev)	-- hex number
					end
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

	code = Preproc.removeCommentsAndApplyContinuations(code)
	local lines = string.split(code, '\n')

	if args.macros then
		self:setMacros(args.macros)
	end

	-- table of {current condition, any past if's of this block}
	local ifstack = table()
	local i = 1
	local throwme
	xpcall(function()
		while i <= #lines do
			local l = lines[i]
			local popInc = l:match'^/%* %+* END   (.*) %*/$'
			if popInc then
				local last = self.includeStack:remove()
-- TODO in my nested include() this is getting broken
				assert(last == popInc, "end of include "..popInc.." vs includeStack "..tolua(last))
			else
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

				local preveval = true
				if #ifstack > 0 then
					for i=1,#ifstack-1 do
						if ifstack[i][1] == false then
							preveval = false
							break
						end
					end
				end
--print('line is', l, 'eval is', eval, 'preveval is', preveval)

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
							
								lines[i] = self:getDefineCode(k, {
									params = params,
									def = paramdef,
								}, l)
							else
							
								local k, v = rest:match'^(%S+)%s+(.-)$'
								if k then
									assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
--print('defining value',k,v)
									-- [[ evaluate macros of v?
									-- and skip previous lines
									self.foundIncompleteMacroWarningMessage = nil
									--v = self:replaceMacros(v)
									-- no, that'll be done in getDefineCode (right?()
									--]]
								else
									k = rest
									v = ''
									assert(k ~= '', "couldn't find what you were defining: "..l)
									assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
--print('defining empty',k,v)
								end
								
								--TODO lines[i] = ...
								-- and then incorporate the enim {} into the code
								lines[i] = self:getDefineCode(k, v, l)
--print('line is', l)
							end
						else
							lines:remove(i)
							i = i - 1
						end
					elseif cmd == 'if'
					or cmd == 'elif'
					then
--print('if/elif with eval', eval, 'preveval', preveval)
						local hasprocessed = false
						if cmd == 'elif' then
--print('closing via elif, #ifstack', require'ext.tolua'(ifstack))
							local oldcond = ifstack:last()
							hasprocessed = oldcond[1] or oldcond[2]
							closeIf()
						end

--print('hasprocessed', hasprocessed)
						local cond
						if cmd == 'elif'
						and hasprocessed
						then
							cond = false
						else
							-- only parse the condition if we're evaluating this #if block
							-- otherwise the cond could have macros that aren't defined yet
							-- if we just give the cond a false value it won't matter -- the whole block is being skipped anyways
							-- NOTICE
							-- 'eval' is the previous #if/#elif 's evaluation
							-- because it was evaluated before the #elif, for #elif it'll include the latest #if's cond as well
							-- 'preveval' is the wrapping block's eval
							if (cmd == 'elif' and not preveval)
							or (cmd == 'if' and not eval)
							then
--print('elif skipping cond evaluation')
								cond = false
							else
								cond = self:parseCondExpr(rest)
								assert(cond ~= nil, "cond must be true or false")
							end
						end
--print('got cond', cond, 'from', rest)
						ifstack:insert{cond, hasprocessed}
						
						lines:remove(i)
						i = i - 1
					elseif cmd == 'else' then
						assert(#ifstack > 0, "found an #else without an #if")
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
						if eval then
							--[[
							self.macros[rest] = nil
							lines:remove(i)
							i = i - 1
							--]]
							-- [[
							lines[i] = self:getDefineCode(rest, nil, l)
							--]]
						else
							lines:remove(i)
							i = i - 1
						end
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
							-- TODO there are some lines that are #include MACRO ... but if it's within a string then no, dont replace macros.
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
								lines:insert(i, '/* '..('+'):rep(#self.includeStack+1)..' END   '..fn..' */')
								
								
								-- TODO not sure how I want to do this
								-- but I want my include-lua project to be able to process certain dependent headers in advance
								-- though not all ... only ones that are not dependent on the current preproc state (i.e. the system files)
								-- so this is a delicate mess.
								local newcode = self:getIncludeFileCode(fn, search, sys)
								
								newcode = Preproc.removeCommentsAndApplyContinuations(newcode)
								local newlines = string.split(newcode, '\n')
								
								while #newlines > 0 do
									lines:insert(i, newlines:remove())
								end
								
								self.includeStack:insert(fn)
								lines:insert(i, '/* '..('+'):rep(#self.includeStack)..' BEGIN '..fn..' */')
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
								local dir, prevfn = path(includeNextFile):getdir()
--print(includeNextFile, dir, prevfn)
								if prevfn == fn then
									foundPrevIncludeDir = dir.path
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
								lines:insert(i, '/* '..('+'):rep(#self.includeStack+1)..' END   '..fn..' */')
								-- at position i, insert the file
								local newcode = assert(path(fn):read(), "couldn't find file "..fn)

								newcode = Preproc.removeCommentsAndApplyContinuations(newcode)
								local newlines = string.split(newcode, '\n')
								
								while #newlines > 0 do
									lines:insert(i, newlines:remove())
								end
							
								self.includeStack:insert(fn)
								lines:insert(i, '/* '..('+'):rep(#self.includeStack)..' BEGIN '..fn..' */')
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
								lines:remove(i)
								i = i - 1
							else
								lines[i] = '/* '..lines[i]..' */'
							end
						else
							lines:remove(i)
							i = i - 1
						end
					elseif cmd == '_Replacement' then
						-- msvc macro
					else
						error("can't handle that preprocessor yet: "..l)
					end
				else
					if eval == false then
						lines:remove(i)
						i = i - 1
					else
	-- [[ or should I just store lines for now, eval later (so that macro arguments can span multiple lines)
	-- no ... because macros have state via #define and #undef, so you must evaluate them now
	-- but then how does C handle
	-- 	#define M(a,b,c)
	--	M(a
	--  #undef M
	--		, b, c)

						local prevIncompleteMacroLine = self.foundIncompleteMacroLine
						self.foundIncompleteMacroLine = nil
						local origl = l
						if prevIncompleteMacroLine then
							--print('/* ### PREPENDING ### ' .. prevIncompleteMacroLine .. ' ### TO ### ' .. l..' */')
							lines:insert(i, '/* ### PREPENDING ### '
								..prevIncompleteMacroLine:gsub('/%*', '/ *'):gsub('%*/', '* /')
								.. ' ### TO ### '
								..l:gsub('/%*', '/ *'):gsub('%*/', '* /')
								..' */')
							i = i + 1
							l = prevIncompleteMacroLine .. ' ' .. l
						end
						
						local nl = self:replaceMacros(l)
						if self.foundIncompleteMacroLine then
							--print("/* ### INCOMPLETE ARG MACRO ### "..key..' ### IN LINE ### '..l..' */')
							lines:insert(i, self.foundIncompleteMacroWarningMessage)
							self.foundIncompleteMacroWarningMessage = nil
							i = i + 1

							--[[
							lines[i] = '/* '..lines[i]..' */'
							i = i + 1
							--]]
							--[[
							lines:remove(i)
							i = i - 1
							--]]
						end

						if origl ~= nl then
--print('line was', l)
							lines[i] = nl
--print('line is', l)
						end
						if self.foundIncompleteMacroLine then
							lines:remove(i)
							i = i - 1
						end
	--]]
					end
				end
			end
			i = i + 1
		end
	end, function(err)
		throwme = table()
		throwme:insert(require 'template.showcode'(lines:sub(1, i+10):concat'\n'))
		-- TODO lines should hold the line, the orig line no, and the inc file
		for _,inc in ipairs(self.includeStack) do
			throwme:insert(' at '..inc)
		end
		throwme:insert('at line: '..i)
		throwme:insert('macros: '..tolua(self.macros))
		throwme:insert(err..'\n'..debug.traceback())
		throwme = throwme:concat'\n'
	end)
	if throwme then
		error(throwme)
	end

	-- remove \r's
	lines = lines:mapi(function(l)
		return string.trim(l)
	end)
	-- remove empty lines
	lines = lines:filter(function(l)
		return l ~= ''
	end)

	-- merge all into one string
	-- then replace all on the whole string
	-- TODO should I worry about #include injection of code and macro args order of evaluation
	--[[
	io.stderr:write('begin replacing ', self.includeStack:last() or 'nil', '\n')
	io.stderr:flush()
	lines = string.split(self:replaceMacros(lines:concat'\n'), '\n')
	io.stderr:write'done replacing\n'
	io.stderr:flush()
	--]]

	-- [[ join lines that don't end in a semicolon or comment
	if self.joinNonSemicolonLines then
		for i=#lines,1,-1 do
			if lines[i]:sub(-2) ~= '*/' then
				lines[i] = lines[i]:gsub('%s+', ' ')
				if lines[i]:sub(-1) ~= ';'
				and (i == #lines or lines[i+1]:sub(1,2) ~= '/*')
				then
					lines[i] = lines[i] .. ' ' .. lines:remove(i+1)
				end
				lines[i] = lines[i]:gsub('%s*;$', ';')
			end
		end
	end
	--]]

	--[[ prepend enums / define's to the beginning
	for _,k in ipairs(table.keys(self.generatedEnums):sort()) do
		local v = self.generatedEnums[k]
		lines:insert(1, 'enum { '..k..' = '..v..' };')
	end
	--]]

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
