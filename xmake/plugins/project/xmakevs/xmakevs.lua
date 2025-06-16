--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      OpportunityLiu
-- @file        vsxmake.lua
--

-- imports
import("core.base.option")
import("core.base.hashset")
import("vstudio.impl.vsinfo", { rootdir = path.directory(os.scriptdir()) })
import("render")
import("getinfo")
import("core.project.config")
import("core.cache.localcache")
import("vstudio.impl.vsutils", {rootdir = path.join(os.programdir(), "plugins", "project")})

local template_root = path.join(os.programdir(), "scripts", "xmakevs", "vsproj", "templates")
local template_sln = path.join(template_root, "sln", "vsxmake.sln")
local template_vcx = path.join(template_root, "vcxproj", "#target#.vcxproj")

local template_fil = path.join(template_root, "vcxproj.filters", "#target#.vcxproj.filters")
local template_props = path.join(template_root, "Xmake.Custom.props")
local template_targets = path.join(template_root, "Xmake.Custom.targets")
local template_items = path.join(template_root, "Xmake.Custom.items")
local template_itemfil = path.join(template_root, "Xmake.Custom.items.filters")

function _filter_files(files, includeexts, excludeexts)
    local positive = not excludeexts
    local extset = hashset.from(positive and includeexts or excludeexts)
    local f = {}
    for _, file in ipairs(files) do
        local ext = path.extension(file)
        if (positive and extset:has(ext)) or not (positive or extset:has(ext)) then
            table.insert(f, file)
        end
    end
    table.sort(f)
    return f
end

function _buildparams(info, target, default)

    local function getprop(match, opt)
        --print("getprop", match, opt)
        local i = info
        local r = info[match]
        if target then
            opt = table.join(target.targetname, opt)
        end
        for _, k in ipairs(opt) do
            local v = (i._targets or {})[k]
            if v == nil and i._arch_modes then
                v = i._arch_modes[k]
            end
            if v == nil and i._paths then
                v = i._paths[k]
            end
            if v == nil and i._dirs then
                v = i._dirs[k]
            end
            if v == nil and i._deps then
                v = i._deps[k]
            end
            if v == nil and i._groups then
                v = i._groups[k]
            end
            if v == nil and i._group_deps then
                v = i._group_deps[k]
            end
            if v == nil then
                v = i[k]
            end
            if v == nil then
                raise("key '" .. k .. "' not found")
            end
            i = v
            r = i[match] or r
        end

        return r or default
    end

    local configs = {
        target = info.targets,
        mode = info.modes,
        arch = info.archs,
        group = info.groups,
        group_dep = info.group_deps
    }

    if target then
        configs.dir = target.dirs
        configs.dep = target.deps

        configs.filec = _filter_files(target.sourcefiles, {".c"})
        configs.filecxx = _filter_files(target.sourcefiles, {".cpp", ".cc", ".cxx"})
        configs.filempp = _filter_files(target.sourcefiles, {".mpp", ".mxx", ".cppm", ".ixx"})
        configs.filecu = _filter_files(target.sourcefiles, {".cu"})
        configs.fileobj = _filter_files(target.sourcefiles, {".obj", ".o"})
        configs.filerc = _filter_files(target.sourcefiles, {".rc"})
        configs.fileui = _filter_files(target.sourcefiles, {".ui"})
        configs.fileqrc = _filter_files(target.sourcefiles, {".qrc"})
        configs.filets = _filter_files(target.sourcefiles, {".ts"})
        configs.incc = _filter_files(table.join(target.headerfiles or {}, target.extrafiles), nil, {".natvis"})
        configs.incnatvis = _filter_files(table.join(target.headerfiles or {}, target.extrafiles), {".natvis"})
    end

    local config_order = {
        target = 1,
        mode = 2,
        arch = 3
    }

    local function listconfig(args)
        if #args > 1 then
            print(args)
            table.sort(args, function (a, b)
                local a_order = config_order[a] or 0
                local b_order = config_order[b] or 0
                return a_order < b_order
            end)
        end
        local r = {}
        for _, k in ipairs(args) do
            print(k)
            local config = configs[k]
            if config == nil then
                raise("key '" .. k .. "' not found")
            end
            table.insert(r, config)
        end
        return r
    end

    return function(match, opt)
        if type(match) == "table" then
            return listconfig(match)
        end
        return getprop(match, opt)
    end
end

function _trycp(file, target, targetname)
    targetname = targetname or path.filename(file)
    local targetfile = path.join(target, targetname)
    targetfile = vsutils.translate_path(targetfile)
    if os.isfile(targetfile) then
        dprint("skipped file %s since the file already exists", path.relative(targetfile))
        return
    end
    os.cp(file, targetfile)
end

function _writefileifneeded(file, content)
    file = vsutils.translate_path(file)
    if os.isfile(file) and io.readfile(file) == content then
        dprint("skipped file %s since the file has the same content", path.relative(file))
        return
    end
    -- we need utf8 with bom encoding for unicode
    -- @see https://github.com/xmake-io/xmake/issues/1689
    io.writefile(file, content, {encoding = "utf8bom"})
end

-- save plugin arguments for `plugin.vsxmake.autoupdate`
-- @see https://github.com/xmake-io/xmake/issues/1895
function _save_plugin_arguments()
    local vsxmake_cache = localcache.cache("vsxmake")
    for _, name in ipairs({"kind", "modes", "archs", "outputdir"}) do
        vsxmake_cache:set(name, option.get(name))
    end
    vsxmake_cache:save()
end

-- clear cache
function _clear_cache()
    localcache.clear("detect")
    localcache.clear("option")
    localcache.clear("package")
    localcache.clear("toolchain")

    -- force recheck
    localcache.set("config", "recheck", true)

    localcache.save()
end

-- make
function make(version)

    if not version then
        version = tonumber(config.get("vs"))
        if not version then
            return function(outputdir)
                raise("invalid vs version, run `xmake f --vs=20xx`")
            end
        end
    end

    return function(outputdir)
        vprint("using project kind vs%d", version)
        assert(version >= 2010, "vsxmake does not support vs version lower than 2010")

        -- get info and params
        local info = getinfo(outputdir, vsinfo(version))
        local paramsprovidersln = _buildparams(info)

        -- write solution file
        local sln = path.join(info.solution_dir, info.slnfile .. ".sln")
        _writefileifneeded(sln, render(template_sln, "#([A-Za-z0-9_,%.%*%(%)]+)#", "@([^@]+)@", paramsprovidersln))

        -- add solution custom file
        _trycp(template_props, info.vcxproj_rootdir)
        _trycp(template_targets, info.vcxproj_rootdir)

        for _, targetname in ipairs(info.targets) do
            local target = info._targets[targetname]
            local paramsprovidertarget = _buildparams(info, target, "<!-- nil -->")
            local vcxproj_dir = target.vcxprojdir

            -- write project file
            local proj = path.join(vcxproj_dir, targetname .. ".vcxproj")
            _writefileifneeded(proj, render(template_vcx, "#([A-Za-z0-9_,%.%*%(%)]+)#", "@([^@]+)@", paramsprovidertarget))

            local vcxproj_filters = path.join(vcxproj_dir, target .. ".vcxproj.filters")
            _writefileifneeded(vcxproj_filters, render(template_fil, "#([A-Za-z0-9_,%.%*%(%)]+)#", "@([^@]+)@", paramsprovidertarget))

            -- add project custom file
            _trycp(template_props, vcxproj_dir)
            _trycp(template_targets, vcxproj_dir)
            _trycp(template_items, vcxproj_dir)
            _trycp(template_itemfil, vcxproj_dir)
        end

        -- clear config and local cache
        --_clear_cache()

        -- save plugin arguments for autoupdate
        _save_plugin_arguments()
    end
end
