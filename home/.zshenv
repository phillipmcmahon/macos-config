# Keep .zshenv PATH-free on macOS — /etc/zprofile runs path_helper after
# .zshenv, which demotes any prepends made here. All PATH setup lives in
# .zprofile instead, after brew shellenv has run.
