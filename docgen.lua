--[=[
@c ClassName [x base_1 x base_2 ... x base_n]
@t tag (one of: ui, abc)
@p parameterName type
@op optionalParameterName type
@d class description+
]=]

--[=[
@m methodName
@t tag (one of: static)
@p parameterName type
@op optionalParameterName type
@r return
@d description+
]=]

--[=[
@p propertyName type description+
]=]

local fs = require('fs')
local pathjoin = require('pathjoin')

local insert, sort, concat = table.insert, table.sort, table.concat
local format = string.format
local pathJoin = pathjoin.pathJoin

local function scan(dir)
	for fileName, fileType in fs.scandirSync(dir) do
		local path = pathJoin(dir, fileName)
		if fileType == 'file' then
			coroutine.yield(path)
		else
			scan(path)
		end
	end
end

local function match(s, pattern) -- only useful for one capture
	return assert(s:match(pattern), s)
end

local function gmatch(s, pattern, hash) -- only useful for one capture
	local tbl = {}
	if hash then
		for k in s:gmatch(pattern) do
			tbl[k] = true
		end
	else
		for v in s:gmatch(pattern) do
			insert(tbl, v)
		end
	end
	return tbl
end

local function matchType(s)
	return s:match('^@(%S+)')
end

local function matchComments(s)
	return s:gmatch('--%[=%[%s*(.-)%s*%]=%]')
end

local function matchClassName(s)
	return match(s, '@c (%S+)')
end

local function matchMethodName(s)
	return match(s, '@m (%S+)')
end

local function matchDescription(s)
	return match(s, '@d (.+)'):gsub('%s+', ' ')
end

local function matchParents(s)
	return gmatch(s, 'x (%S+)')
end

local function matchReturns(s)
	return gmatch(s, '@r (%S+)')
end

local function matchTags(s)
	return gmatch(s, '@t (%S+)', true)
end

local function matchProperty(s)
	local a, b, c = s:match('@p (%S+) (%S+) (.+)')
	return {
		name = assert(a, s),
		type = assert(b, s),
		desc = assert(c, s):gsub('%s+', ' '),
	}
end

local function matchParameters(s)
	local ret = {}
	for optional, paramName, paramType in s:gmatch('@(o?)p (%S+) (%S+)') do
		insert(ret, {paramName, paramType, optional == 'o'})
	end
	return ret
end

local function matchMethod(s)
	return {
		name = matchMethodName(s),
		desc = matchDescription(s),
		parameters = matchParameters(s),
		returnTypes = matchReturns(s),
		tags = matchTags(s),
	}
end

----

local docs = {}

local function newClass()

	local class = {
		methods = {},
		statics = {},
		properties = {},
	}

	local function init(s)
		class.name = matchClassName(s)
		class.parents = matchParents(s)
		class.desc = matchDescription(s)
		class.parameters = matchParameters(s)
		class.tags = matchTags(s)
		assert(not docs[class.name], 'duplicate class: ' .. class.name)
		docs[class.name] = class
	end

	return class, init

end

for f in coroutine.wrap(scan), './libs' do

	local d = assert(fs.readFileSync(f))

	local class, initClass = newClass()
	for s in matchComments(d) do
		local t = matchType(s)
		if t == 'c' then
			initClass(s)
		elseif t == 'm' then
			local method = matchMethod(s)
			insert(method.tags.static and class.statics or class.methods, method)
		elseif t == 'p' then
			insert(class.properties, matchProperty(s))
		end
	end

end

----

local output = 'docs'

local function link(str)
	if type(str) == 'table' then
		local ret = {}
		for i, v in ipairs(str) do
			ret[i] = link(v)
		end
		return concat(ret, ', ')
	else
		local ret = {}
		for t in str:gmatch('[^/]+') do
			insert(ret, docs[t] and format('[[%s]]', t) or t)
		end
		return concat(ret, '/')
	end
end

local function sorter(a, b)
	return a.name < b.name
end

local function writeHeading(f, heading)
	f:write('## ', heading, '\n\n')
end

local function writeProperties(f, properties)
	sort(properties, sorter)
	f:write('| Name | Type | Description |\n')
	f:write('|-|-|-|\n')
	for _, v in ipairs(properties) do
		f:write('| ', v.name, ' | ', link(v.type), ' | ', v.desc, ' |\n')
	end
	f:write('\n')
end

local function writeParameters(f, parameters)
	f:write('(')
	local optional
	if #parameters > 0 then
		for i, param in ipairs(parameters) do
			f:write(param[1])
			if i < #parameters then
				f:write(', ')
			end
			if param[3] then
				optional = true
			end
		end
		f:write(')\n\n')
		if optional then
			f:write('| Parameter | Type | Optional |\n')
			f:write('|-|-|:-:|\n')
			for _, param in ipairs(parameters) do
				local o = param[3] and '✔' or ''
				f:write('| ', param[1], ' | ', link(param[2]), ' | ', o, ' |\n')
			end
			f:write('\n')
		else
			f:write('| Parameter | Type |\n')
			f:write('|-|-|\n')
			for _, param in ipairs(parameters) do
				f:write('| ', param[1], ' | ', link(param[2]), ' |\n')
			end
			f:write('\n')
		end
	else
		f:write(')\n\n')
	end
end

local function writeMethods(f, methods)
	sort(methods, sorter)
	for _, method in ipairs(methods) do
		f:write('### ', method.name)
		writeParameters(f, method.parameters)
		f:write(method.desc, '\n\n')
		f:write('**Returns:** ', link(method.returnTypes), '\n\n----\n\n')
	end
end

if not fs.existsSync(output) then
	fs.mkdirSync(output)
end

local function collectParents(class, k, ret, seen)
	ret = ret or {}
	seen = seen or {}
	for _, parent in ipairs(class.parents) do
		parent = docs[parent]
		if parent then
			for _, v in ipairs(parent[k]) do
				if not seen[v] then
					seen[v] = true
					insert(ret, v)
				end
			end
		end
		collectParents(parent, k, ret, seen)
	end
	return ret
end

for _, class in pairs(docs) do

	local f = io.open(pathJoin(output, class.name .. '.md'), 'w')

	if next(class.parents) then
		f:write('#### *extends ', link(class.parents), '*\n\n')
	end

	f:write(class.desc, '\n\n')

	if class.tags.ui then
		writeHeading(f, 'Constructor')
		f:write('### ', class.name)
		writeParameters(f, class.parameters)
	else
		f:write('*Instances of this class should not be constructed by users.*\n\n')
	end

	local properties = collectParents(class, 'properties')
	if next(properties) then
		writeHeading(f, 'Properties Inherited ' .. link(class.parents))
		writeProperties(f, properties)
	end

	if next(class.properties) then
		writeHeading(f, 'Properties')
		writeProperties(f, class.properties)
	end

	local statics = collectParents(class, 'statics')
	if next(statics) then
		writeHeading(f, 'Static Methods Inherited From ' .. link(class.parents))
		writeMethods(f, statics)
	end

	local methods = collectParents(class, 'methods')
	if next(methods) then
		writeHeading(f, 'Methods Inherited From ' .. link(class.parents))
		writeMethods(f, methods)
	end

	if next(class.statics) then
		writeHeading(f, 'Static Methods')
		writeMethods(f, class.statics)
	end

	if next(class.methods) then
		writeHeading(f, 'Methods')
		writeMethods(f, class.methods)
	end

	f:close()

end
