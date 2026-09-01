
eval "$(/opt/homebrew/bin/brew shellenv zsh)"

# Keep path entries unique
typeset -U path

# GNU coreutils first (moved from .zshenv — must come after brew shellenv
# and path_helper to avoid being demoted)
_gnubin="/opt/homebrew/opt/coreutils/libexec/gnubin"
[[ -d "$_gnubin" ]] && path=("$_gnubin" $path)

# Prefer Homebrew's OpenSSH over the macOS system SSH. Apple's fork omits
# features present in upstream OpenSSH (notably FIDO2/U2F security key
# support and certain key exchange algorithms). The Homebrew build tracks
# upstream releases and includes the full feature set.
_openssh="/opt/homebrew/opt/openssh/bin"
[[ -d "$_openssh" ]] && path=("$_openssh" $path)

# Personal bin dirs (only if they exist)
for _dir in "$HOME/bin" "$HOME/scripts" "$HOME/.cargo/bin" "$HOME/go/bin"; do
    [[ -d "$_dir" ]] && path+=("$_dir")
done

# Don't leak helper variables into the login session
unset _gnubin _openssh _dir
