local string = require 'ext.string'
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local class = require 'ext.class'


local function isvalidsymbol(s)
	return not not s:match'^[_%a][_%w]*$'
end

-- remove all /* */ blocks first
local function removeComments(code)
	repeat
		local i = code:find('/*',1,true)
		if not i then break end
		local j = code:find('*/',i+2,true)
		if not j then
			error("found /* with no */")
		end
		code = code:sub(1,i-1)..code:sub(j+2)
	until false
	return code
end


local Preproc = class()

function Preproc:searchForInclude(fn)
	for _,d in ipairs(self.includeDirs) do
		local p = d..'/'..fn
		if os.fileexists(p) then
			return p
		end
	end
end

--[[
Preproc(code)
Preproc(args)
args = table of:
	code = code to use
	includeDirs = include directories to use
	macros = macros to use
--]]
function Preproc:init(args)
	if type(args) == 'string' then
		args = {code=args}
	elseif type(args) ~= 'table' then
		error("can't handle args")
	end

	local code = assert(args.code, "expected code")

	self.includeDirs = table(args.includeDirs)
	for _,k in ipairs{'HOME', 'USERPROFILE'} do
		local v = os.getenv(k)
		if v then
			self.includeDirs:insert((v:gsub('\\', '/')..'/include/'))
		end
	end




	code = removeComments(code)	
	local lines = string.split(code, '\n')

	self.defines = table(args.defines):setmetatable(nil)

	local ifstack = table()
	local i = 1
	xpcall(function()
		while i < #lines do
			local l = lines[i]

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
--print('eval is', eval, 'line is', l)

			if l:sub(1,1) == '#' then
				l = string.trim(l)	-- trailing space doesn't matter, right?
				local cmd, rest = l:match'^#%s*(%S+)%s*(.-)$'
--print('cmd is', cmd, 'rest is', rest)				
				
				local function closeIf()
					assert(#ifstack > 0, 'found an #'..cmd..' without an #if')
					ifstack:remove()
				end

				if cmd == 'define' then
					if eval then
						local k, v = rest:match'^(%S+)%s+(.-)$'
						if k then
							assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
							--print('defining',k,v)
							self.defines[k] = v
						else
							local k = rest
							local v = ''
							assert(k ~= '', "couldn't find what you were defining: "..l)
							assert(isvalidsymbol(k), "tried to define an invalid macro name: "..tolua(k))
							
							--print('defining',k,v)
							self.defines[k] = v
						end
						--if it is a number define
						local isnumber = tonumber(v)	-- TODO also check valid suffixes?
						if isnumber then
--print('line was', l)
							l = 'enum { '..k..' = '..v..' };'
							lines[i] = l
--print('line is', l)
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

					-- just lua it
--print('evaluating condition:', rest)
					local luacondcode = 'return '
						..rest
							:gsub('&&', ' and ')
							:gsub('||', ' or ')
							:gsub('!', ' not ')
							:gsub('(%d+)L?', '%1')
--print('as lua cond code', luacondcode)						
					local cond = assert(load(luacondcode, nil, nil, {
							defined = function(k)
								return 
									--not not
									self.defines[k]
							end,
						}))() or false
--print('got cond', cond)
					ifstack:insert(cond)
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'ifdef' then
--print('ifdef looking for '..rest)
					assert(isvalidsymbol(rest))
					local cond = not not self.defines[rest]
--print('got cond', cond)						
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
--print('ifndef looking for', rest)						
					assert(isvalidsymbol(rest))
					local cond = not self.defines[rest]						
--print('got cond', cond)						
					ifstack:insert(cond)
					
					lines:remove(i)
					i = i - 1
				elseif cmd == 'endif' then
					assert(rest == '', "found trailing characters after "..cmd)
					closeIf()
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
						error("couldn't find the file in include "..l)
					end
					
					lines:remove(i)
					if eval then
						fn = self:searchForInclude(fn, sys)
						local newcode = assert(file[fn], "couldn't find file "..f)
						
						newcode = removeComments(newcode)	
						local newlines = string.split(newcode, '\n')
						
						lines:insert(i, '// END '..l)
						while #newlines > 0 do
							lines:insert(i, newlines:remove())
						end
						lines:insert(i, '// BEGIN '..l)

						-- at position i, insert the file
					end
					i = i - 1
				else
					error("can't handle that preprocessor yet: "..l)
				end
			else
				if eval == false then
					lines:remove(i)
					i = i - 1
				else
					for k,v in pairs(self.defines) do
						repeat
							local j = l:find(k,j,true)
							if not j then break end
--print('found macro '..k)
							-- make sure the symbol before and after is not a name character
							local before = l:sub(j-1,j-1)
							local after = l:sub(j+#k,j+#k)
							if not before:match'[_a-zA-Z0-9]'
							and not after:match'[_a-zA-Z0-9]'
							then
--print('replacing', k, v)
--print('line was', l)
								l = l:sub(1,j-1) .. ' ' .. v .. ' ' .. l:sub(j+#k)
								lines[i] = l
--print('line is', l)							
							else
								break	-- failed to find any matches - bail out
							end
						until false
					end
				end
			end
			i = i + 1
		end
	end, function(err)
		print(require 'template.showcode'(lines:sub(1, i+10):concat'\n'))
		print('at line: '..i)
		print(err..'\n'..debug.traceback())
		os.exit(1)
	end)

	code = lines:concat'\n'
	
	self.code = code
end

function Preproc:__tostring()
	return self.code
end

function Preproc.__concat(a,b)
	return tostring(a) .. tostring(b)
end

return Preproc
