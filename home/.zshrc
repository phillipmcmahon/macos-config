
[ -f ~/.config/.zsh_functions ] && source ~/.config/.zsh_functions

# GPG pinentry needs the terminal (for encrypt/decrypt/sign with the YubiKey)
# $TTY is a native zsh variable — avoids the $(tty) subprocess and the
# "not a tty" string when run in non-TTY contexts.
export GPG_TTY=$TTY

# SSH auth via GnuPG agent
# export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

# SSH auth via Bitwarden agent
export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"

command -v gpgconf >/dev/null && gpgconf --launch gpg-agent
