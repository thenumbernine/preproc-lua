local string = require 'ext.string'
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local os = require 'ext.os'
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
	includeDirs = include directories to use
	macros = macros to use
--]]
function Preproc:init(args)
	if args ~= nil then
		self(args)
	end
	self.macros = {}
	self.alreadyIncludedFiles = {}

	self.includeDirs = table()

	local incenv = os.getenv'INCLUDE'
	if incenv then
		self:addIncludeDirs(string.split(incenv, ';'))
	end
end

function Preproc:setMacros(args)
	for k,v in pairs(args) do
		self.macros[k] = v
	end
end

function Preproc:addIncludeDir(dir)
	-- should I fix paths of the user-provided includeDirs? or just INCLUDE?
	dir = dir:gsub('\\', '/')
	self.includeDirs:insert(dir)
end

function Preproc:addIncludeDirs(dirs)
	for _,dir in ipairs(dirs) do
		self:addIncludeDir(dir)
	end
end

function Preproc:searchForInclude(fn)
	for _,d in ipairs(self.includeDirs) do
		local p = d..'/'..fn
		p = p:gsub('//', '/')
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

print('found macro', key)
print('replacing from params '..tolua(vparams))	
	
	local paramStr = l:sub(j,k):match(pat)
	paramStr = paramStr:sub(2,-2)	-- strip outer ()'s
print('found paramStr', paramStr)	
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
print('substituting the '..paramIndex..'th macro from key '..tostring(macrokey)..' to value '..paramvalue)
		paramMap[macrokey] = paramvalue
	end
	
	assert(paramIndex == #vparams, "expanding macro "..key.." expected "..#vparams.." "..tolua(vparams).." params but found "..paramIndex..": "..tolua(paramMap))

	return j, k, paramMap
end

--[[
argsonly = set to true to only expand macros that have arguments
useful for if evaluation
--]]
function Preproc:replaceMacros(l, macros, alsoDefined)
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
				if j then
					local def = macros[query] and 1 or 0
					l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
					found = true
				end
			end
		end
		if not found then
			for key,v in pairs(macros) do
				if type(v) == 'table' then
					local j, k, paramMap = handleMacroWithArgs(l, macros, key, v.params)
					if j then
print('replacing with params', tolua(v))
						-- now replace all of v.params strings with params
						local def = self:replaceMacros(v.def, paramMap, alsoDefined)
-- TODO space or nospace?
-- nospace = good for ## operator
-- space = good for subsequent tokenizer after replacing A()B(), to prevent unnecessary merges
def = def:gsub('##', '')						
						l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
						found = true
						break
					end
				else
					local j,k = l:find(key)
					if j then 
						-- make sure the symbol before and after is not a name character
						local before = l:sub(j-1,j-1)
						-- technically no need to match 'after' since the greedy match would have included it, right?
						-- same for 'before' ?
						local after = l:sub(k+1,k+1)
						if not before:match'[_a-zA-Z0-9]'
						and not after:match'[_a-zA-Z0-9]'
						then
print('found macro', key)
print('replacing with', v)
							
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
	if t[1] == 'defined' then
		return self.macros[t[2]] and 1 or 0
	elseif t[1] == 'macro' then
		local v = self.macros[t[2]]
		if v then
			v = self:replaceMacros(v)
			v = tonumber(v) or v
		end
		-- should this always evaluate to a number?
print('replacing', t[2],' with ',v)				
		return castnumber(v)
	elseif t[1] == 'number' then
		return assert(tonumber(t[2]), "failed to parse number "..tostring(t[2]))
	elseif t[1] == '!' then
		return castnumber(self:evalAST(t[2])) == 0 and 1 or 0
	elseif t[1] == '&&' then
		if castnumber(self:evalAST(t[2])) ~= 0
		and castnumber(self:evalAST(t[3])) ~= 0
		then 
			return 1 
		end
		return 0
	elseif t[1] == '||' then
		if self:evalAST(t[2]) ~= 0
		or self:evalAST(t[3]) ~= 0
		then 
			return 1 
		end
		return 0
	elseif t[1] == '&' then
		return bit.band(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '|' then
		return bit.bor(
			castnumber(self:evalAST(t[2])),
			castnumber(self:evalAST(t[3]))
		)
	elseif t[1] == '==' then
		return (castnumber(self:evalAST(t[2])) == castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '>=' then
		return (castnumber(self:evalAST(t[2])) >= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '<=' then
		return (castnumber(self:evalAST(t[2])) <= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '!=' then
		return (castnumber(self:evalAST(t[2])) ~= castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '>' then
		return (castnumber(self:evalAST(t[2])) > castnumber(self:evalAST(t[3]))) and 1 or 0
	elseif t[1] == '<' then
		return (castnumber(self:evalAST(t[2])) < castnumber(self:evalAST(t[3]))) and 1 or 0
	else
		error("don't know how to handle this ast entry "..t[1])
	end
end



function Preproc:parseCondInt(expr)
	local expr = expr
assert(expr)
print('evaluating condition:', expr)
	
	-- does defined() work with macros with args?
	-- if not then substitute macros with args here
	-- if so then substitute it in the eval of macros later ...
expr = self:replaceMacros(expr, nil, true)
print('after macros:', expr)

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

		local decpat = '%d+[Ll]?'
		local hexpat = '0x%x+'

		local prev, cur
		local function next()
			skipwhitespace()
			if col > #expr then 
print('done')				
				cur = ''
				return cur
			end

			for _,pat in ipairs{
				namepat,
				hexpat,
				decpat,
				'&&',
				'||',
				'==',
				'>=',
				'<=',
				'!=',
				'>',
				'<',
				'!',
				'&',
				'|',
				'%(',
				'%)',
				',',
			} do
				local symbol = readnext(pat)
				if symbol then 
					cur = symbol
print('cur', cur)					
					return symbol 
				end
			end	

			error("couldn't understand token here: "..expr:sub(cur))
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

		local function level4()
			if canbe'!' then
				local a = level4()
				local result = {'!', a}
print('got', tolua(result))
				return result
			elseif canbe(decpat) or canbe(hexpat) then
				local dec = prev:match'(%d+)[Ll]?'
				local val
				if dec then
					val = assert(tonumber(dec), "expected number")	-- decimal number
				else
					val = assert(tonumber(prev), "expected number")	-- hex number
				end
				assert(val)
				local result = {'number', val}
print('got', tolua(result))
				return result
			elseif canbe'%(' then
				local node = level1()
				mustbe'%)'
print('got', tolua(result))				
				return node
			
			-- have to handle 'defined' without () because it takes an implicit 1st arg
			elseif canbe'defined' then
				local name = mustbe(namepat)
				local result = {'number', castnumber(self.macros[namepat])}
print('got', tolua(result))
				return result
			elseif canbe(namepat) then
				local result = {'number', 0}
print('got', tolua(result))
				return result
			else
				error("failed to parse expression: "..cur)
			end
		end

		local function level3()
			local a = level4()
			if canbe'==' 
			or canbe'!='
			or canbe'>='
			or canbe'<='
			or canbe'>'
			or canbe'<'
			then
				local op = prev
				local b = level3()
				local result = {op, a, b}
print('got', tolua(result))				
				return result
			end
			return a
		end

		local function level2()
			local a = level3()
			if canbe'||' 
			or canbe'&&' 	
			then
				local op = prev
				local b = level2()
				local result = {op, a, b}
print('got', tolua(result))				
				return result
			end
			return a
		end

		level1 = function()
			local a = level2()
			if canbe'|' 
			or canbe'&' 	
			then
				local op = prev
				local b = level1()
				local result = {op, a, b}
print('got', tolua(result))				
				return result
			end
			return a	
		end

		local parse = level1()

print('got expression tree', tolua(parse))

		mustbe''

		cond = self:evalAST(parse)
print('got cond', cond)

	end, function(err)
		rethrow = 
			' at col '..col..'\n'
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

	if args.includeDirs then
		self:addIncludeDirs(args.includeDirs)
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
print('eval is', eval, 'line is', l)

			l = string.trim(l)	-- trailing space doesn't matter, right?
			if l:sub(1,1) == '#' then
				local cmd, rest = l:match'^#%s*(%S+)%s*(.-)$'
print('cmd is', cmd, 'rest is', rest)				
				
				local function closeIf()
					assert(#ifstack > 0, 'found an #'..cmd..' without an #if')
					ifstack:remove()
				end

				if cmd == 'define' then
					if eval then
						
						local k, params, paramdef = rest:match'^(%S+)%(([^)]*)%)%s*(.-)$'
						if k then
							assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
print('defining with params',k,params,paramdef)
							
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
print('defining value',k,v)
								self.macros[k] = v
							else
								local k = rest
								v = ''
								assert(k ~= '', "couldn't find what you were defining: "..l)
								assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
								
print('defining empty',k,v)
								self.macros[k] = v
							end
						
							--if it is a number define
							local isnumber = tonumber(v)	-- TODO also check valid suffixes?
							if isnumber then
print('line was', l)
								if self.macros[k] then
									if self.macros[k] ~= v then
										print('warning: redefining '..k)
									end
									lines:remove(i)
									i = i - 1
								else
									l = 'enum { '..k..' = '..v..' };'
									lines[i] = l
								end
print('line is', l)
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
								lines:remove(i)
								i = i - 1
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
print('got cond', cond)
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
print('ifdef looking for '..rest)
					assert(isvalidsymbol(rest))
					local cond = not not self.macros[rest]
print('got cond', cond)						
					ifstack:insert{cond, false}
					
					lines:remove(i)
					i = i - 1			
				elseif cmd == 'ifndef' then
print('ifndef looking for', rest)						
					assert(isvalidsymbol(rest), "tried to check ifndef a non-valid symbol "..tolua(rest))
					local cond = not self.macros[rest]						
print('got cond', cond)						
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
				elseif cmd == 'include' then
					local sys = true
					local fn = rest:match'^<(.*)>$'
					if not fn then
						sys = false
						fn = rest:match'^"(.*)"$'
					end
					if not fn then
						error("include expected file: "..l)
					end
					
					lines:remove(i)
					if eval then
						local search = fn
						fn = self:searchForInclude(fn, sys)
						if not fn then
							error("couldn't find include file "..search)
						end
						if not self.alreadyIncludedFiles[fn] then
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
print('line was', l)
						lines[i] = nl
print('line is', l)							
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
