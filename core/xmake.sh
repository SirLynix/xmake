#!/bin/sh

set_project "xmake"
set_version "2.7.3" "%Y%m%d%H%M"

# set warning all
set_warnings "all"

# set language: c99
set_languages "c99"

# add defines
add_defines "_GNU_SOURCE=1"  "_FILE_OFFSET_BITS=64"  "_LARGEFILE_SOURCE"

# disable some compiler errors
if is_plat "macosx"; then
    add_cxflags "-Wno-error=deprecated-declarations" "-fno-strict-aliasing" "-Wno-error=nullability-completeness" "-Wno-error=parentheses-equality"
fi

# add build modes
if is_mode "debug"; then
    set_symbols "debug"
    set_optimizes "none"
else
    set_strip "all"
    set_symbols "hidden"
    set_optimizes "smallest"
fi

# the runtime option, lua or luajit
option "runtime" "Use luajit or lua runtime" "lua"

# the readline option
option "readline"
    add_links "readline"
    add_cincludes "readline/readline.h"
    add_cfuncs "readline"
    add_defines "XM_CONFIG_API_HAVE_READLINE"
option_end

# the curses option
option "curses"
    add_links "curses"
    add_cfuncs "initscr"
    add_cincludes "curses.h"
    add_defines "XM_CONFIG_API_HAVE_CURSES"
option_end

# the lua-cjson option
option "lua_cjson"
    add_links "lua5.1-cjson"
    add_csnippets "
int luaopen_cjson(void *l);\n
void test() {\n
    luaopen_cjson(0);\n
}
"
option_end

# the lua option
option "lua"
    add_cfuncs "lua_pushstring"
    add_cincludes "lua.h" "lualib.h" "lauxlib.h"
    before_check "option_find_lua"
option_end

option_find_lua() {
    option "lua"
        add_cflags `pkg-config --cflags lua5.4 2>/dev/null`
        add_ldflags `pkg-config --libs lua5.4 2>/dev/null`
    option_end
}

# the lua option
option "luajit"
    add_cfuncs "lua_pushstring"
    add_cincludes "lua.h" "lualib.h" "lauxlib.h"
    add_defines "USE_LUAJIT"
    before_check "option_find_luajit"
option_end

option_find_luajit() {
    option "luajit"
        add_cflags `pkg-config --cflags luajit 2>/dev/null`
        add_ldflags `pkg-config --libs luajit 2>/dev/null`
    option_end
}


# add projects
if ! has_config "lua"; then
    if is_config "runtime" "luajit"; then
        includes "src/luajit"
    else
        includes "src/lua"
    fi
fi
if ! has_config "lua_cjson"; then
    includes "src/lua-cjson"
fi
includes "src/sv"
includes "src/lz4"
includes "src/tbox"
includes "src/xmake"
includes "src/demo"

