import("core.base.option")
import("core.base.task")
import("actions.build.main", {rootdir = os.programdir(), alias = "build_action"})
import("actions.clean.main", {rootdir = os.programdir(), alias = "clean_action"})

function main(action, config, targetname)
    option.save("main")
    if action == "build" then
        build_action({target = targetname})
    elseif action == "rebuild" then
        option.set("rebuild", true)
        build_action({target = targetname})
    elseif action == "clean" then
        clean_action({target = targetname})
    elseif action == "check" then
    else
        os.raise("unknown action " .. action)
    end
    option.restore()
end
