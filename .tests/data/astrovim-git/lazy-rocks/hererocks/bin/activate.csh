which deactivate-lua >&/dev/null && deactivate-lua

alias deactivate-lua 'if ( -x '\''/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin/lua'\'' ) then; setenv PATH `'\''/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin/lua'\'' '\''/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin/get_deactivated_path.lua'\''`; rehash; endif; unalias deactivate-lua'

setenv PATH '/home/rektide/src/nvim-termichatter/.tests/data/astrovim-git/lazy-rocks/hererocks/bin':"$PATH"
rehash
