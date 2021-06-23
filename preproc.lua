local string = require 'ext.string'
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local os = require 'ext.os'
local file = require 'ext.file'
local class = require 'ext.class'


local function isvalidsymbol(s)
	return not not s:match'^[_%a][_%w]*$'
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

	-- remove all // \n blocks first
	repeat
		local i = code:find('//',1,true)
		if not i then break end
		local j = code:find('\n',i+2,true) or #code
		code = code:sub(1,i-1)..code:sub(j+1)
	until false
	
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

function Preproc:replaceMacros(l, macros)
	macros = macros or self.macros
	local found
	repeat
		found = nil
		for key,v in pairs(macros) do
			if type(v) == 'table' then
				local pat = key..'%s*(%b())'
				local j,k = l:find(pat)
				if j then
					local before = l:sub(j-1,j-1)
					if not before:match'[_a-zA-Z0-9]' then
						local paramStr = l:sub(j,k):match(pat)
						paramStr = paramStr:sub(2,-2)	-- strip outer ()'s
						-- so now split by commas, but ignore commas that are out of balance with parenthesis
						local parcount = 0
						local paramIndex = 0
						local last = 1
						local paramMap = {}
						for i=1,#paramStr do
							local ch = paramStr:sub(i,i)
							if ch == '(' then
								parcount = parcount + 1
							elseif ch == ')' then
								parcount = parcount - 1
							elseif ch == ',' then
								if parcount == 0 then
									local paramvalue = paramStr:sub(last, i-1)
									paramIndex = paramIndex + 1
									paramMap[v.params[paramIndex]] = paramvalue
									last = i + 1
								end
							end
						end
						if parcount ~= 0 then
							error("macro mismatched ()'s")
						end
						local paramvalue = paramStr:sub(last)
						paramIndex = paramIndex + 1
						paramMap[v.params[paramIndex]] = paramvalue
						
						assert(paramIndex == #v.params, "macro expected "..#v.params.."  but found "..paramIndex)

						-- now replace all of v.params strings with params
						local def = self:replaceMacros(v.def, paramMap)

						l = l:sub(1,j-1) .. ' ' .. def .. ' ' .. l:sub(k+1)
					end
				end
			else
				local j,k = l:find(key)
				if j then 
print('found macro '..key)
					-- make sure the symbol before and after is not a name character
					local before = l:sub(j-1,j-1)
					local after = l:sub(k+1,k+1)
					if not before:match'[_a-zA-Z0-9]'
					and not after:match'[_a-zA-Z0-9]'
					then
print('replacing', key, v)
						
						-- if the macro has params then expect a parenthesis after k
						-- and replace all the instances of v's params in v'def with the values in those parenthesis

						-- also when it comes to replacing macro params, C preproc uses () counting for the replacement

						l = l:sub(1,j-1) .. ' ' .. v .. ' ' .. l:sub(k+1)
						found = true
					end
				end
			end
		end
	until not found
	return l
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
					if b == false then
						eval = false
						break
					end
				end
			end
print('eval is', eval, 'line is', l)

			if l:sub(1,1) == '#' then
				l = string.trim(l)	-- trailing space doesn't matter, right?
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
print('defining',k,v)
							
-- [[ what if we're defining a macro with args?
-- at this point I probably need to use a parser on #if evaluations			

							params = string.split(params, ','):mapi(string.trim)
							for i,param in ipairs(params) do
								assert(isvalidsymbol(param), "macro param #"..i.." is an invalid name")
							end
						
							self.macros[k] = {
								params = params,
								def = paramdef,
							}
						else
						
							local k, v = rest:match'^(%S+)%s+(.-)$'
							if k then
								assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
print('defining',k,v)
								self.macros[k] = v
							else
								local k = rest
								v = ''
								assert(k ~= '', "couldn't find what you were defining: "..l)
								assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
								
print('defining',k,v)
								self.macros[k] = v
							end
						end
						--if it is a number define
						local isnumber = tonumber(v)	-- TODO also check valid suffixes?
						if isnumber then
print('line was', l)
							l = 'enum { '..k..' = '..v..' };'
							lines[i] = l
print('line is', l)
						else
							lines:remove(i)
							i = i - 1
						end
					else
						lines:remove(i)
						i = i - 1
					end
				elseif cmd == 'if' 
				or cmd == 'elif'
				then
					if cmd == 'elif' then
						closeIf()
					end

print('evaluating condition:', rest)
					local condcode = self:replaceMacros(rest)
print('after macro replace:', condcode)

					-- just lua it
					local luacondcode = 'return '
						..condcode
							:gsub('&&', ' and ')
							:gsub('||', ' or ')
							:gsub('!=', '~=')
							:gsub('!', ' not ')
							:gsub('(%d+)L?', '%1')
print('as lua cond code', luacondcode)						
					local condenv = setmetatable({
						defined = function(k)
							local v = self.macros[k]
							if type(v) == 'string' then 
								return v
							-- if it is a macro with args
							elseif type(v) == 'table' then
								return function(...)
									local repl = v.def
									for i,param in ipairs(v.params) do
										repl = repl:gsub(param, select(i, ...))
									end
									return repl
								end
							end
						end,
					},{
						__index = function(t,k)
							-- lua will auto convert strings of numbers to the number values when comparing
							-- but what about empty macros? 
							-- in those cases, when performing binary operations, C preproc will replace the macro value with zero
							-- ... so how do I do that ... 
							-- I could return an object wrapping the value
							-- but how would and or not work with wrappers, esp with luajit that doesn't allow metamethods of these? actually neither does lua 5.4 -- only bitwise overloads.
							-- I might actually have to parse this for it to work correclty.
							return self.macros[k]
						end,
					})
					local cond = assert(load(luacondcode, nil, nil, condenv))() or false
print('got cond', cond)
					ifstack:insert(cond)
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'ifdef' then
print('ifdef looking for '..rest)
					assert(isvalidsymbol(rest))
					local cond = not not self.macros[rest]
print('got cond', cond)						
					ifstack:insert(cond)
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'else' then
					assert(rest == '', "found trailing characters after "..cmd)
					local n = #ifstack
					ifstack[n] = not ifstack[n]
					lines:remove(i)
					i = i - 1				
				elseif cmd == 'ifndef' then
print('ifndef looking for', rest)						
					assert(isvalidsymbol(rest))
					local cond = not self.macros[rest]						
print('got cond', cond)						
					ifstack:insert(cond)
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'endif' then
					assert(rest == '', "found trailing characters after "..cmd)
					closeIf()
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
						lines:insert(i, '/* END '..fn..' */')
						if not self.alreadyIncludedFiles[fn] then
							-- at position i, insert the file
							local newcode = assert(file[fn], "couldn't find file "..fn)

							newcode = removeCommentsAndApplyContinuations(newcode)	
							local newlines = string.split(newcode, '\n')
							
							while #newlines > 0 do
								lines:insert(i, newlines:remove())
							end
							
							self.includeStack:insert(fn)
						end
						lines:insert(i, '/* BEGIN '..fn..' */')
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
		print(err..'\n'..debug.traceback())
		os.exit(1)
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
