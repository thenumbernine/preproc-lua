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

function Preproc:handleMacroWithArgs(l, key, vparams)
	-- TODO multiline support
	-- look for 'key' whatsoever
	-- if we find it then switch to start expecting that opening parenthesis
	-- and then tokenize or something.

	local keyj,keyk = l:find(key)
	if not keyj then return end

	local beforekey = l:sub(keyj-1,keyj-1)
	local afterkey = l:sub(keyk+1,keyk+1)
	if beforekey:match'[_%w]'
	or afterkey:match'[_%w]'
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
--DEBUG(Preproc:handleMacroWithArgs): print("/* ### INCOMPLETE ARG MACRO ### "..key..' ### IN LINE ### '..l..' */')
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
	if before:match'[_%w]' then
		return
	end

--DEBUG(Preproc:handleMacroWithArgs): print('found macro', key)
--DEBUG(Preproc:handleMacroWithArgs): print('replacing from params '..tolua(vparams))

	local paramStr = l:sub(j,k):match(pat)
	paramStr = paramStr:sub(2,-2)	-- strip outer ()'s
--DEBUG(Preproc:handleMacroWithArgs): print('found paramStr', paramStr)
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

					if #vparams == 1 and vparams[1] == '...' then
						-- varargs ... use ... indexes?  numbers?  strings?
						paramMap[paramIndex] = paramvalue
					else
						if not vparams[paramIndex] then
							error('failed to find paramIndex '..tostring(paramIndex)..'\n'
								..' key='..tostring(key)..'\n'	-- macro name
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
--DEBUG(Preproc:handleMacroWithArgs): print('substituting the '..paramIndex..'th macro from key '..tostring(macrokey)..' to value '..paramvalue)
			paramMap[macrokey] = paramvalue
		end
	end

	-- if we were vararg matching this whole time ... should I replace it with a single-arg and concat the values?
	if #vparams == 1 and vparams[1] == '...' then
		paramMap = {['...'] = table.mapi(paramMap, function(v) return tostring(v) end):concat', '}
	else
		assert.eq(paramIndex, #vparams, "expanding macro "..key.." expected "..#vparams.." "..tolua(vparams).." params but found "..paramIndex..": "..tolua(paramMap))
	end

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
--DEBUG(Preproc isInString): print('isInString '..line..' '..j..' '..k..' : false')
				return false
			end
		end
	end
--DEBUG(Preproc isInString): print('isInString '..line..' '..j..' '..k..' : true')
	return true
end

local function overlaps(a, b)
	return a[1] <= b[2] and b[1] <= a[2]
end

-- largest to smalleste
local cSymbolEscs = table{
	'...',
	'>>=',
	'<<=',
	'||',
	'&&',
	'>=',
	'<=',
	'!=',
	'->',
	'##',
	'++',
	'--',
	'>',
	'<',
	'=',
	';',
	',',
	'?', ':',	-- is there a need to parse :: separately? for C++?  nah, not for the preprocessor's expressions.
	'#',
	'&', '|', '~', '^', '!',
	'.', '(', ')', '[', ']', '{', '}', '+', '-', '*', '/', '%',
}:sort(function(a,b) return #a > #b end)
:mapi(function(c) return '^'..string.patescape(c) end)


local Reader = class()
function Reader:setData(data)
	self.data = data
	self.index = 1
	self.tokens = table()	-- .token, .type, .space
	self:next()		-- prep next symbol as top
end

function Reader:next()
--DEBUG:print'GETTOKEN'
	if self.index > #self.data then
		if #self.tokens == 0
		or self.tokens:last().type ~= 'done'
		then
			self.tokens:insert{token='', type='done', space=''}
		end
--DEBUG:print'...done'
		return '', 'done', ''
	end

	local si1, si2 = self.data:find('^%s*', self.index)
assert(si1)
	local space = self.data:sub(si1, si2)
	self.index = si2 + 1
	-- TODO
	local ti1, ti2
	local tokentype
	if self.data:find('^[_%a]', self.index) then
		-- if we start as a word then read a word
		ti1, ti2 = self.data:find('^[_%a][_%w]*', self.index)
		tokentype = 'name'
	elseif self.data:find('^%d', self.index) then
		-- if we start as a number then read numbers
		ti1, ti2 = self.data:find('^%d[%w]*', self.index)
		tokentype = 'number'
	elseif self.data:find("^'", self.index) then
		ti1 = self.index
		ti2 = ti1 + 1
		if self.data:sub(ti2, ti2) == '\\' then ti2 = ti2 + 1 end
		ti2 = ti2 + 1
		assert.eq(self.data:sub(ti2, ti2), "'", 'at line '..self.data)
		tokentype = 'char'
	elseif self.data:find('^"', self.index) then
		-- read string ... ugly
		ti1 = self.index
		ti2 = self.index
		while true do
			ti2 = ti2 + 1
			if self.data:sub(ti2, ti2) == '\\' then
				ti2 = ti2 + 1
			elseif self.data:sub(ti2, ti2) == '"' then
				break
			end
		end
		tokentype = 'string'
	else
		-- see if it's a symbol, searching biggest to smallest
		for k,esc in ipairs(cSymbolEscs) do
			ti1, ti2 = self.data:find(esc, self.index)
			if ti1 then break end
		end
		assert(ti1, "failed to find any valid symbols at "..self.data:sub(self.index, self.index+20))
		tokentype = 'symbol'
	end
if not ti1 then error("failed to match at "..self.data:sub(self.index, self.index+20)) end
	local token = self.data:sub(ti1, ti2)
	self.index = ti2 + 1
	self.tokens:insert{token=token, type=tokentype, space=space}
--DEBUG:print('...next got', tolua(token), tolua(tokentype), tolua(space))
	return token, tokentype, space
end

function Reader:canbe(token)
	local last = self.tokens:last()
	if token == last.token then
		self:next()
		return last.token
	end
end

function Reader:mustbe(token)
	return assert(self:canbe(token))
end

function Reader:canbetype(tokentype)
	local last = self.tokens:last()
	if tokentype == last.type then
		self:next()
		return last.token
	end
end

function Reader:mustbetype(tokentype)
	return assert(self:canbetype(tokentype))
end

function Reader:replaceStack(startPos, endPos, ...)
	for i=startPos,endPos do
		assert(self.tokens:remove(startPos))
	end
	for i=select('#',...),1,-1 do
		self.tokens:insert(startPos, (select(i, ...)))
	end
end




--[[
argsonly = set to true to only expand macros that have arguments
useful for if evaluation

TODO THIS NEEDS TO HAVE STATE
in the latest stdio.h there is a multiple-line-spanning-macro, so I can't get around it any more

and that also might mean I need a tokenizer of some sort, to know when the parenthesis arguments begin and end
--]]
function Preproc:replaceMacros(l, macros, alsoDefined, checkingIncludeString, replaceEmptyWithZero)
	if l == '' then return l end

--DEBUG(Preproc:replaceMacros): print('replaceMacros begin: '..l)
	macros = macros or self.macros

	-- avoid infinite-recursive macros
	local alreadyReplaced = {}

--DEBUG:print('INIT DATA READER TO LINE', tolua(l))
	local r = Reader()
	r:setData(l)
	-- #tokens == 1 at first
	repeat
		local macroTop = #r.tokens		-- #r.tokens == 1 after first read
		local key = r.tokens:last().token
--DEBUG:print('last', tolua(r.tokens:last()))
		-- at first, #r.tokens == 1 here
		if alsoDefined and r:canbe'defined' then
			-- at first #r.tokens == 2 here, and look like {{'defined', ''}, {'(', ''}}
--DEBUG:print('got "defined", macroTop='..macroTop..', stack='..tolua(r.tokens))
assert.eq(r.tokens[#r.tokens-1].token, "defined")
			-- defined, parenthesis are optional
			local par = r:canbe'('
--DEBUG:print('searching for par?', not not par)

			-- TODO what about defined(A##B) , can you even do that?
			-- TODO HERE parse expressions, not just single macro names.  #define A || B is valid.
			local query = r:mustbetype'name'

			if par then r:mustbe')' end
			local parCloseTop = #r.tokens	-- get tokens before reading ')' so we know the true #r.tokens at ) before it might get an end and not add to the stack ...

			local repl = macros[query] and '1' or '0'
			-- replace with defined
			-- TODO but the next symbol is primsed so ...
			-- I need the same mechanism that buffers token/tokenhistory to also buffer spaces...
			-- and canbe/mustbe should also push into their own token history, not datareader's ...
--DEBUG:print('before replacing '..macroTop..'..'..parCloseTop..', stack='..tolua(r.tokens))
			r:replaceStack(macroTop, parCloseTop-1, {token=repl, type='number', space=' '})
--DEBUG:print('after replacing '..macroTop..'..'..parCloseTop..', stack='..tolua(r.tokens))

		-- C99
		elseif r:canbe'_Pragma' then
--DEBUG:print('got "_Pragma", stack', tolua(r.tokens))
assert.eq(r.tokens[#r.tokens-1].token, "_Pragma")
			-- defined, parenthesis are optional
			r:mustbe'('
			-- TODO macro expression processing
			-- TODO check balanced ( )
			local x = r:mustbetype'name'
			r:mustbe')'
			local parCloseTop = #r.tokens	-- get tokens before reading ')' so we know the true #r.tokens at ) before it might get an end and not add to the stack ...
			r:replaceStack(macroTop, parCloseTop-1)

		-- clang
		elseif r:canbe'__has_include' then
--DEBUG:print('got "__has_include", stack', tolua(r.tokens))
			local t1 = #r.tokens
			r:mustbe'('
			while not r:canbe')' do
				-- collect tokens into our include test
				r:next()
			end
			local parCloseTop = #r.tokens	-- get tokens before reading ')' so we know the true #r.tokens at ) before it might get an end and not add to the stack ...
			local x = r.tokens:sub(t1+1, parCloseTop-2):mapi(function(v) return v.space..v.token end):concat()
--DEBUG:print('__has_include', x)

			-- same as include_next
			local sys = true
			local fn = x:match'^<(.*)>$'
			if not fn then
				sys = false
				fn = x:match'^"(.*)"$'
				if not fn then
					error("__has_include expected file, got "..tolua(x).." in line: "..l)
				end
			end
			local repl = self:searchForInclude(fn, sys) and '1' or '0'
			r:replaceStack(macroTop, parCloseTop-1, {token=repl, type='number', space=' '})

		-- clang
		elseif r:canbe'__has_include_next' then
--DEBUG:print('got "__has_include_next", stack', tolua(r.tokens))
			local t1 = #r.tokens
			r:mustbe'('
			while not r:canbe')' do
				-- collect tokens into our include test
				r:next()
			end
			local parCloseTop = #r.tokens	-- get tokens before reading ')' so we know the true #r.tokens at ) before it might get an end and not add to the stack ...
			local x = r.tokens:sub(t1+1, parCloseTop-2):mapi(function(v) return v.space..v.token end):concat()
--DEBUG:print('__has_include_next', x)

			-- same as include_next
			local sys = true
			local fn = x:match'^<(.*)>$'
			if not fn then
				sys = false
				fn = x:match'^"(.*)"$'
				if not fn then
					error("include expected file: "..l)
				end
			end

			local foundPrevIncludeDir
			for i=#self.includeStack,1,-1 do
				local includeNextFile = self.includeStack[i]
				local dir, prevfn = path(includeNextFile):getdir()
				if prevfn.path == fn then
					foundPrevIncludeDir = dir.path
					break
				end
			end
			local repl = self:searchForInclude(fn, sys, foundPrevIncludeDir) and '1' or '0'

			r:replaceStack(macroTop, parCloseTop-1, {token=repl, type='number', space=' '})
		elseif r:canbetype'name' then
--DEBUG:print('canbename for macro expansion:', key)
::tryagain::
			-- TODO this inside define() etc macro conditions I guess?  include too, can you do #include MACRO ?
			local v = macros[key]
			if type(v) == 'table' then	-- then the macro has parameters
				-- TODO handle macro here
			elseif type(v) == 'string' then
				-- stupid windows hack
				if v == '' and replaceEmptyWithZero then v = '0' end
				-- TODO something about making sure names don't stick together or something, idk
				r.tokens[macroTop] = {token=v, type='name', space=' '}	-- TODO type is not classified.
				key = v
				if not alreadyReplaced[key] then
					alreadyReplaced[key] = true
					-- TODO something about repeated substitutions until all the macros are exhausted or something
					goto tryagain
				end
			elseif v ~= nil then
				error("macro had a bad type "..tolua(key).." = "..tolua(v))
			end

		-- TODO for #include's we want to handle < >
		-- but for #if expressions we want to evaluate < > as expression-trees
		-- so we cn't handle < include/path.h > here
		--[[
		elseif r:canbe'<' then
			-- read until > I guess, for include or whatever else
			-- can you do #include < MACRO > ?
			while not (r:canbe'>' or r:canbetype'done') do
				r:next()
			end
--DEBUG:print("done with <>'s, got:")
--DEBUG:print(tolua(r.tokens))
		--]]
		else
			r:next()
		end
	until r:canbetype'done'
--DEBUG:print('canbedone', r:canbetype'done')
local lorig = l
--DEBUG:print('BEFORE', l)
--DEBUG:print('tokens='..tolua(r.tokens))
	l = r.tokens:mapi(function(v) return v.space..v.token end):concat()
--DEBUG:print('AFTER', l)
--DEBUG:assert.eq(lorig, l)


-- TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO TODO
-- Get rid of the repeated find replace code below, and replace it with proper token based parser above

	local found
	repeat
		found = nil
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
--DEBUG(Preproc:replaceMacros): print('...but its in a previously-recursively-expanded location')
							else
--DEBUG(Preproc:replaceMacros): print('replacing with params', tolua(v))
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
--DEBUG(Preproc:replaceMacros): print('from', origl, 'to', l)
								-- sometimes you get #define x x ... which wants you to keep the original and not replace forever
								if l ~= origl then
									found = true
								end
								break
							end
						end
					else
						-- stupid windows hack
						if v == '' and replaceEmptyWithZero then v = '0' end

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
								if not before:match'[_%w]'
								and not after:match'[_%w]'
								then
--DEBUG(Preproc:replaceMacros): print('found macro', key)
									if alreadyReplaced[key]
									and overlaps(alreadyReplaced[key], {j,k})
									then
--DEBUG(Preproc:replaceMacros): print('...but its in a previously-recursively-expanded location')
										-- don't expand
									else
--DEBUG(Preproc:replaceMacros): print('replacing with', v)
										-- if the macro has params then expect a parenthesis after k
										-- and replace all the instances of v's params in v'def with the values in those parenthesis

										-- also when it comes to replacing macro params, C preproc uses () counting for the replacement
--DEBUG(Preproc:replaceMacros): local origl = l
										l = l:sub(1,j-1) .. v .. l:sub(k+1)
--DEBUG(Preproc:replaceMacros): print('from', origl, 'to', l)
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
--DEBUG(Preproc:replaceMacros): print('replaceMacros done: '..l)
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


function Preproc:parseCondInt(origexpr)
	local expr = origexpr

	assert(expr)
--DEBUG: print('evaluating condition:', expr)
	-- does defined() work with macros with args?
	-- if not then substitute macros with args here
	-- if so then substitute it in the eval of macros later ...
	--
	-- ok so Windows gl.h will have in their macro if statements `MACRO && stmt` where MACRO is #define'd to be an empty string
	-- so if we replace macros here then ... we get parse errors on the #if evaluation
	-- Windows ... smh
	-- so I've added a 5th arg to replaceMacros to substitute empty-strings with 0's .... sounds like a horrible idea ...
	-- ... that's right Windows, it was a horrible idea to implicitly cast empty string macros to zeroes in macro statements.
	expr = self:replaceMacros(expr, nil, true, nil, true)
--DEBUG: print('after macros:', expr)

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
--DEBUG: print('done')
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
--DEBUG: print('cur', cur)
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
				return result
			elseif canbe'%(' then
				local node = level1()
				mustbe'%)'
--DEBUG: print('got', tolua(result))
				return node

			-- have to handle 'defined' without () because it takes an implicit 1st arg
			elseif canbe'defined' then
				local name = mustbe(namepat)
				local result = {'number', castnumber(self.macros[namepat])}
--DEBUG: print('got', tolua(result))
				return result
			elseif canbe(namepat) then
				-- since we've already replaced all macros in the line, any unknown/remaining macro variable is going to evaluate to 0
				local result = {'number', 0}
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
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
--DEBUG: print('got', tolua(result))
				return result
			end
			return a
		end

		local parse = level1()

--DEBUG: print('got expression tree', tolua(parse))

		mustbe''

		cond = self:evalAST(parse)
--DEBUG: print('got cond', cond)

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
--DEBUG: print('line is', l, 'eval is', eval, 'preveval is', preveval)

				l = string.trim(l)	-- trailing space doesn't matter, right?
				if l:sub(1,1) == '#' then
					local cmd, rest = l:match'^#%s*(%S+)%s*(.-)$'
--DEBUG: print('cmd is', cmd, 'rest is', rest)

					-- another windows irritation ...
					if cmd then
						local j = cmd:find'%('
						if j then
							rest = cmd:sub(j)..' '..rest
							cmd = cmd:sub(1,j-1)
						end
					end


					local function closeIf()
						assert.gt(#ifstack, 0, 'found an #'..cmd..' without an #if')
						ifstack:remove()
					end

					if cmd == 'define' then
						if eval then
							local k, params, paramdef = rest:match'^(%S+)%(([^)]*)%)%s*(.-)$'
							if k then
								assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
--DEBUG: print('defining with params',k,params,paramdef)

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
									-- for debugging
									-- should this just be the filename+line, or the include-stack to the file too?
--DEUBG:							stack = table(self.includeStack),
								}, l)
							else

								local k, v = rest:match'^(%S+)%s+(.-)$'
								if k then
									assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
--DEBUG: print('defining value',k,v)
									-- [[ evaluate macros of v?
									-- and skip previous lines
									self.foundIncompleteMacroWarningMessage = nil
									--v = self:replaceMacros(v)
									-- no, that'll be done in getDefineCode (right?()
									--]]
								else
									k = rest
									v = ''
									assert.ne(k, '', "couldn't find what you were defining: "..l)
									assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
--DEBUG: print('defining empty',k,v)
								end

								--TODO lines[i] = ...
								-- and then incorporate the enim {} into the code
								lines[i] = self:getDefineCode(k, v, l)
--DEBUG: print('line is', l)
							end
						else
							lines:remove(i)
							i = i - 1
						end
					elseif cmd == 'if'
					or cmd == 'elif'
					then
--DEBUG: print('if/elif with eval', eval, 'preveval', preveval)
						local hasprocessed = false
						if cmd == 'elif' then
--DEBUG: print('closing via elif, #ifstack', require'ext.tolua'(ifstack))
							local oldcond = ifstack:last()
							hasprocessed = oldcond[1] or oldcond[2]
							closeIf()
						end

--DEBUG: print('hasprocessed', hasprocessed)
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
--DEBUG: print('elif skipping cond evaluation')
								cond = false
							else
								cond = self:parseCondExpr(rest)
								assert(cond ~= nil, "cond must be true or false")
							end
						end
--DEBUG: print('got cond', cond, 'from', rest)
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
--DEBUG: print('ifdef looking for '..rest)
						assert(isvalidsymbol(rest))
						local cond = not not self.macros[rest]
--DEBUG: print('got cond', cond)
						ifstack:insert{cond, false}

						lines:remove(i)
						i = i - 1
					elseif cmd == 'ifndef' then
--DEBUG: print('ifndef looking for', rest)
						assert(isvalidsymbol(rest), "tried to check ifndef a non-valid symbol "..tolua(rest))
						local cond = not self.macros[rest]
--DEBUG: print('got cond', cond)
						ifstack:insert{cond, false}

						lines:remove(i)
						i = i - 1
					elseif cmd == 'endif' then
						assert.eq(rest, '', "found trailing characters after "..cmd)
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
--DEBUG: print('include_next search fn='..tostring(fn)..' sys='..tostring(sys))
							-- search through the include stack for the most recent file with the name of what we're looking for ...
							local foundPrevIncludeDir
							for i=#self.includeStack,1,-1 do
								local includeNextFile = self.includeStack[i]
								local dir, prevfn = path(includeNextFile):getdir()
--DEBUG: print(includeNextFile, dir, prevfn)
								if prevfn.path == fn then
									foundPrevIncludeDir = dir.path
									break
								end
							end
--DEBUG: print('foundPrevIncludeDir '..tostring(foundPrevIncludeDir))
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
--DEBUG: print('include_next '..fn)
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
-- [=[ or should I just store lines for now, eval later (so that macro arguments can span multiple lines)
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
--DEBUG: print('/* ### PREPENDING ### ' .. prevIncompleteMacroLine .. ' ### TO ### ' .. l..' */')
							--[[ keep?
							lines[i-1] = '// '..lines[i-1]
							--]]
							-- [[ remove
							lines:remove(i-1)
							i = i - 1
							--]]

							--[[ if you want debug output in the file ...
							lines:insert(i, '/* ### PREPENDING ### '
								..prevIncompleteMacroLine:gsub('/%*', '/ *'):gsub('%*/', '* /')
								.. ' ### TO ### '
								..l:gsub('/%*', '/ *'):gsub('%*/', '* /')
								..' */')
							i = i + 1
							--]]

							l = prevIncompleteMacroLine .. ' ' .. l
							-- try to replace the macros ...
							local nl = self:replaceMacros(l)
							-- if replace didn't work and we're still in the middle of a macro then use the un-replaced version ...
							if self.foundIncompleteMacroLine then
								self.foundIncompleteMacroLine = l
								-- [[ keep?
								lines[i] = '// '..l
								--]]
								--[[ empty?
								-- neither keep nor empty seems to matter since the next pass it gets removed anyways
								lines[i] = ''
								--]]
								--[[ remove?
								-- this will break since the next pass removes it ...
								lines:remove(i)
								i = i - 1
								--]]
							else
								-- otherwise use it
								lines[i] = nl
							end
						else
							local nl = self:replaceMacros(l)
							if nl ~= l then
								lines[i] = nl
							end
						end
--]=]
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

	--[[ join lines that don't end in a semicolon or comment
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
