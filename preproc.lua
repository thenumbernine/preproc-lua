--[[

I'm currently breaking everything
1) merge the preproic expr prarser with the noew entre preproc parser
2) dont use its ast, instead eval as you go and replace the preproc parser stack values
3) replace the foundIncompleteMacroLine line with just keep the parser parsing
4) hoepfully handle #'s and ##'s while parsing
5) parse parse parse parse parse
--]]
local assert = require 'ext.assert'
local string = require 'ext.string'
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local path = require 'ext.path'
local class = require 'ext.class'
local bit = require 'bit'			-- either luajit's, or my vanilla Lua compat wrapper lib ...

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
--DEBUG(removeCommentsAndApplyContinuations): print('was', tolua(code))
		code = code:sub(1,i-1)..' '..code:sub(j+1)
--DEBUG(removeCommentsAndApplyContinuations): print('is', tolua(code))
	until false

	-- remove all /* */ blocks first
	repeat
		local i = code:find('/*',1,true)
		if not i then break end
		local j = code:find('*/',i+2,true)
		if not j then
			error("found /* with no */")
		end
--DEBUG(removeCommentsAndApplyContinuations): print('was', tolua(code))
		code = code:sub(1,i-1)..code:sub(j+2)
--DEBUG(removeCommentsAndApplyContinuations): print('is', tolua(code))
	until false

	-- [[ remove all // \n blocks first
	repeat
		local i = code:find('//',1,true)
		if not i then break end
		local j = code:find('\n',i+2,true) or #code
--DEBUG(removeCommentsAndApplyContinuations): print('was', tolua(code))
		code = code:sub(1,i-1)..code:sub(j)
--DEBUG(removeCommentsAndApplyContinuations): print('is', tolua(code))
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
--DEBUG(Preproc:getDefineCode): print('getDefineCode setting '..k..' to '..tolua(v))
	self.macros[k] = v
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
--DEBUG(Preproc:setMacros): print('setMacros setting '..k..' to '..tolua(v))
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
--DEBUG(Preproc:searchForInclude): print('searching '..tolua(includeDirs))
--DEBUG(Preproc:searchForInclude): print('search starting '..tostring(startHere))
		startHere = startHere:match'^(.-)/*$'	-- remove trailing /'s
		for i=1,#includeDirs do
			local dir = includeDirs[i]:match'^(.-)/*$'
--DEBUG(Preproc:searchForInclude): print("does "..tostring(startHere).." match "..tostring(dir).." ? "..tostring(dir == startHere))
			if dir == startHere then
				startIndex = i+1
				break
			end
		end
--DEBUG(Preproc:searchForInclude): print('startIndex '..tostring(startIndex))
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

-- largest to smalleste
local cSymbols = table{
	'...',
	'&&',
	'||',
	'==',
	'>=',
	'<=',
	'!=',
	'<<',
	'>>',
	'->',
	'##',
	'++',
	'--',
	'>',
	'<',
	'!',
	'&',
	'|',
	'+',
	'-',
	'*',
	'/',
	'%',
	'^',
	'~',
	'(',
	')',
	'?',
	':',	-- is there a need to parse :: separately? for C++?  nah, not for the preprocessor's expressions.
	',',
	'=',
	';',
	'#',
	'.',
	'[',
	']',
	'{',
	'}',
}:sort(function(a,b) return #a > #b end)
local cSymbolSet = cSymbols:mapi(function(c) return true, c end):setmetatable(nil)
local cSymbolEscs = cSymbols:mapi(function(c) return '^'..string.patescape(c) end)

local function gettokentype(s, i)
	i = i or 1
	local tokentype, ti1, ti2
	if s:find('^[_%a]', i) then
		-- if we start as a word then read a word
		ti1, ti2 = s:find('^[_%a][_%w]*', i)
		tokentype = 'name'
	elseif s:find('^%d', i) then
		-- TODO if you find a digit then go on to handle any suffix and then validate it later
		if not ti1 then
			ti1, ti2 = s:find('^0[Xx]%x+[Uu][Ll][Ll]', i)	-- ULL hex
		end
		if not ti1 then
			ti1, ti2 = s:find('^%d+[Uu][Ll][Ll]', i)	-- ULL dec
		end
		if not ti1 then
			ti1, ti2 = s:find('^0[Xx]%x+[Uu][Ll]', i)	-- UL hex
		end
		if not ti1 then
			ti1, ti2 = s:find('^%d+[Uu][Ll]', i)	-- UL dec
		end
		if not ti1 then
			ti1, ti2 = s:find('^0[Xx]%x+[Ll][Ll]', i) -- LL hex
		end
		if not ti1 then
			ti1, ti2 = s:find('^%d+[Ll][Ll]', i)	-- LL dec
		end
		if not ti1 then
			ti1, ti2 = s:find('^0[Xx]%x+[LlUu]?', i)	-- U/L hex
		end
		if not ti1 then
			ti1, ti2 = s:find('^%d+[LlUu]?', i)		-- U/L dec
		end
		-- how about floats and [eE]+ stuff?

		--ti1, ti2 = s:find('^%d[%w]*', i)	-- if we start as a number then read numbers
		tokentype = 'number'
	elseif s:find("^'", i) then
		ti1 = i
		ti2 = ti1 + 1
		if s:sub(ti2, ti2) == '\\' then ti2 = ti2 + 1 end
		ti2 = ti2 + 1
		assert.eq(s:sub(ti2, ti2), "'", 'at line '..s)
		tokentype = 'char'
	elseif s:find('^"', i) then
		-- read string ... ugly
		ti1 = i
		ti2 = i
		while true do
			ti2 = ti2 + 1
			if s:sub(ti2, ti2) == '\\' then
				ti2 = ti2 + 1
			elseif s:sub(ti2, ti2) == '"' then
				break
			end
		end
		tokentype = 'string'
	else
		-- see if it's a symbol, searching biggest to smallest
		for k,esc in ipairs(cSymbolEscs) do
			ti1, ti2 = s:find(esc, i)
			if ti1 then break end
		end
		assert(ti1, "failed to find any valid symbols at "..s:sub(i, i+20))
		tokentype = 'symbol'
	end
	return tokentype, ti1, ti2
end

local Reader = class()
function Reader:init(data)
	self:resetData(data)
end
function Reader:resetData(data)
	self.stack = setmetatable({}, {
		__index = function(t,k)
			if type(k) == 'number' and k < 0 then k = k + #self + 1 end
			local v = rawget(self, k)
			if v == nil then v = table[k] end
			return v
		end,
		__newindex = function(t,k,v)
			if type(k) == 'number' and k < 0 then k = k + #self + 1 end
			rawset(self, k, v)
		end,
	})
	-- each entry holds .token, .type, .space
	self:setData(data)
end
function Reader:setData(data)
	self.data = data
	self.index = 1
	self:next()		-- prep next symbol as top
end

function Reader:next()
--DEBUG:print'Reader:next()'
	if self.index > #self.data then
		if #self.stack == 0
		or self.stack:last().type ~= 'done'
		then
--DEBUG:print'...inserting type=done'
			self.stack:insert{token='', type='done', space=''}
		end
--DEBUG:print'...done'
		return '', 'done', ''
	end

	local si1, si2 = self.data:find('^%s*', self.index)
assert(si1)
	local space = self.data:sub(si1, si2)
	self.index = si2 + 1

	local tokentype, ti1, ti2 = gettokentype(self.data, self.index)
if not ti1 then error("failed to match at "..self.data:sub(self.index, self.index+20)) end
	local token = self.data:sub(ti1, ti2)
	self.index = ti2 + 1
	self.stack:insert{token=token, type=tokentype, space=space}
--DEBUG:print('...next got', tolua{token=token, type=tokentype, space=space})
	return token, tokentype, space
end

function Reader:canbe(token)
	local last = self.stack:last()
	if token == last.token then
		self:next()
		return last.token
	end
end

function Reader:mustbe(token)
	return assert(self:canbe(token))
end

function Reader:canbetype(tokentype)
	local last = self.stack:last()
	if tokentype == last.type then
		self:next()
		return last.token
	end
end

function Reader:mustbetype(tokentype)
	return assert(self:canbetype(tokentype))
end

-- concats the currently-unprocessed top-of-stack with the rest of the data
function Reader:whatsLeft()
	return self.stack:last().token..self.data:sub(self.index)
end

local function determineSpace(prevEntry, thisEntry)
	local space = ''
	if prevEntry then
		if (thisEntry.type == 'name' or thisEntry.type == 'number')
		and (prevEntry.type == 'name' or prevEntry.type == 'number')
		then
			-- if the neighboring token types don't play well then put a space
			space = ' '
		else
			-- if merging makes another valid token then put a space
			if cSymbolSet[prevEntry.token..thisEntry.token] then
				space = ' '
			end
		end
	end
	return space
end

-- lastToken = stack[] entry underneath where it's going
-- determines token type and determines what kind of space to use
function makeTokenEntry(token, lastTokenStackEntry)
assert.type(token, 'string')
if lastTokenStackEntry ~= nil then assert.type(lastTokenStackEntry, 'table') end
	local tokentype = gettokentype(token)
	local newStackEntry = {token=token, type=tokentype}
	newStackEntry.space = determineSpace(lastTokenStackEntry, newStackEntry)
	return newStackEntry
end

function Reader:setStackToken(loc, token)
assert.type(loc, 'number')
assert.type(token, 'string')
	--[[ TODO. This isn't working.  but I need it to work to remove spaces between symbols and numbers etc.
	local thisEntry = makeTokenEntry(token, self.stack[loc-1])
	self.stack[loc] = thisEntry
	local nextEntry = self.stack[loc+1]
	if nextEntry then
		nextEntry.space = determineSpace(thisEntry, nextEntry)
	end
	--]]
	-- [[ works but extra space
	self.stack[loc] = {token=token, type='name', space=' '}
	--]]
end

function Reader:replaceStack(startPos, endPos, ...)
	if startPos < 0 then startPos = startPos + 1 + #r.stack end
	if endPos < 0 then endPos = endPos + 1 + #r.stack end
	for i=startPos,endPos do
		assert(self.stack:remove(startPos))
	end
	-- insert left to right, in order (not reversed), so that each token can see its predecessor in the stack
	for i=1,select('#',...) do
		local insloc = startPos+i-1
		self.stack:insert(insloc, makeTokenEntry(select(i, ...), self.stack[insloc-1]))
	end
end

function Reader:removeStack(loc)
	self:replaceStack(loc, loc)
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
		assert.len(t, 2)
		return assert(cliteralintegertonumber(t[2]), "failed to parse number "..tostring(t[2]))
	elseif t[1] == '!' then
		assert.len(t, 2)
		return castnumber(self:evalAST(t[2])) == 0 and 1 or 0
	elseif t[1] == '~' then
		assert.len(t, 2)
		-- TODO here we are using ffi's bit lib ...
		return bit.bnot(castnumber(self:evalAST(t[2])))
	elseif t[1] == '^' then
		assert.len(t, 3)
		return bit.bxor(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3])))
	elseif t[1] == '&' then
		assert.len(t, 3)
		return bit.band(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '|' then
		assert.len(t, 3)
		return bit.bor(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '<<' then
		assert.len(t, 3)
		return bit.lshift(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '>>' then
		assert.len(t, 3)
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
		assert.len(t, 3)
		return castnumber(self:evalAST(t[2]))
			* castnumber(self:evalAST(t[3]))
	elseif t[1] == '/' then
		assert.len(t, 3)
		return castnumber(self:evalAST(t[2]))
			/ castnumber(self:evalAST(t[3]))
	elseif t[1] == '%' then
		assert.len(t, 3)
		return castnumber(self:evalAST(t[2]))
			% castnumber(self:evalAST(t[3]))
	elseif t[1] == '&&' then
		assert.len(t, 3)
		if castnumber(self:evalAST(t[2])) ~= 0
		and castnumber(self:evalAST(t[3])) ~= 0
		then
			return 1
		end
		return 0
	elseif t[1] == '||' then
		assert.len(t, 3)
		if self:evalAST(t[2]) ~= 0
		or self:evalAST(t[3]) ~= 0
		then
			return 1
		end
		return 0
	elseif t[1] == '==' then
		assert.len(t, 3)
		return (castnumber(self:evalAST(t[2])) == castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '>=' then
		assert.len(t, 3)
		return (castnumber(self:evalAST(t[2])) >= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '<=' then
		assert.len(t, 3)
		return (castnumber(self:evalAST(t[2])) <= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '!=' then
		assert.len(t, 3)
		return (castnumber(self:evalAST(t[2])) ~= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '>' then
		assert.len(t, 3)
		return (castnumber(self:evalAST(t[2])) > castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '<' then
		assert.len(t, 3)
		return (castnumber(self:evalAST(t[2])) < castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '?' then
		assert.len(t, 4)
		if castnumber(self:evalAST(t[2])) ~= 0 then
			return castnumber(self:evalAST(t[3]))
		else
			return castnumber(self:evalAST(t[4]))
		end
	else
		error("don't know how to handle this ast entry "..t[1])
	end
end


function Preproc:parseCondInt(r)
	assert(r)
--DEBUG:print('evaluating condition:', r)
	-- ok so Windows gl.h will have in their macro if statements `MACRO && stmt` where MACRO is #define'd to be an empty string
	-- so if we replace macros here then ... we get parse errors on the #if evaluation
	-- Windows ... smh
--DEBUG:print('after macros:', r)

	local cond

	local level1

	local function level13()
local top = #r.stack
		if r:canbetype'number' then
			local prev = r.stack[-2].token

-- stack is {prev, nextqueued}

			-- remove L/U suffix:
			local val = assert(cliteralintegertonumber(prev), "expected number")	-- decimal number

			-- put it back
			-- or better would be (TODO) just operate on 64bit ints or whatever preprocessor spec says it handles
			r:replaceStack(-2, -2, {
				token = tostring(val),
				type = 'number',
				space = ' ',
			})

		elseif r:canbe'(' then
			local node = level1()
			r:mustbe')'
-- stack is {'(', prev, ')', nextqueued}
			r:removeStack(-4)
			r:removeStack(-2)
-- stack is {prev, nextqueued}
		elseif r:canbe'defined' then
			local par = r:canbe'('
-- stack is {'(', nextqueued}
			r:removeStack(-2)
-- stack is {nextqueued}
			r:mustbetype'name'
			if par then
				r:mustbe')'
-- stack is {name, ')', nextqueued}
				r:removeStack(-2)
			end
-- stack is {name, nextqueued}
			r.stack[-2] = {
				token = tostring(castnumber(self.macros[name])),
				type = 'number',
				space = ' ',
			}
		elseif r:canbe'_Pragma' then
			-- here we want to eliminate the contents of the ()
			-- so just reset the data and remove the %b()
			local rest = string.trim(r:whatsLeft())
			local par, rest = rest:match'^(%b())%s*(.*)$'
assert(par)
			r:setData(rest)
			r:removeStack(-2)	-- remove the former-topmost that got appended into setData

		elseif r:canbe'__has_include'
		or r:canbe'__has_include_next'
		then
			local prev = r.stack[-2].token

			r:mustbe'('
			local rest = string.trim(r:whatsLeft())

			local fn, sys
			if rest:match'^"' then
				fn, rest = rest:match'^(%b"")%s*(.*)$'
			elseif rest:match'^<' then
				fn, rest = rest:match'^(%b<>)%s*(.*)$'
				sys = true
			else
				error('expected <> or ""')
			end

			local repl
			if prev == '__has_include' then
				repl = self:searchForInclude(fn, sys) and '1' or '0'
			elseif prev == '__has_include_next' then
				local foundPrevIncludeDir
				for i=#self.includeStack,1,-1 do
					local includeNextFile = self.includeStack[i]
					local dir, prevfn = path(includeNextFile):getdir()
					if prevfn.path == fn then
						foundPrevIncludeDir = dir.path
						break
					end
				end
				repl = self:searchForInclude(fn, sys, foundPrevIncludeDir) and '1' or '0'
			end

			r:setData(rest)		-- set new data, pushes next token on the stack
			r:replaceStack(-2, repl)	-- replace the former-topmost stack with true or false

			r:mustbe')'
			r:removeStack(-2)

		elseif r:canbetype'name' then
			local k = r.stack[-2].token
			local v = self.macros[k]


			if type(v) == 'string' then
				-- then we need to wedge our string into the to-be-parsed content ...
				-- throw out the old altogether?
				r:setData(v..r:whatsLeft())
				r:removeStack(-2)	-- remove the former-topmost that got appended into setData

				level1()	-- when inserting macros, what level do I start at?

			elseif type(v) == 'table' then
				-- if I try to separately parse further then I have to parse whtas inside the macro args, which would involve () balancing, and only for the sake of () balancing
				-- otherwise I can just () balance regex and then insert it all into the current reader
				local whatsLeft = r:whatsLeft()

				whatsLeft = handleMacroArgs(whatsLeft, v.def)

				-- then we need to wedge our def into the to-be-parsed content with macro args replaced ...
				r:setData(whatsLeft)
				r:removeStack(-2)	-- remove the former-topmost that got appended into setData

				level1()	-- when inserting macros, what level do I start at?

			elseif type(v) == 'nil' then
				-- any unknown/remaining macro variable is going to evaluate to 0
				r.stack[-2] = {token='0', type='number', space=' '}
			end
		else
			error("failed to parse expression: "..cur)
		end
assert.len(r.stack, top+1)
	end

	local function level12()
local top = #r.stack
		if r:canbe'+'
		or r:canbe'-'
		or r:canbe'!'
		or r:canbe'~'
		-- prefix ++ and -- go here in C, but I'm betting not in C preprocessor ...
		then
			level13()
			local op = r.stack[-3].token
-- stack is {'+'|'-'|'!'|'~', a, nextqueued}
assert.ge(#r.stack, 3)
assert(op == '+' or op == '-' or op == '!' or op == '~')

			local a = castnumber(r.stack[-2].token)
			local result
			if op == '+' then
				result = a
			elseif op == '-' then
				result = -a
			elseif op == '!' then
				result = a == 0 and 1 or 0
			elseif op == '~' then
				result = bit.bnot(a)
			else
				error'here'
			end
			r:replaceStack(-3, -2, {
				token = tostring(result),
				type = 'number',
				space = ' ',
			})
		else
			level13()
		end
assert.len(r.stack, top+1)
	end

	local function level11()
local top = #r.stack
		level12()
		if r:canbe'*' or r:canbe'/' or r:canbe'%' then
			level11()
			local op = r.stack[-3].token
-- stack is {a, '*'|'/'|'%', b, nextqueued}
assert.ge(#r.stack, 4)
assert(op == '*' or op == '/' or op == '%')
			local a = castnumber(r.stack[-4].token)
			local b = castnumber(r.stack[-2].token)
			local result
			if op == '*' then
				result = a * b
			elseif op == '/' then
				result = a / b		-- always integer division?
			elseif op == '%' then
				result = a % b
			else
				error'here'
			end
			r:replaceStack(-4, -2, {
				token = tostring(result),
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level10()
local top = #r.stack
		level11()
		if r:canbe'+' or r:canbe'-' then
			level10()
			local op = r.stack[-3].token
-- stack is {a, '+'|'-', b, nextqueued}
assert.ge(#r.stack, 4)
assert(op == '+' or op == '-')
			local a = castnumber(r.stack[-4].token)
			local b = castnumber(r.stack[-2].token)
			local result
			if op == '+' then
				result = a + b
			elseif op == '-' then
				result = a - b
			else
				error'here'
			end
			r:replaceStack(-4, -2, {
				token = tostring(result),
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level9()
local top = #r.stack
		level10()
		if r:canbe'>>' or r:canbe'<<' then
			level9()
			local op = r.stack[-3].token
-- stack is {a, '>>'|'<<', b, nextqueued}
assert.ge(#r.stack, 4)
assert(op == '>>' or op == '<<')
			local a = castnumber(r.stack[-4].token)
			local b = castnumber(r.stack[-2].token)
			local result
			if op == '>>' then
				result = bit.rshift(a, b)
			elseif op == '<<' then
				result = bit.lshift(a, b)
			else
				error'here'
			end
			r:replaceStack(-4, -2, {
				token = tostring(result),
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level8()
local top = #r.stack
		level9()
		if r:canbe'>='
		or r:canbe'<='
		or r:canbe'>'
		or r:canbe'<'
		then
			level8()
			local op = r.stack[-3].token
-- stack is {a, '>='|'<='|'>'|'<', b, nextqueued}
assert.ge(#r.stack, 4)
assert(op == '>=' or op == '<=' or op == '>' or op == '<')
			local a = castnumber(r.stack[-4].token)
			local b = castnumber(r.stack[-2].token)
			local result
			if op == '>=' then
				result = a >= b and '1' or '0'
			elseif op == '<=' then
				result = a <= b and '1' or '0'
			elseif op == '>' then
				result = a > b and '1' or '0'
			elseif op == '<' then
				result = a < b and '1' or '0'
			else
				error'here'
			end
			r:replaceStack(-4, -2, {
				token = result,
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level7()
local top = #r.stack
		level8()
		if r:canbe'==' or r:canbe'!=' then
			level7()
			local op = r.stack[-3].token
-- stack is {a, '=='|'!=', b, nextqueued}
assert.ge(#r.stack, 4)
assert(op == '==' or op == '!=')
			local a = castnumber(r.stack[-4].token)
			local b = castnumber(r.stack[-2].token)
			r:replaceStack(-4, -2, {
				token = tostring(
					op == '=='
					and (a == b and '1' or '0')
					or (a ~= b and '1' or '0')
				),
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level6()
local top = #r.stack
		level7()
		if r:canbe'&' then
			level6()
-- stack is {a, '&', b, nextqueued}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '&')
			r:replaceStack(-4, -2, {
				token = tostring(
					bit.band(
						castnumber(r.stack[-4].token),
						castnumber(r.stack[-2].token)
					)
				),
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level5()
local top = #r.stack
		local a = level6()
		if r:canbe'^' then
			level5()
-- stack is {a, '^', b, nextqueued}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '^')
			r:replaceStack(-4, -2, {
				token = tostring(
					bit.bxor(
						castnumber(r.stack[-4].token),
						castnumber(r.stack[-2].token)
					)
				),
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level4()
local top = #r.stack
		level5()
		if r:canbe'|' then
			level4()
-- stack is {a, '|', b, nextqueued}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '|')
			r:replaceStack(-4, -2, {
				token = tostring(
					bit.bor(
						castnumber(r.stack[-4].token),
						castnumber(r.stack[-2].token)
					)
				),
				type = 'number',
				space = ' ',
			})
		end
assert.len(r.stack, top+1)
	end

	local function level3()
local top = #r.stack
		level4()
		if r:canbe'&&' then
			level3()
-- stack should be {a, '&&', b, nextqueued}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '&&')
			r:replaceStack(-4, -2, castnumber(r.stack[-4].token) == 0
				and r.stack[-2]
				or r.stack[-4])
		end
assert.len(r.stack, top+1)
	end

	local function level2()
local top = #r.stack
		level3()
		if r:canbe'||' then
			level2()
-- stack should be: {a, '||', b, nextqueued}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '||')
			r:replaceStack(-4, -2, castnumber(r.stack[-4].token) ~= 0
				and r.stack[-4]
				or r.stack[-2])
		end
assert.len(r.stack, top+1)
	end

	level1 = function()
local top = #r.stack
		level2()
		if r:canbe'?' then
			level1()
			r:mustbe':'
			level1()
-- stack stack should be: {a, '?', b, ':', c, nextqueued}
assert.ge(#r.stack, 6)
assert.eq(r.stack[-5].token, '?')
assert.eq(r.stack[-3].token, ':')
			r:replaceStack(-6, -2, castnumber(r.stack[-6].token) ~= 0
				and r.stack[-4]
				or r.stack[-2])
		end
assert.len(r.stack, top+1)
	end

	local parse = level1()

--DEBUG:print('got expression tree', tolua(parse))
-- stack should be: {'#', 'if'/'elif', cond, nextqueued}
assert.len(#r.stack, 4)
	r:mustbetype'done'
	local cond = castnumber(r.stack[-2].token)

--DEBUG:print('got cond', cond)

	return cond
end

function Preproc:__call(args)
	if type(args) == 'string' then
		args = {code=args}
	elseif type(args) ~= 'table' then
		error("can't handle args")
	end

	local code = assert.index(args, 'code')

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

	local lastTime = os.time()

	xpcall(function()
		while i <= #lines do
			local thisTime = os.time()
			if thisTime > lastTime then
				lastTime = thisTime
				print('... on line '..i..'/'..#lines)
			end

			local l = lines[i]
			local popInc = l:match'^/%* %+* END   (.*) %*/$'
			if popInc then
				local last = self.includeStack:remove()
-- TODO in my nested include() this is getting broken
				assert.eq(last, popInc, "end of include "..popInc.." vs includeStack "..tolua(last))
			else
				-- nil = no condition present
				-- true = current condition is true
				-- false = current condition is false
				local eval = true
				if #ifstack > 0 then
					for j,b in ipairs(ifstack) do
						if b[1] == false then
							eval = false
							break
						end
					end
				end

				local preveval = true
				if #ifstack > 0 then
					for j=1,#ifstack-1 do
						if ifstack[j][1] == false then
							preveval = false
							break
						end
					end
				end

--DEBUG:print('line is '..tolua(l)..' eval is '..tolua(eval)..' preveval is '..tolua(preveval))

				local function closeIf(cmd)
					assert.gt(#ifstack, 0, 'found an #'..cmd..' without an #if')
					ifstack:remove()
				end

				l = string.trim(l)

				if l:match'^%s*#' then

					local r = Reader(l)
					r:mustbe'#'	-- expected right, unless this line starts with ##

					-- another windows irritation ... `#cmd` and `#(cmd)` are both valid
					local cmdpar = r:canbe'('
					local cmd = r:mustbetype'name'
					if cmdpar then r:mustbe')' end
--DEBUG:print('got cmd '..tolua(cmd)..', after cmd is '..tolua(r:whatsLeft()))

					if cmd == 'define' then
--DEBUG:print'handling "define"'
						if eval then
							local k = r:mustbetype'name'
--DEBUG:print('got name='..tolua(k))
							-- and now spaces matter ...
							-- if the next parenthesis is space-separated then this is just a replacement-macro
							-- but if there's no space then it is a function-macro
							local par = r:canbe'('
							if par
							and r.stack[-2].space == ''
							then
								-- params
								local params = table()
								local first = true
								while not r:canbe')' do
									if not first then
										r:mustbe','
									end
									first = false
									params:insert(r:canbe'...' or r:mustbetype'name')
								end
								local paramdef = r:whatsLeft()
--DEBUG:print('defining with params',params,paramdef)
								-- by default returns '' to replace the line with empty
								lines[i] = self:getDefineCode(k, {
									params = params,
									def = paramdef,	-- This is rest of the line to be parsed:
								}, l)
							else
--DEBUG:print('defining value',k,v)
								local v = (par and '(' or '')..r:whatsLeft()
								v = string.trim(v)
								-- replace
								lines[i] = self:getDefineCode(k, v)
							end
						else
							lines:remove(i)
							i = i - 1
						end
					elseif cmd == 'if'
					or cmd == 'elif'
					then
--DEBUG:print('if/elif with eval', eval, 'preveval', preveval)
						local hasprocessed = false
						if cmd == 'elif' then
--DEBUG:print('closing via elif, #ifstack', require'ext.tolua'(ifstack))
							local oldcond = ifstack:last()
							hasprocessed = oldcond[1] or oldcond[2]
							closeIf(cmd)
						end

--DEBUG:print('hasprocessed', hasprocessed)
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
--DEBUG:print('elif skipping cond evaluation')
								cond = false
							else
								cond = self:parseCondInt(r) ~= 0
								assert(cond ~= nil, "cond must be true or false")
							end
						end
--DEBUG:print('got cond', cond, 'from', r)
						ifstack:insert{cond, hasprocessed}

						lines:remove(i)
						i = i - 1


					elseif cmd == 'else' then
						assert.gt(#ifstack, 0, "found an #else without an #if")
						local oldcond = ifstack:last()
						local hasprocessed = oldcond[1] or oldcond[2]
						assert.eq(rest, '', "found trailing characters after "..cmd)
						ifstack[#ifstack] = {not hasprocessed, hasprocessed}
						lines:remove(i)
						i = i - 1
					elseif cmd == 'ifdef' then
						local rest = r:whatsLeft()
--DEBUG:print('ifdef looking for '..rest)
						assert(isvalidsymbol(rest))
						local cond = not not self.macros[rest]
--DEBUG:print('got cond', cond)
						ifstack:insert{cond, false}

						lines:remove(i)
						i = i - 1
					elseif cmd == 'ifndef' then
						local rest = r:whatsLeft()
--DEBUG:print('ifndef looking for', rest)
						assert(isvalidsymbol(rest), "tried to check ifndef a non-valid symbol "..tolua(rest))
						local cond = not self.macros[rest]
--DEBUG:print('got cond', cond)
						ifstack:insert{cond, false}

						lines:remove(i)
						i = i - 1
					elseif cmd == 'endif' then
						assert.eq(rest, '', "found trailing characters after "..cmd)
						closeIf(cmd)
						ifHandled = nil
						lines:remove(i)
						i = i - 1
					elseif cmd == 'undef' then
						local rest = r:whatsLeft()
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
						local rest = r:whatsLeft()
						if eval then
							error(rest)
						end
						lines:remove(i)
						i = i - 1
					elseif cmd == 'warning' then
						local rest = r:whatsLeft()
						if eval then
							print('warning: '..rest)
						end
						lines:remove(i)
						i = i - 1
					elseif cmd == 'include' then
						local rest = r:whatsLeft()
						lines:remove(i)
						if eval then
							-- ok so should I be replacing macros before handling *all* preprocessor directives? I really hope not.
							-- TODO there are some lines that are #include MACRO ... but if it's within a string then no, dont replace macros.
							--rest = self:replaceMacros(rest, nil, true, true)

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
print(('+'):rep(#self.includeStack+1)..' #include '..fn)
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
						local rest = r:whatsLeft()
						lines:remove(i)
						if eval then
							-- ok so should I be replacing macros before handling *all* preprocessor directives? I really hope not.
							--rest = self:replaceMacros(rest, nil, true, true)

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
--DEBUG:print('include_next search fn='..tostring(fn)..' sys='..tostring(sys))
							-- search through the include stack for the most recent file with the name of what we're looking for ...
							local foundPrevIncludeDir
							for i=#self.includeStack,1,-1 do
								local includeNextFile = self.includeStack[i]
								local dir, prevfn = path(includeNextFile):getdir()
--DEBUG:print(includeNextFile, dir, prevfn)
								if prevfn.path == fn then
									foundPrevIncludeDir = dir.path
									break
								end
							end
--DEBUG:print('foundPrevIncludeDir '..tostring(foundPrevIncludeDir))
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
--DEBUG:print('include_next '..fn)
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
						local rest = r:whatsLeft()
						if eval then
							if rest == 'once' then
								-- if we #pragma once on a non-included file then nobody cares
								if #self.includeStack > 0 then
									local last = self.includeStack:last()
									self.alreadyIncludedFiles[last] = true
								end
								lines:remove(i)
								i = i - 1
							elseif rest:match'^pack' then
								-- keep pragma pack
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
						-- plain ol' line ...
						--error('here with '..tolua(l))
					end
				end
			end
			i = i + 1
		end
	end, function(err)
		throwme = table()
		--[[ too big
		throwme:insert(require 'template.showcode'(lines:sub(1, i+10):concat'\n'))
		--]]
		-- [[ put in file
		path'~lastfile.lua':write(lines:concat'\n')
		--]]
		-- TODO lines should hold the line, the orig line no, and the inc file
		for _,inc in ipairs(self.includeStack) do
			throwme:insert(' at '..inc)
		end
		throwme:insert('at line: '..i)
		--[[ output?  it's big so ...
		throwme:insert('macros: '..tolua(self.macros))
		--]]
		-- [[ so just put it in a file
		path'~macros.lua':write(tolua(self.macros))
		--]]
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
