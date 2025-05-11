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

local function isvalidsymbol(s)
	return not not s:match('^[_%a][_%w]*$')
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
-- TODO combine these suffixes with the ones on string parsing ...
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
			if type(k) == 'number' and k < 0 then
				k = k + #t + 1
			end
			local v = rawget(t, k)
			if v == nil then v = table[k] end
			return v
		end,
		__newindex = function(t,k,v)
			if type(k) == 'number' and k < 0 then
				k = k + #t + 1
			end
			rawset(t, k, v)
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
--DEBUG:print'Reader:next ...inserting type=done'
			self.stack:insert{token='', type='done', space=''}
		end
--DEBUG:print'Reader:next ...done'
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
--DEBUG:print('Reader:next ...next got', tolua{token=token, type=tokentype, space=space})
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
--DEBUG:print('Reader:canbetype', self, tokentype)
--DEBUG:print('Reader:canbetype self.stack', self.stack)
	local last = self.stack:last()
--DEBUG:print('Reader:canbetype last', last)
	if tokentype == last.type then
		self:next()
--DEBUG:print('Reader:canbetype returning', last.token)
		return last.token
	end
end

function Reader:mustbetype(tokentype)
--DEBUG:print('Reader:mustbetype', self, tokentype)
	local result = self:canbetype(tokentype)
		or error("expected token type "..tolua(tokentype).." but found "..tolua(self.stack:last()))
--DEBUG:print('Reader:mustbetype got', result)
	return result
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
assert.ge(loc, 1)
assert.le(loc, #self.stack+1)
	self.stack[loc] = {token=token, type='name', space=' '}
	--]]
end

function Reader:replaceStack(startPos, endPos, ...)
	if startPos < 0 then startPos = startPos + 1 + #self.stack end
	if endPos < 0 then endPos = endPos + 1 + #self.stack end
	local removed = self.stack:sub(startPos, endPos)
	for i=startPos,endPos do
		assert(self.stack:remove(startPos))
	end
	-- insert left to right, in order (not reversed), so that each token can see its predecessor in the stack
	for i=1,select('#',...) do
		local insloc = startPos+i-1
assert.ge(insloc, 1)
assert.le(insloc, #self.stack+1)
		self.stack:insert(insloc, makeTokenEntry(select(i, ...), self.stack[insloc-1]))
	end
	return removed:unpack()
end

function Reader:removeStack(loc)
	return self:replaceStack(loc, loc)
end

function Reader:insertStack(loc, ...)
	return self:replaceStack(loc, loc-1, ...)
end

function Reader:stackToString()
--DEBUG:print('Reader:stackToString stack='..tolua(self.stack))
	return self.stack:mapi(function(entry) return entry.space..entry.token end):concat()
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

local function cLiteralIntegerToNumber(x)
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
	local n = cLiteralIntegerToNumber(x)
	if not n then error("couldn't cast to number: "..x) end
	return n
end

--[[
Uses parenthesis-balancing to parse the macro arguments.

args:
	paramStr = macro arg, of '(' + comma-sep args + ')'
	vparams = list of macro params: {'a', 'b', 'c'} etc, found in macros[name].params

returns:
	map from vparams' strings as keys to values found in paramStr
	with maybe an extra '...' key to any varargs
--]]
function Preproc:parseMacroArgs(paramStr, vparams)
--DEBUG:print('Preproc:parseMacroArgs', tolua{paramStr=paramStr, vparams=vparams})

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

					if #vparams == 1 and vparams[1] == '...' then
						-- varargs ... use ... indexes?  numbers?  strings?
						paramMap[paramIndex] = paramvalue
					else
						if not vparams[paramIndex] then
							error('failed to find paramIndex '..tostring(paramIndex)..'\n'
								..' vparams='..require'ext.tolua'(vparams)..'\n'	-- macro arguments
								--..' paramStr='..tostring(paramStr)..'\n'
								..' paramvalue='..tostring(paramvalue)..'\n'
								..' l='..tostring(l)..'\n'	-- line we are replacing
								..' paramMap='..tolua(paramMap)..'\n'
							)
						end
						paramMap[vparams[paramIndex]] = paramvalue
					end
					last = i + 1
				end
			end
			i = i + 1
		end
		assert.eq(parcount, 0, "macro mismatched ()'s")
		local paramvalue = paramStr:sub(last)
		paramIndex = paramIndex + 1

		if #vparams == 1 and vparams[1] == '...' then
			-- varargs
			paramMap[paramIndex] = paramvalue
		else
			local macrokey = vparams[paramIndex]
			if not macrokey then
				error("failed to find index "..tolua(paramIndex).." of vparams "..tolua(vparams))
			end
--DEBUG(Preproc:parseMacroArgs): print('substituting the '..paramIndex..'th macro from key '..tostring(macrokey)..' to value '..paramvalue)
			paramMap[macrokey] = paramvalue
		end
	end

	-- if we were vararg matching this whole time ... should I replace it with a single-arg and concat the values?
	if #vparams == 1 and vparams[1] == '...' then
		paramMap = {['...'] = table.mapi(paramMap, function(v) return tostring(v) end):concat', '}
	else
		assert.eq(paramIndex, #vparams, "expanding macro, expected "..#vparams.." "..tolua(vparams).." params but found "..paramIndex..": "..tolua(paramMap))
	end

--DEBUG:print('Preproc:parseMacroArgs got', tolua(paramMap))
	return paramMap
end

-- try to evaluate the token at the top
-- like level13, but unlike it this doesn't fail if it can't evaluate it
function Preproc:tryToEval(r)
--DEBUG:print('Preproc:tryToEval', tolua(r.stack[-1]))
local top = #r.stack
local rest = r:whatsLeft()

	if r:canbetype'name' then
-- stack: {..., name, next}
		local k = r.stack[-2].token
		local v = self.macros[k]
--DEBUG:print('...handling named macro: '..tolua(k)..' = '..tolua(v))

		if type(v) == 'string' then
			assert.eq(r:removeStack(-2).token, k)
-- stack: {..., next}
			-- then we need to wedge our string into the to-be-parsed content ...
			-- throw out the old altogether?
			local rest = r:whatsLeft()
			r:removeStack(-1)
-- stack: {...}
			r:setData(v..rest)
-- stack: {..., next}

			if not self.evaluatingPlainCode then
				self:level1(r)	-- when inserting macros, what level do I start at?
			else
				-- TODO
				-- levelX() wants one new thing on the stack
				-- and the stack assertion is at the end of this function
				-- but
				-- this is also called from evaluatingPlainCode's tryToEval()
				-- and in that case we don't care
				-- but for consistency,
				-- here's an empty string
				--r:insertStack(-1, '')
				-- ... tokentype classifier will complain so ...
				r.stack:insert(#r.stack, {
					token='',
					type='space',
					space='',
				})
			end
-- stack: {..., result, next}

		elseif type(v) == 'table' then
			assert.eq(r:removeStack(-2).token, k)
-- stack: {..., next}
			-- if I try to separately parse further then I have to parse whtas inside the macro args, which would involve () balancing, and only for the sake of () balancing
			-- otherwise I can just () balance regex and then insert it all into the current reader
			local paramStr, rest
			rest = string.trim(r:whatsLeft())
			r:removeStack(-1)
-- stack: {...}
			paramStr, rest = rest:match'^(%b())%s*(.*)$'

			-- now we have to count () balance ourselves to find our where the right commas go ...
			assert(paramStr, "macro expected arguments")

			-- TODO ()-balancing and comma-separation for the arguments in 'paramStr' ...
			paramStr = paramStr:sub(2,-2)	-- strip outer ()'s

-- then use those for values associatd with variables in `v.params`
			local paramMap = self:parseMacroArgs(paramStr, v.params)
-- then replace all occurrences of those variables found within the stack of `v.def`
-- then copy that stack onto the top, underneath the current next-token.

			local eval = table()
			for _,e in ipairs(v.def) do
				eval:insert(e.space)
				local replArg = paramMap[e.token]
				if replArg then
					eval:insert(replArg)
				else
					eval:insert(e.token)
				end
			end
			eval = eval:concat()
--DEBUG:print('evalated to', eval)

			-- then we need to wedge our def into the to-be-parsed content with macro args replaced ...
			r:setData(eval..rest)
-- stack: {..., next}

			-- when inserting macros, what level do I start at?
			-- to handle scope, lets wrap in ( ) and use level13's ( ) evaluation
			if not self.evaluatingPlainCode then
				self:level1(r)
			else
				-- same argument as above
				--r:insertStack(-1, '')
				-- ... tokentype classifier will complain so ...
				r.stack:insert(#r.stack, {
					token='',
					type='space',
					space='',
				})
			end
-- stack: {..., result, next}

		elseif type(v) == 'nil' then
			-- any unknown/remaining macro variable is going to evaluate to 0

			if self.evaluatingPlainCode then
				-- if we're not in a macro-eval then leave it as is
-- stack: {..., name, next}
			else
				-- if we're in a macro-eval then replace with a 0
				r:replaceStack(-2, -2, '0')
-- stack: {..., "0", next}
			end
		end
	else
--DEBUG:print("...couldn't handle "..tolua(rest))
--DEBUG:print("The stack better not have changed.")
assert.len(r.stack, top)
		return false
	end
--DEBUG:print("...handled, so the stack better be +1")
assert.len(r.stack, top+1)
	return true
end

function Preproc:level13(r)
local top = #r.stack
local rest = r:whatsLeft()

	if r:canbetype'number' then
		local prev = r.stack[-2].token

-- stack: {prev, next}

		-- remove L/U suffix:
		local val = assert(cLiteralIntegerToNumber(prev), "expected number")	-- decimal number

		-- put it back
		-- or better would be (TODO) just operate on 64bit ints or whatever preprocessor spec says it handles
		r:replaceStack(-2, -2, tostring(val))
	elseif r:canbe'(' then
		self:level1(r)
		r:mustbe')'
-- stack: {'(', prev, ')', next}
		r:removeStack(-4)
		r:removeStack(-2)
-- stack: {prev, next}

	-- what does this even do?
	elseif r:canbe'_Pragma' then
--DEBUG:print'...handling _Pragma'
-- stack: {..., "_Pragma", next)
assert.eq(r:removeStack(-2).token, '_Pragma')
-- stack: {..., next)
		-- here we want to eliminate the contents of the ()
		-- so just reset the data and remove the %b()
		local rest = string.trim(r:whatsLeft())
		local par, rest = rest:match'^(%b())%s*(.*)$'
assert(par)
		r:removeStack(-1)
-- stack: {...}
		r:setData(rest)
-- stack: {..., next}
		r:insertStack(-1, '0')
-- stack: {..., "0", next}

	elseif r:canbe'__has_include'
	or r:canbe'__has_include_next'
	then
		local prev = r.stack[-2].token
--DEBUG:print('...handling '..prev)
assert(prev == '__has_include' or prev == '__has_include_next')
-- stack: {..., prev, next}
		assert.eq(r:removeStack(-2).token, prev)
-- stack: {..., next}

		r:mustbe'('
-- stack: {..., "(", next}
		assert.eq(r:removeStack(-2).token, '(')
-- stack: {..., next}

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

		r:removeStack(-1)
-- stack: {...}
		r:setData(rest)		-- set new data, pushes next token on the stack
-- stack: {..., next}
		r:insertStack(-1, repl)
-- stack: {..., repl, next}

		r:mustbe')'
-- stack: {..., repl, ")", next}
		assert.eq(r:removeStack(-2).token, '(')
-- stack: {..., repl, next}

	elseif r:canbe'defined' then
-- stack: {'defined', next}
		assert.eq(r:removeStack(-2).token, 'defined')
-- stack: {next}
		local par = r:canbe'('
-- stack: {'(', next}
		assert.eq(r:removeStack(-2).token, '(')
-- stack: {next}
		local name = r:mustbetype'name'
--DEBUG:print('evaluating defined('..tolua(name)..')')
		if par then
			r:mustbe')'
-- stack: {name, ')', next}
			assert.eq(r:removeStack(-2).token, ')')
-- stack: {name, next}
		end
-- stack: {name, next}
		assert.eq(r.stack[-2].token, name)
		r:replaceStack(-2, -2, tostring(castnumber(self.macros[name])))
	else
		-- do 'tryToEval' last to catch all other names we didn't just handle above
		if not self:tryToEval(r) then
			error("failed to parse expression: "..rest)
		end
	end
assert.len(r.stack, top+1)
end

function Preproc:level12(r)
local top = #r.stack
	if r:canbe'+'
	or r:canbe'-'
	or r:canbe'!'
	or r:canbe'~'
	-- prefix ++ and -- go here in C, but I'm betting not in C preprocessor ...
	then
		self:level13(r)
		local op = r.stack[-3].token
-- stack: {'+'|'-'|'!'|'~', a, next}
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
		r:replaceStack(-3, -2, tostring(result))
	else
		self:level13(r)
	end
assert.len(r.stack, top+1)
end

function Preproc:level11(r)
local top = #r.stack
	self:level12(r)
	if r:canbe'*' or r:canbe'/' or r:canbe'%' then
		self:level11(r)
		local op = r.stack[-3].token
-- stack: {a, '*'|'/'|'%', b, next}
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
		r:replaceStack(-4, -2, tostring(result))
	end
assert.len(r.stack, top+1)
end

function Preproc:level10(r)
local top = #r.stack
	self:level11(r)
	if r:canbe'+' or r:canbe'-' then
		self:level10(r)
		local op = r.stack[-3].token
-- stack: {a, '+'|'-', b, next}
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
		r:replaceStack(-4, -2, tostring(result))
	end
assert.len(r.stack, top+1)
end

function Preproc:level9(r)
local top = #r.stack
	self:level10(r)
	if r:canbe'>>' or r:canbe'<<' then
		self:level9(r)
		local op = r.stack[-3].token
-- stack: {a, '>>'|'<<', b, next}
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
		r:replaceStack(-4, -2, tostring(result))
	end
assert.len(r.stack, top+1)
end

function Preproc:level8(r)
local top = #r.stack
	self:level9(r)
	if r:canbe'>='
	or r:canbe'<='
	or r:canbe'>'
	or r:canbe'<'
	then
		self:level8(r)
		local op = r.stack[-3].token
-- stack: {a, '>='|'<='|'>'|'<', b, next}
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
		r:replaceStack(-4, -2, result)
	end
assert.len(r.stack, top+1)
end

function Preproc:level7(r)
local top = #r.stack
	self:level8(r)
	if r:canbe'==' or r:canbe'!=' then
		self:level7(r)
		local op = r.stack[-3].token
-- stack: {a, '=='|'!=', b, next}
assert.ge(#r.stack, 4)
assert(op == '==' or op == '!=')
		local a = castnumber(r.stack[-4].token)
		local b = castnumber(r.stack[-2].token)
		r:replaceStack(-4, -2, tostring(
			op == '=='
			and (a == b and '1' or '0')
			or (a ~= b and '1' or '0')
		))
	end
assert.len(r.stack, top+1)
end

function Preproc:level6(r)
local top = #r.stack
	self:level7(r)
	if r:canbe'&' then
		self:level6(r)
-- stack: {a, '&', b, next}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '&')
		r:replaceStack(-4, -2, tostring(
			bit.band(
				castnumber(r.stack[-4].token),
				castnumber(r.stack[-2].token)
			)
		))
	end
assert.len(r.stack, top+1)
end

function Preproc:level5(r)
local top = #r.stack
	self:level6(r)
	if r:canbe'^' then
		self:level5(r)
-- stack: {a, '^', b, next}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '^')
		r:replaceStack(-4, -2, tostring(
			bit.bxor(
				castnumber(r.stack[-4].token),
				castnumber(r.stack[-2].token)
			)
		))
	end
assert.len(r.stack, top+1)
end

function Preproc:level4(r)
local top = #r.stack
	self:level5(r)
	if r:canbe'|' then
		self:level4(r)
-- stack: {a, '|', b, next}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '|')
		r:replaceStack(-4, -2, tostring(
			bit.bor(
				castnumber(r.stack[-4].token),
				castnumber(r.stack[-2].token)
			)
		))
	end
assert.len(r.stack, top+1)
end

function Preproc:level3(r)
local top = #r.stack
	self:level4(r)
	if r:canbe'&&' then
		self:level3(r)
-- stack should be {a, '&&', b, next}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '&&')
		r:replaceStack(-4, -2, castnumber(r.stack[-4].token) == 0
			and r.stack[-2].token
			or r.stack[-4].token)
	end
assert.len(r.stack, top+1)
end

function Preproc:level2(r)
local top = #r.stack
	self:level3(r)
	if r:canbe'||' then
		self:level2(r)
-- stack should be: {a, '||', b, next}
assert.ge(#r.stack, 4)
assert.eq(r.stack[-3].token, '||')
		r:replaceStack(-4, -2, castnumber(r.stack[-4].token) ~= 0
			and r.stack[-4].token
			or r.stack[-2].token)
	end
assert.len(r.stack, top+1)
end

function Preproc:level1(r)	-- defined at the top
local top = #r.stack
	self:level2(r)
	if r:canbe'?' then
		self:level1(r)
		r:mustbe':'
		self:level1(r)
-- stack stack should be: {a, '?', b, ':', c, next}
assert.ge(#r.stack, 6)
assert.eq(r.stack[-5].token, '?')
assert.eq(r.stack[-3].token, ':')
		r:replaceStack(-6, -2, castnumber(r.stack[-6].token) ~= 0
			and r.stack[-4].token
			or r.stack[-2].token)
	end
assert.len(r.stack, top+1)
end

function Preproc:parseCondInt(r)
	assert(r)
-- stack: {next}
assert.len(r.stack, 1)
	-- ok so Windows gl.h will have in their macro if statements `MACRO && stmt` where MACRO is #define'd to be an empty string
	-- so if we replace macros here then ... we get parse errors on the #if evaluation
	-- Windows ... smh

	self:level1(r)

-- stack: {cond, next}
print('stack', tolua(r.stack))
assert.len(r.stack, 2)
	r:mustbetype'done'

	local cond = castnumber(r.stack[1].token)
--DEBUG:print('got cond', cond)
	r.stack:remove(1)
-- stack: {next}
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
-- stack: {next}
assert.len(r.stack, 1)
					r:mustbe'#'	-- expected right, unless this line starts with ##
-- stack: {'#', next}
assert.len(r.stack, 2)
					assert.eq(r:removeStack(-2).token, '#')
-- stack: {next}
assert.len(r.stack, 1)

					-- another windows irritation ... `#cmd` and `#(cmd)` are both valid
					local par = r:canbe'('
					if par then
-- stack: {'(', next}
						assert.eq(r:removeStack(-2).token, '(')
					end
-- stack: {next}
assert.len(r.stack, 1)
					local cmd = r:mustbetype'name'
-- stack: {cmd, next}
					assert.eq(r:removeStack(-2).token, cmd)
-- stack: {next}
assert.len(r.stack, 1)
					if par then
						r:mustbe')'
						assert.eq(r:removeStack(-2).token, ')')
					end
-- stack: {next}
assert.len(r.stack, 1)
--DEBUG:print('got cmd '..tolua(cmd)..', after cmd is '..tolua(r:whatsLeft()))
					if cmd == 'define' then
--DEBUG:print'handling "define"'
-- stack: {next}
assert.len(r.stack, 1)
						if eval then
							local k = r:mustbetype'name'
--DEBUG:print('got name='..tolua(k))
-- stack: {name, next}
assert.len(r.stack, 2)
							assert.eq(r:removeStack(-2).token, k)
-- stack: {next}
assert.len(r.stack, 1)
							-- and now spaces matter ...
							-- if the next parenthesis is space-separated then this is just a replacement-macro
							-- but if there's no space then it is a function-macro
							local par = r:canbe'('
if par then
	assert.len(r.stack, 2)
	assert.eq(r.stack[1], r.stack[-2])
	assert.eq(r.stack[2], r.stack[-1])
end
							if par
							and r.stack[-2].space == ''
							then
-- stack: {'(', next}
								assert.eq(r:removeStack(-2).token, '(')
-- stack: {next}
								-- params
								local params = table()
								local first = true
								while not r:canbe')' do
									if not first then
-- stack: {',', next}
										r:mustbe','
-- stack: {next}
										assert.eq(r:removeStack(-2).token, ',')
									end
									first = false
									local argname = r:canbe'...' or r:mustbetype'name'
-- stack: {argname, next}
									params:insert(argname)
-- stack: {next}
									assert.eq(r:removeStack(-2).token, argname)
								end
-- stack: {')', next}
								assert.eq(r:removeStack(-2).token, ')')
-- stack: {next}
assert.len(r.stack, 1)
								-- now parse all of the rest of the line and save it for later
								while not r:canbetype'done' do
									r:next()
								end

								-- now save it
								local def = table()
								local n = #r.stack-1
								table.move(r.stack, 1, n, 1, def)
assert.len(def, n)
assert.len(r.stack, n+1)
								r.stack[1] = r.stack[n+1]
								for i=2,n+1 do
									r.stack[i] = nil
								end
assert.len(r.stack, 1)
assert.eq(r.stack[1].type, 'done')

--DEBUG:print('defining macro '..tolua(k)..' with params='..tolua(params)..', def='..tolua(def))
								-- by default returns '' to replace the line with empty
								lines[i] = self:getDefineCode(k, {
									params = params,
									def = def,	-- This is rest of the line to be parsed:
								}, l)
							else

--DEBUG:print('defining macro '..tolua(k)..' with value='..tolua(v))
								local v = (par and '(' or '')..r:whatsLeft()
								v = string.trim(v)
								-- replace
								lines[i] = self:getDefineCode(k, v, l)
							end
						else
							lines:remove(i)
							i = i - 1
						end
					elseif cmd == 'if'
					or cmd == 'elif'
					then
-- stack: {next}
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
assert.len(r.stack, 1)
								cond = self:parseCondInt(r) ~= 0
assert.len(r.stack, 1)
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
--DEBUG:print('got non-macro line: '..tolua(l))

						-- tokenize it and search through it
						-- and replace any macros you find
						local r = Reader(l)

						while not r:canbetype'done' do
--DEBUG:print('#r.stack', #r.stack)
--DEBUG:print('normal line handling token', tolua(r.stack[-1]))
-- {..., last token consumed that isn't done, next}

							-- see if we can expand it to a token ...
							self.evaluatingPlainCode = true	-- TODO or just pass a flag through the 'eval' levels
							self:tryToEval(r)
							self.evaluatingPlainCode = nil

							-- try to expand stack[-1]
							-- i.e. try to apply level13 of the expr evaluator
							r:next()
						end

						-- TODO only replace line if we ever replaced a macro?
						lines[i] = r:stackToString()
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
		for i=#lines-1,1,-1 do
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
