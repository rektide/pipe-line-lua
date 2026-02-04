if functions -q deactivate-lua
    deactivate-lua
end

function deactivate-lua
    if test -x '/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin/lua'
        eval ('/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin/lua' '/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin/get_deactivated_path.lua' --fish)
    end

    functions -e deactivate-lua
end

set -gx PATH '/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin' $PATH
