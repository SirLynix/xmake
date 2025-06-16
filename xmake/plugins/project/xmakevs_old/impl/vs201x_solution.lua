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
-- @author      ruki
-- @file        vs201x_solution.lua
--

-- imports
import("core.project.project")
import("vsfile")
import("vsutils")

-- make xmake projects
function _get_targets()
    local targets = {}
    local default_target
    for _, target in ipairs(project.ordertargets()) do
        local targetname = target:name()
        local targetinfo = {dir = targetname, name = targetname, group = target:get("group")}
        -- we need to set startup project for default or binary target
        -- @see https://github.com/xmake-io/xmake/issues/1249
        if target:get("default") == true then
            default_target = targetinfo
        elseif target:is_binary() then
            if not default_target then
                default_target = targetinfo
            else
                table.insert(targets, targetinfo)
            end
        else
            table.insert(targets, targetinfo)
        end
    end
    if not default_target then
        table.insert(targets, 1, default_target)
    end
    -- compute hashes
    for _, targetinfo in ipairs(targets) do
        targetinfo.hash = hash.uuid4(targetinfo.name)
        if targetinfo.group and #targetinfo.group == 0 then
            targetinfo.group = nil
        end
    end
    -- add xmake projects
    table.insert(targets, {dir = "_XMake", name = "Check", group = "XMake", hash = hash.uuid4("xmake-check")})
    table.insert(targets, {dir = "_XMake", name = "BuildAll", group = "XMake", hash = hash.uuid4("xmake-buildall")})
    return targets
end

-- make header
function _make_header(slnfile, vsinfo)
    slnfile:print("Microsoft Visual Studio Solution File, Format Version %s.00", vsinfo.solution_version)
    slnfile:print("# Visual Studio %s", vsinfo.vstudio_version)
end

-- make projects
function _make_projects(slnfile, vsinfo, targets)
    -- make all targets
    local groups = {}
    local vctool = "8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942"
    local checkhash = hash.uuid4("xmake-check")
    for _, targetinfo in ipairs(targets) do
        local targetname = targetinfo.name
        slnfile:enter("Project(\"{%s}\") = \"%s\", \"%s\\%s.vcxproj\", \"{%s}\"", vctool, targetname, targetinfo.dir, targetname, targetinfo.hash)

        slnfile:enter("ProjectSection(ProjectDependencies) = postProject")
        slnfile:print("{%s} = {%s}", checkhash, checkhash)
        slnfile:leave("EndProjectSection")

        slnfile:leave("EndProject")

        if targetinfo.group then
            local group_current_path
            local group_names = path.split(targetinfo.group)
            for idx, group_name in ipairs(group_names) do
                group_current_path = group_current_path and path.join(group_current_path, group_name) or group_name
                groups[group_current_path] = hash.uuid4("group." .. group_current_path)
            end
        end
    end

    -- make all groups
    local project_group_uuid = "2150E333-8FDC-42A3-9474-1A3956D46DE8"
    for group_path, group_uuid in table.orderpairs(groups) do
        local group_name = path.filename(group_path)
        slnfile:enter("Project(\"{%s}\") = \"%s\", \"%s\", \"{%s}\"", project_group_uuid, group_name, group_name, group_uuid)
        slnfile:leave("EndProject")
    end
end

-- make global
function _make_global(slnfile, vsinfo, targets)
    -- enter global
    slnfile:enter("Global")

    -- add solution configuration platforms
    slnfile:enter("GlobalSection(SolutionConfigurationPlatforms) = preSolution")
    for _, mode in ipairs(vsinfo.modes) do
        for _, arch in ipairs(vsinfo.archs) do
            slnfile:print("%s|%s = %s|%s", mode, arch, mode, arch)
        end
    end
    slnfile:leave("EndGlobalSection")

    -- add project configuration platforms
    slnfile:enter("GlobalSection(ProjectConfigurationPlatforms) = postSolution")
    local checkhash = hash.uuid4("xmake-check")
    local buildallhash = hash.uuid4("xmake-buildall")
    for _, mode in ipairs(vsinfo.modes) do
        for _, arch in ipairs(vsinfo.archs) do
            local vs_arch = vsutils.vsarch(arch)
            for _, targetinfo in ipairs(targets) do
                slnfile:print("{%s}.%s|%s.ActiveCfg = %s|%s", targetinfo.hash, mode, arch, mode, vs_arch)
            end
            slnfile:print("{%s}.%s|%s.ActiveCfg = %s|%s", checkhash, mode, arch, mode, vs_arch)
            slnfile:print("{%s}.%s|%s.ActiveCfg = %s|%s", buildallhash, mode, arch, mode, vs_arch)
            slnfile:print("{%s}.%s|%s.Build.0 = %s|%s", buildallhash, mode, arch, mode, vs_arch)
        end
    end
    slnfile:leave("EndGlobalSection")

    -- add solution properties
    slnfile:enter("GlobalSection(SolutionProperties) = preSolution")
    slnfile:print("HideSolutionNode = FALSE")
    slnfile:leave("EndGlobalSection")

    -- add project groups
    slnfile:enter("GlobalSection(NestedProjects) = preSolution")
    local subgroups = {}
    for _, targetinfo in ipairs(targets) do
        if targetinfo.group then
            -- target -> group
            local group_path = path.normalize(targetinfo.group)
            slnfile:print("{%s} = {%s}", targetinfo.hash, hash.uuid4("group." .. group_path))
            -- group -> group -> ...
            local group_current_path
            local group_names = path.split(group_path)
            for idx, group_name in ipairs(group_names) do
                group_current_path = group_current_path and path.join(group_current_path, group_name) or group_name
                local group_name_sub = group_names[idx + 1]
                local key = group_name .. (group_name_sub or "")
                if group_name_sub and not subgroups[key] then
                    slnfile:print("{%s} = {%s}", hash.uuid4("group." .. path.join(group_current_path, group_name_sub)),
                        hash.uuid4("group." .. group_current_path))
                    subgroups[key] = true
                end
            end
        end
    end
    slnfile:leave("EndGlobalSection")

    -- leave global
    slnfile:leave("EndGlobal")
end

-- make solution
function make(vsinfo)
    -- init solution name
    vsinfo.solution_name = project.name() or ("vs" .. vsinfo.vstudio_version)

    local targets = _get_targets()

    -- open solution file
    local slnpath = path.join(vsinfo.solution_dir, vsinfo.solution_name .. ".sln")
    local slnfile = vsfile.open(slnpath, "w")

    -- init indent character
    vsfile.indentchar('\t')

    -- make header
    _make_header(slnfile, vsinfo)

    -- make projects
    _make_projects(slnfile, vsinfo, targets)

    -- make global
    _make_global(slnfile, vsinfo, targets)

    -- exit solution file
    slnfile:close()
end

