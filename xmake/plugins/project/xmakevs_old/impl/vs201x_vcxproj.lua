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
-- @file        vs201x_vcxproj.lua
--

-- imports
import("core.base.hashset")
import("core.project.rule")
import("core.project.config")
import("core.project.project")
import("core.language.language")
import("core.tool.toolchain")
import("private.utils.batchcmds")
import("detect.sdks.find_cuda")
import("vsfile")
import("vsutils")
import("private.utils.toolchain", {alias = "toolchain_utils"})
import("rules.c++.modules.support", {rootdir = os.programdir()})

function _make_dirs(dir, vcxprojdir)
    dir = dir:trim()
    if #dir == 0 then
        return ""
    end
    dir = path.translate(dir)
    if not path.is_absolute(dir) then
        dir = path.relative(path.absolute(dir), vcxprojdir)
    end
    return dir
end

-- check for CUDA
function _check_cuda(target)
    local cuda
    for _, targetinfo in ipairs(target.info) do
        if targetinfo.sourcekinds and table.contains(targetinfo.sourcekinds, "cu") then
            cuda = find_cuda()
            break
        end
    end
    if cuda then
        if cuda.msbuildextensionsdir and cuda.version and os.isfile(path.join(cuda.msbuildextensionsdir, format("CUDA %s.props", cuda.version))) then
            return cuda
        else
            os.raise("The Visual Studio Integration for CUDA %s is not found. Please check your CUDA installation.", cuda.version)
        end
    end
end

-- get toolset version
function _get_toolset_ver(targetinfo, vsinfo)
    -- get toolset version from vs version
    local vs_toolset = toolchain.load("msvc"):config("vs_toolset") or config.get("vs_toolset")
    local toolset_ver = toolchain_utils.get_vs_toolset_ver(vs_toolset)
    if not toolset_ver then
        toolset_ver = vsinfo.toolset_version
    end
    return toolset_ver
end

-- get platform sdk version from vcvars.WindowsSDKVersion
function _get_platform_sdkver(target, vsinfo)
    local sdkver = nil
    for _, targetinfo in ipairs(target.info) do
        sdkver = targetinfo.sdkver
        if sdkver then
            break
        end
    end
    return sdkver or vsinfo.sdk_version
end

-- combine two successive flags
function _combine_flags(flags, patterns)
    local newflags = {}
    local temparg
    for _, arg in ipairs(flags) do
        if temparg then
            table.insert(newflags, temparg .. " " .. arg)
            temparg = nil
        else
            for _, pattern in ipairs(patterns) do
                if arg:match(pattern) then
                    temparg = arg
                end
            end
            if not temparg then
                table.insert(newflags, arg)
            end
        end
    end
    return newflags
end

-- exclude patterns from flags
function _exclude_flags(flags, excludes)
    local newflags = {}
    for _, flag in ipairs(flags) do
        local excluded = false
        for _, exclude in ipairs(excludes) do
            if flag:find("^[%-/]" .. exclude) then
                excluded = true
                break
            end
        end
        if not excluded then
            table.insert(newflags, vsutils.escape(flag))
        end
    end
    return newflags
end

-- try split from nvcc -code flag
--   e.g. nvcc -arch=compute_86 -code=\"sm_86,compute_86\"
--        nvcc -gencode arch=compute_86,code=[sm_86,compute_86]
function _split_gpucodes(flag)
    flag = flag:gsub("[%[\"]?(.-)[%]\"]?", "%1")
    return flag:split(",")
end

-- make compiling command
function _make_compcmd(compargv, sourcefile, objectfile, vcxprojdir)
    local argv = {}
    for i, v in ipairs(compargv) do
        if i == 1 then
            v = path.filename(v) -- C:\xxx\ml.exe -> ml.exe
        end
        v = v:gsub("__sourcefile__", sourcefile)
        v = v:gsub("__objectfile__", objectfile)

        -- -Idir or /Idir
        -- handle external includes as well
        for _, pattern in ipairs({"[%-/](I)(.*)", "[%-/](external:I)(.*)"}) do
            v = v:gsub(pattern, function (flag, dir)
                dir = _make_dirs(dir, vcxprojdir)
                return "/" .. flag .. dir
            end)
        end

        table.insert(argv, v)
    end
    return table.concat(argv, " ")
end

-- make compiling flags
function _make_compflags(sourcefile, targetinfo, vcxprojdir)
    -- translate path for -Idir or /Idir
    local flags = {}
    for _, flag in ipairs(targetinfo.compflags[sourcefile]) do
        for _, pattern in ipairs({"[%-/](I)(.*)", "[%-/](external:I)(.*)"}) do

            -- -Idir or /Idir
            flag = flag:gsub(pattern, function (flag, dir)
                dir = _make_dirs(dir, vcxprojdir)
                return "/" .. flag .. dir
            end)
        end
        table.insert(flags, flag)
    end
    return flags
end

-- make header
function _make_header(vcxprojfile, vsinfo)
    vcxprojfile:print("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
    vcxprojfile:enter("<Project DefaultTargets=\"Build\" ToolsVersion=\"%s.0\" xmlns=\"http://schemas.microsoft.com/developer/msbuild/2003\">", assert(vsinfo.project_version))
end

-- make references
function _make_references(vcxprojfile, vsinfo, target)
    vcxprojfile:print("<ItemGroup>")
    for dep_name, dep_vcxprojfile in pairs(target.deps) do
        vcxprojfile:print("<ProjectReference Include=\"%s\">", dep_vcxprojfile)
            vcxprojfile:print("<Project>{%s}</Project>", hash.uuid4(dep_name))
        vcxprojfile:print("</ProjectReference>")
    end
    vcxprojfile:print("</ItemGroup>")
end

-- make tailer
function _make_tailer(vcxprojfile, vsinfo, target)
    vcxprojfile:print("<Import Project=\"%$(VCTargetsPath)\\Microsoft.Cpp.targets\" />")
    vcxprojfile:enter("<ImportGroup Label=\"ExtensionTargets\">")
    local cuda = _check_cuda(target)
    if cuda then
        vcxprojfile:print("<Import Project=\"%s\" />", path.join(cuda.msbuildextensionsdir, format("CUDA %s.targets", cuda.version)))
    end
    vcxprojfile:leave("</ImportGroup>")
    vcxprojfile:leave("</Project>")
end

-- make Configurations
function _make_configurations(vcxprojfile, vsinfo, target)

    -- the target name
    local targetname = target.name

    -- make ProjectConfigurations
    vcxprojfile:enter("<ItemGroup Label=\"ProjectConfigurations\">")
    for _, targetinfo in ipairs(target.info) do
        vcxprojfile:enter("<ProjectConfiguration Include=\"%s|%s\">", targetinfo.mode, targetinfo.arch)
            vcxprojfile:print("<Configuration>%s</Configuration>", targetinfo.mode)
            vcxprojfile:print("<Platform>%s</Platform>", targetinfo.arch)
        vcxprojfile:leave("</ProjectConfiguration>")
    end
    vcxprojfile:leave("</ItemGroup>")

    -- make Globals
    vcxprojfile:enter("<PropertyGroup Label=\"Globals\">")
        vcxprojfile:print("<ProjectGuid>{%s}</ProjectGuid>", hash.uuid4(targetname))
        vcxprojfile:print("<RootNamespace>%s</RootNamespace>", targetname)
        if vsinfo.vstudio_version >= "2015" then
            vcxprojfile:print("<WindowsTargetPlatformVersion>%s</WindowsTargetPlatformVersion>", _get_platform_sdkver(target, vsinfo))
        end
    vcxprojfile:leave("</PropertyGroup>")

    -- make Configuration
    for _, targetinfo in ipairs(target.info) do
        vcxprojfile:enter("<PropertyGroup Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\" Label=\"Configuration\">", targetinfo.mode, targetinfo.arch)
            vcxprojfile:print("<ConfigurationType>Makefile</ConfigurationType>")
            vcxprojfile:print("<PlatformToolset>%s</PlatformToolset>", _get_toolset_ver(targetinfo, vsinfo))
            vcxprojfile:print("<CharacterSet>%s</CharacterSet>", targetinfo.unicode and "Unicode" or "MultiByte")
            if targetinfo.usemfc then
                vcxprojfile:print("<UseOfMfc>%s</UseOfMfc>", targetinfo.usemfc)
            end
        vcxprojfile:leave("</PropertyGroup>")
    end

    -- import Microsoft.Cpp.Default.props and Microsoft.Cpp.props
    vcxprojfile:print("<Import Project=\"%$(VCTargetsPath)\\Microsoft.Cpp.Default.props\" />")
    vcxprojfile:print("<Import Project=\"%$(VCTargetsPath)\\Microsoft.Cpp.props\" />")

    -- make ExtensionSettings
    vcxprojfile:enter("<ImportGroup Label=\"ExtensionSettings\">")
    local cuda = _check_cuda(target)
    if cuda then
        vcxprojfile:print("<Import Project=\"%s\" />", path.join(cuda.msbuildextensionsdir, format("CUDA %s.props", cuda.version)))
    end
    vcxprojfile:leave("</ImportGroup>")

    -- make PropertySheets
    for _, targetinfo in ipairs(target.info) do
        vcxprojfile:enter("<ImportGroup Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\" Label=\"PropertySheets\">", targetinfo.mode, targetinfo.arch)
            vcxprojfile:print("<Import Project=\"%$(UserRootDir)\\Microsoft.Cpp.%$(Platform).user.props\" Condition=\"exists(\'%$(UserRootDir)\\Microsoft.Cpp.%$(Platform).user.props\')\" Label=\"LocalAppDataPlatform\" />")
        vcxprojfile:leave("</ImportGroup>")
    end

    -- make UserMacros
    vcxprojfile:print("<PropertyGroup Label=\"UserMacros\" />")

    -- make XMake properties
    local envcmd = "set XMAKE_IN_VSTUDIO=1 && "

    vcxprojfile:enter("<PropertyGroup Label=\"XMakeProperties\">")
        vcxprojfile:print("<XMakeExecutable>%s</XMakeExecutable>", vsutils.escape(os.programfile()))
        vcxprojfile:print("<XMakeProjectDir>%s</XMakeProjectDir>", vsutils.escape(os.projectdir()))
        vcxprojfile:print("<XMakeExecutableFull>%$([System.IO.Path]::GetFullPath('%$(XMakeExecutable)'))</XMakeExecutableFull>")
        vcxprojfile:print("<XMakeProjectDirFull>%$([System.IO.Path]::GetFullPath('%$(XMakeProjectDir)'))</XMakeProjectDirFull>")
        vcxprojfile:print("<XMakeCommandPrefix>%s</XMakeCommandPrefix>", vsutils.escape(envcmd))
    vcxprojfile:leave("</PropertyGroup>")

    -- make OutputDirectory and IntermediateDirectory
    for _, targetinfo in ipairs(target.info) do
        vcxprojfile:enter("<PropertyGroup Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\">", targetinfo.mode, targetinfo.arch)
            vcxprojfile:print("<OutDir>%s\\</OutDir>", _make_dirs(targetinfo.targetdir, target.project_dir))
            vcxprojfile:print("<IntDir>%s\\</IntDir>", _make_dirs(targetinfo.objectdir, target.project_dir))
            if targetinfo.targetfile then 
                vcxprojfile:print("<TargetName>%s</TargetName>", path.basename(targetinfo.targetfile))
                vcxprojfile:print("<TargetExt>%s</TargetExt>", path.extension(targetinfo.targetfile))
                vcxprojfile:print("<NMakeOutput>%s</NMakeOutput>", targetinfo.targetfile)
                vcxprojfile:print("<NMakeNativeOutput>%s</NMakeNativeOutput>", targetinfo.targetfile)
            end

            local invalidcmd = "echo The selected platform/configuration is not valid for this target."

            vcxprojfile:print("<NMakeBuildCommandLine>%$(XMakeCommandPrefix)%s</NMakeBuildCommandLine>", targetinfo.buildcommand or invalidcmd)
            vcxprojfile:print("<NMakeReBuildCommandLine>%$(XMakeCommandPrefix)%s</NMakeReBuildCommandLine>", targetinfo.rebuildcommand or invalidcmd)
            vcxprojfile:print("<NMakeCleanCommandLine>%$(XMakeCommandPrefix)%s</NMakeCleanCommandLine>", targetinfo.cleancommand or invalidcmd)

            if targetinfo.commonflags then
                _make_nmake_options(vcxprojfile, targetinfo.commonflags.cl)
            end

            -- use c or c++ precompiled header
            local pcheader = target.pcxxheader or target.pcheader
            if pcheader then
                vcxprojfile:print("<NMakeForcedIncludes>%s</NMakeForcedIncludes>", vsutils.escape(path.filename(pcheader)))
            end
        vcxprojfile:leave("</PropertyGroup>")
    end

    -- make Debugger
    for _, targetinfo in ipairs(target.info) do
        if targetinfo.rundir then
            vcxprojfile:enter("<PropertyGroup Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\" Label=\"Debugger\">", targetinfo.mode, targetinfo.arch)
                vcxprojfile:print("<LocalDebuggerWorkingDirectory>%s</LocalDebuggerWorkingDirectory>", _make_dirs(targetinfo.rundir, target.project_dir))
                -- @note we use writef to avoid escape $() in runenvs, e.g. $([System.Environment]::Get ..)
                vcxprojfile:writef("<LocalDebuggerEnvironment>%s;%%(LocalDebuggerEnvironment)</LocalDebuggerEnvironment>\n", targetinfo.runenvs)
            vcxprojfile:leave("</PropertyGroup>")
        end
    end
end

-- make nmake options for intellisense
function _make_nmake_options(vcxprojfile, flags, condition)

    -- exists condition?
    condition = condition or ""

    -- get flags string
    local flagstr = os.args(flags)

    -- make NMakePreprocessorDefinitions
    local defines = {}
    for _, flag in ipairs(flags) do
        flag:gsub("^[%-/]D(.*)",
            function (def)
                table.insert(defines, vsutils.escape(def))
            end
        )
    end
    vcxprojfile:print("<NMakePreprocessorDefinitions%s>%s</NMakePreprocessorDefinitions>", condition, table.concat(defines, ";"))

    -- make AdditionalIncludeDirectories
    local dirs = {}
    for _, flag in ipairs(flags) do
        flag:gsub("^[%-/]I(.*)", function (dir) table.insert(dirs, vsutils.escape(dir)) end)
        flag:gsub("^[%-/]external:I(.*)", function (dir) table.insert(dirs, vsutils.escape(dir)) end)
    end
    if #dirs > 0 then
        vcxprojfile:print("<NMakeIncludeSearchPath%s>%s</NMakeIncludeSearchPath>", condition, table.concat(dirs, ";"))
    end

    -- make AdditionalOptions
    local excludes = {
        "nologo", "Fd", "I", "D", "external:I"
    }
    local additional_flags = _exclude_flags(flags, excludes)
    if #additional_flags > 0 then
        vcxprojfile:print("<AdditionalOptions%s>%s</AdditionalOptions>", condition, os.args(additional_flags))
    end
end

-- make common item
function _make_common_item(vcxprojfile, vsinfo, target, targetinfo)

    -- enter ItemDefinitionGroup
    vcxprojfile:enter("<ItemDefinitionGroup Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\">", targetinfo.mode, targetinfo.arch)

    vcxprojfile:enter("<NMakeCompile>")
        vcxprojfile:print("<NMakeCompileFileCommandLine>%$(XMakeCommandPrefix)\"%$(XMakeExecutableFull)\" build --files=$(SelectedFiles)</NMakeCompileFileCommandLine>")
    vcxprojfile:leave("</NMakeCompile>")

    -- leave ItemDefinitionGroup
    vcxprojfile:leave("</ItemDefinitionGroup>")
end

-- build common items (doesn't print anything)
function _build_common_items(vsinfo, target)

    -- for each mode and arch
    for _, targetinfo in ipairs(target.info) do

        -- make source flags
        local flags_stats = {cl = {}, cuda = {}}
        local files_count = {cl = 0, cuda = 0}
        local first_flags = {}
        targetinfo.sourceflags = {}
        for _, sourcebatch in pairs(targetinfo.sourcebatches) do
            local sourcekind = sourcebatch.sourcekind
            local rulename = sourcebatch.rulename
            if (rulename == "c.build" or rulename == "c++.build" or rulename == "c++.build.modules" or rulename == "asm.build" or sourcekind == "mrc") then
                for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                    -- make compiler flags
                    local flags = _make_compflags(sourcefile, targetinfo, target.project_dir)

                    -- no common flags for asm/rc
                    if sourcekind ~= "as" and sourcekind ~= "mrc" then
                        for _, flag in ipairs(table.unique(flags)) do
                            flags_stats.cl[flag] = (flags_stats.cl[flag] or 0) + 1
                        end

                        -- update files count
                        files_count.cl = files_count.cl + 1

                        -- save first flags
                        if first_flags.cl == nil then
                            first_flags.cl = flags
                        end
                    end

                    -- save source flags
                    targetinfo.sourceflags[sourcefile] = flags
                end
            elseif sourcekind == "cu" then
                for _, sourcefile in ipairs(sourcebatch.sourcefiles) do

                    -- make compiler flags
                    local flags = _make_compflags(sourcefile, targetinfo, target.project_dir)

                    -- count flags
                    for _, flag in ipairs(table.unique(flags)) do
                        flags_stats.cuda[flag] = (flags_stats.cuda[flag] or 0) + 1
                    end

                    -- update files count
                    files_count.cuda = files_count.cuda + 1

                    -- save first flags
                    if first_flags.cuda == nil then
                        first_flags.cuda = flags
                    end

                    -- save source flags
                    targetinfo.sourceflags[sourcefile] = flags
                end
            end
        end

        -- make common flags
        targetinfo.commonflags = {cl = {}, cuda = {}}
        for _, comp in ipairs({"cl", "cuda"}) do
            for _, flag in ipairs(first_flags[comp]) do
                if flags_stats[comp][flag] >= files_count[comp] then
                    table.insert(targetinfo.commonflags[comp], flag)
                end
            end
        end

        -- remove common flags from source flags
        local sourceflags = {}
        for _, sourcebatch in pairs(targetinfo.sourcebatches) do
            local sourcekind = sourcebatch.sourcekind
            local rulename = sourcebatch.rulename
            if (sourcekind == "as" or sourcekind == "mrc") then
                -- no common flags for as/mrc files
                for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                    sourceflags[sourcefile] = targetinfo.sourceflags[sourcefile]
                end
            elseif rulename == "c.build" or rulename == "c++.build" or rulename == "c++.build.modules" then -- sourcekind maybe bind multiple rules, e.g. c++modules
                for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                    local flags = targetinfo.sourceflags[sourcefile]
                    local otherflags = {}
                    for _, flag in ipairs(flags) do
                        if flags_stats.cl[flag] < files_count.cl then
                            table.insert(otherflags, flag)
                        end
                    end
                    sourceflags[sourcefile] = otherflags
                end
            elseif sourcekind == "cu" then
                for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                    local flags = targetinfo.sourceflags[sourcefile]
                    local otherflags = {}
                    for _, flag in ipairs(flags) do
                        if flags_stats.cuda[flag] < files_count.cuda then
                            table.insert(otherflags, flag)
                        end
                    end
                    sourceflags[sourcefile] = otherflags
                end
            end
        end
        targetinfo.sourceflags = sourceflags
    end
end

-- make common items
function _make_common_items(vcxprojfile, vsinfo, target)

    -- for each mode and arch
    for _, targetinfo in ipairs(target.info) do
        -- make common item
        _make_common_item(vcxprojfile, vsinfo, target, targetinfo)
    end
end

-- make header file
function _make_include_file(vcxprojfile, includefile, vcxprojdir)
    vcxprojfile:print("<ClInclude Include=\"%s\" />", path.relative(path.absolute(includefile), vcxprojdir))
end

-- make source file for all modes
function _make_source_file_forall(vcxprojfile, vsinfo, target, sourcefile, sourceinfo)

    -- get object file and source kind
    local sourcekind
    for _, info in ipairs(sourceinfo) do
        sourcekind = info.sourcekind
        break
    end

    -- enter it
    local nodename
    if     sourcekind == "as"  then nodename = "CustomBuild"
    elseif sourcekind == "mrc" then nodename = "ResourceCompile"
    elseif sourcekind == "cu"  then nodename = "CudaCompile"
    elseif sourcekind == "cc" or sourcekind == "cxx" then nodename = "ClCompile"
    end
    sourcefile = path.relative(path.absolute(sourcefile), target.project_dir)
    vcxprojfile:enter("<%s Include=\"%s\">", nodename, sourcefile)

        -- for *.asm files
        if sourcekind == "as" then
            vcxprojfile:print("<ExcludedFromBuild>false</ExcludedFromBuild>")
            vcxprojfile:print("<FileType>Document</FileType>")
            for _, info in ipairs(sourceinfo) do
                local objectfile = path.relative(path.absolute(info.objectfile), target.project_dir)
                local compcmd = _make_compcmd(info.compargv, sourcefile, objectfile, target.project_dir)
                vcxprojfile:print("<Outputs Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s\'\">%s</Outputs>", info.mode .. '|' .. info.arch, objectfile)
                vcxprojfile:print("<Command Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s\'\">%s</Command>", info.mode .. '|' .. info.arch, compcmd)
            end
            vcxprojfile:print("<Message>%s</Message>", path.filename(sourcefile))

        -- for *.rc files
        elseif sourcekind == "mrc" then
            for _, info in ipairs(sourceinfo) do
                local objectfile = path.relative(path.absolute(info.objectfile), target.project_dir)
                vcxprojfile:print("<ResourceOutputFileName Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\">%s</ResourceOutputFileName>",
                    info.mode, info.arch, objectfile)
            end

        -- for *.c/cpp/cu files
        else

            -- compile as c++ modules
            if support.has_module_extension(sourcefile) then
                vcxprojfile:print("<CompileAs>CompileAsCppModule</CompileAs>")
            end

            -- we need to use different object directory and allow parallel building
            --
            -- @see https://github.com/xmake-io/xmake/issues/2016
            -- https://github.com/xmake-io/xmake/issues/1062
            for _, info in ipairs(sourceinfo) do
                local objectname = path.filename(info.objectfile)
                local targetinfo = info.targetinfo
                if not targetinfo.objectnames then
                    targetinfo.objectnames = hashset:new()
                end
                if targetinfo.objectnames:has(objectname) then
                    local outputnode = (sourcekind == "cu" and "CompileOut" or "ObjectFileName")
                    local objectfile = path.relative(path.absolute(info.objectfile), target.project_dir)
                    vcxprojfile:print("<%s Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\">%s</%s>",
                        outputnode, info.mode, info.arch, objectfile, outputnode)
                else
                    targetinfo.objectnames:insert(objectname)
                end
            end

            -- init items
            local items =
            {
                AdditionalOptions =
                {
                    key = function (info) return os.args(info.flags) end
                ,   value = function (key) return key .. " %%(AdditionalOptions)" end
                }
            }

            -- make items
            for itemname, iteminfo in pairs(items) do

                -- make merge keys
                local mergekeys  = {}
                for _, info in ipairs(sourceinfo) do
                    local key = iteminfo.key(info)
                    mergekeys[key] = mergekeys[key] or {}
                    mergekeys[key][info.mode .. '|' .. info.arch] = true
                end
                for key, mergeinfos in pairs(mergekeys) do

                    -- merge mode and arch first
                    local count = 0
                    for _, mode in ipairs(vsinfo.modes) do
                        if mergeinfos[mode .. "|Win32"] and mergeinfos[mode .. "|x64"] then
                            mergeinfos[mode .. "|Win32"] = nil
                            mergeinfos[mode .. "|x64"]   = nil
                            mergeinfos[mode]             = true
                        end
                        if mergeinfos[mode] then
                            count = count + 1
                        end
                    end

                    -- disable the precompiled header if sourcekind ~= headerkind
                    local pcheader = target.pcxxheader or target.pcheader
                    local pcheader_disable = false
                    if sourcekind == "cu" or (pcheader and language.sourcekind_of(sourcefile) ~= (target.pcxxheader and "cxx" or "cc")) then
                        pcheader_disable = true
                    end

                    -- all modes and archs exist?
                    if count == #vsinfo.modes then
                        if #key > 0 then
                            vcxprojfile:print("<%s>%s</%s>", itemname, iteminfo.value(key), itemname)
                            if pcheader_disable then
                                vcxprojfile:print("<PrecompiledHeader>NotUsing</PrecompiledHeader>")
                            end
                        end
                    else
                        for cond, _ in pairs(mergeinfos) do
                            if cond:find('|', 1, true) then
                                -- for mode | arch
                                if #key > 0 then
                                    vcxprojfile:print("<%s Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s\'\">%s</%s>", itemname, cond, iteminfo.value(key), itemname)
                                    if pcheader_disable then
                                        vcxprojfile:print("<PrecompiledHeader Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s\'\">NotUsing</PrecompiledHeader>", cond)
                                    end
                                end
                            else
                                -- only for mode
                                if #key > 0 then
                                    vcxprojfile:print("<%s Condition=\"\'%$(Configuration)\'==\'%s\'\">%s</%s>", itemname, cond, iteminfo.value(key), itemname)
                                    if pcheader_disable then
                                        vcxprojfile:print("<PrecompiledHeader Condition=\"\'%$(Configuration)\'==\'%s\'\">NotUsing</PrecompiledHeader>", cond)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

    -- leave it
    vcxprojfile:leave("</%s>", nodename)
end

-- make source file for specific modes
function _make_source_file_forspec(vcxprojfile, vsinfo, target, sourcefile, sourceinfo)

    -- add source file
    sourcefile = path.relative(path.absolute(sourcefile), target.project_dir)
    for _, info in ipairs(sourceinfo) do

        -- enter it
        local nodename
        if     info.sourcekind == "as"  then nodename = "CustomBuild"
        elseif info.sourcekind == "mrc" then nodename = "ResourceCompile"
        elseif info.sourcekind == "cu"  then nodename = "CudaCompile"
        elseif info.sourcekind == "cc" or info.sourcekind == "cxx" then nodename = "ClCompile"
        end
        vcxprojfile:enter("<%s Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\" Include=\"%s\">",
            nodename, info.mode, info.arch, sourcefile)

        -- for *.asm files
        local objectfile = path.relative(path.absolute(info.objectfile), target.project_dir)
        if info.sourcekind == "as" then
            local compcmd = _make_compcmd(info.compargv, sourcefile, objectfile, target.project_dir)
            vcxprojfile:print("<ExcludedFromBuild>false</ExcludedFromBuild>")
            vcxprojfile:print("<FileType>Document</FileType>")
            vcxprojfile:print("<Outputs>%s</Outputs>", objectfile)
            vcxprojfile:print("<Command>%s</Command>", compcmd)

        -- for *.rc files
        elseif info.sourcekind == "mrc" then
            vcxprojfile:print("<ResourceOutputFileName Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\">%s</ResourceOutputFileName>",
                info.mode, info.arch, objectfile)

        -- for *.c/cpp/cu files
        else
            -- compile as c++ modules
            if support.has_module_extension(sourcefile) then
                vcxprojfile:print("<CompileAs>CompileAsCppModule</CompileAs>")
            end

           -- we need to use different object directory and allow parallel building
            --
            -- @see https://github.com/xmake-io/xmake/issues/2016
            -- https://github.com/xmake-io/xmake/issues/1062
            local objectname = path.filename(objectfile)
            local targetinfo = info.targetinfo
            if not targetinfo.objectnames then
                targetinfo.objectnames = hashset:new()
            end
            local targetinfo = info.targetinfo
            local outputnode = (info.sourcekind == "cu" and "CompileOut" or "ObjectFileName")
            if targetinfo.objectnames:has(objectname) then
                vcxprojfile:print("<%s Condition=\"\'%$(Configuration)|%$(Platform)\'==\'%s|%s\'\">%s</%s>",
                    outputnode, info.mode, info.arch, objectfile, outputnode)
            else
                targetinfo.objectnames:insert(objectname)
            end

            -- disable the precompiled header if sourcekind ~= headerkind
            local pcheader = target.pcxxheader or target.pcheader
            if pcheader and info.sourcekind ~= "cu" and language.sourcekind_of(sourcefile) ~= (target.pcxxheader and "cxx" or "cc") then
                vcxprojfile:print("<PrecompiledHeader>NotUsing</PrecompiledHeader>")
            end
            vcxprojfile:print("<AdditionalOptions>%s %%(AdditionalOptions)</AdditionalOptions>", os.args(info.flags))
        end

        -- leave it
        vcxprojfile:leave("</%s>", nodename)
    end
end

-- make source files
function _make_source_files(vcxprojfile, vsinfo, target)
    -- add source files
    vcxprojfile:enter("<ItemGroup>")

        -- make source file infos
        local sourceinfos = {}
        for _, targetinfo in ipairs(target.info) do
            for _, sourcebatch in pairs(targetinfo.sourcebatches or {}) do
                local sourcekind = sourcebatch.sourcekind
                local rulename = sourcebatch.rulename
                if (rulename == "c.build" or rulename == "c++.build" or sourcekind == "as" or sourcekind == "mrc" or sourcekind == "cu") then
                    local objectfiles = sourcebatch.objectfiles
                    for idx, sourcefile in ipairs(sourcebatch.sourcefiles) do
                        local objectfile    = objectfiles[idx]
                        local flags         = targetinfo.sourceflags[sourcefile]
                        sourceinfos[sourcefile] = sourceinfos[sourcefile] or {}
                        table.insert(sourceinfos[sourcefile], {targetinfo = targetinfo, mode = targetinfo.mode, arch = targetinfo.arch, sourcekind = sourcekind, objectfile = objectfile, flags = flags, compargv = targetinfo.compargvs[sourcefile]})
                    end
                elseif rulename == "c++.build.modules" then
                    local builder_batch = targetinfo.sourcebatches["c++.build.modules.builder"]
                    table.sort(builder_batch.objectfiles)
                    local objectfiles = builder_batch.objectfiles
                    for idx, sourcefile in ipairs(sourcebatch.sourcefiles) do
                        local is_named_module = table.contains(builder_batch.sourcefiles, sourcefile)
                        if is_named_module then
                            local objectfile    = objectfiles[idx]
                            local flags         = targetinfo.sourceflags[sourcefile]
                            sourceinfos[sourcefile] = sourceinfos[sourcefile] or {}
                            table.insert(sourceinfos[sourcefile], {targetinfo = targetinfo, mode = targetinfo.mode, arch = targetinfo.arch, sourcekind = "cxx", objectfile = objectfile, flags = flags, compargv = targetinfo.compargvs[sourcefile]})
                        end
                    end
                end
            end
        end

        -- make source files
        for sourcefile, sourceinfo in table.orderpairs(sourceinfos) do
            if #sourceinfo == #target.info then
                _make_source_file_forall(vcxprojfile, vsinfo, target, sourcefile, sourceinfo)
            else
                _make_source_file_forspec(vcxprojfile, vsinfo, target, sourcefile, sourceinfo)
            end
        end

    vcxprojfile:leave("</ItemGroup>")

    -- add include files
    local pcheader = target.pcxxheader or target.pcheader
    vcxprojfile:enter("<ItemGroup>")
        for _, includefile in ipairs(table.join(target.headerfiles or {}, target.extrafiles)) do
            -- we need to ignore pcheader file to fix https://github.com/xmake-io/xmake/issues/1171
            if not pcheader or includefile ~= pcheader then
                _make_include_file(vcxprojfile, includefile, target.project_dir)
            end
        end
    vcxprojfile:leave("</ItemGroup>")
end

-- make vcxproj
function make(vsinfo, target)

    -- the target name
    local targetname = target.name

    -- the vcxproj directory
    local vcxprojdir = target.project_dir

    -- build common flags
    _build_common_items(vsinfo, target)

    -- open vcxproj file
    local vcxprojpath = path.join(vcxprojdir, targetname .. ".vcxproj")
    local vcxprojfile = vsfile.open(vcxprojpath, "w")

    -- init indent character
    vsfile.indentchar('  ')

    -- make header
    _make_header(vcxprojfile, vsinfo)

    -- make Configurations
    _make_configurations(vcxprojfile, vsinfo, target)

    -- make common items
    _make_common_items(vcxprojfile, vsinfo, target)

    -- make source files
    _make_source_files(vcxprojfile, vsinfo, target)

    -- make deps references
    _make_references(vcxprojfile, vsinfo, target)

    -- make tailer
    _make_tailer(vcxprojfile, vsinfo, target)

    -- exit solution file
    vcxprojfile:close()
end
