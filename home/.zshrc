
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
. "/Users/phillipmcmahon/.acme.sh/acme.sh.env"
export PATH="${HOME}/.local/bin":${PATH}

# Switch this Terminal tab's profile and return its previous profile name.
_terminal_host_profile() {
    /usr/bin/osascript - "$TTY" "$1" <<'APPLESCRIPT'
on run argv
    set targetTTY to item 1 of argv
    set profileName to item 2 of argv

    tell application "Terminal"
        repeat with terminalWindow in windows
            repeat with terminalTab in tabs of terminalWindow
                if (tty of terminalTab) is targetTTY then
                    set previousName to name of (current settings of terminalTab)
                    set current settings of terminalTab to settings set profileName
                    return previousName
                end if
            end repeat
        end repeat
    end tell

    error "Could not find the Terminal tab for " & targetTTY
end run
APPLESCRIPT
}

# Use the SSH executable already selected by your PATH.
ssh() {
    local target_host target_profile previous_profile

    if [[ "$TERM_PROGRAM" != Apple_Terminal || ! -t 0 || ! -t 1 ]]; then
        command ssh "$@"
        return $?
    fi

    # Resolve HostName from SSH configuration, including configured aliases.
    target_host=$(
        command ssh -G "$@" 2>/dev/null |
            /usr/bin/awk '$1 == "hostname" { print $2 }'
    )

    case "$target_host" in
        podman.services.phillipmcmahon.com)
            target_profile="Services"
            ;;
        podman.dmz.phillipmcmahon.com)
            target_profile="DMZ"
            ;;
        *)
            command ssh "$@"
            return $?
            ;;
    esac

    if ! previous_profile=$(_terminal_host_profile "$target_profile"); then
        print -u2 -- "Profile switching failed. Continuing with SSH."
        command ssh "$@"
        return $?
    fi

    {
        command ssh "$@"
    } always {
        _terminal_host_profile "$previous_profile" >/dev/null
    }
}
