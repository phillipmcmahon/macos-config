#!/usr/bin/env bash
set -Eeuo pipefail

KEYID="0xA11E70ADFDA60CF9"

# 1. Packages
brew list gnupg &>/dev/null || brew install gnupg
brew list pinentry-mac &>/dev/null || brew install pinentry-mac
PINENTRY="$(brew --prefix)/bin/pinentry-mac"

mkdir -p ~/.gnupg && chmod 700 ~/.gnupg

# 2. gpg-agent.conf — SSH support + GUI pinentry
cat > ~/.gnupg/gpg-agent.conf <<EOF
enable-ssh-support
pinentry-program ${PINENTRY}
default-cache-ttl 600
max-cache-ttl 7200
EOF

# 3. scdaemon.conf — macOS smartcard fixes
cat > ~/.gnupg/scdaemon.conf <<EOF
disable-ccid
pcsc-shared
EOF

# 4. gpg.conf — hardened defaults
cat > ~/.gnupg/gpg.conf <<EOF
personal-cipher-preferences AES256 AES192 AES
personal-digest-preferences SHA512 SHA384 SHA256
personal-compress-preferences ZLIB BZIP2 ZIP Uncompressed
default-preference-list SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed
cert-digest-algo SHA512
s2k-digest-algo SHA512
s2k-cipher-algo AES256
charset utf-8
fixed-list-mode
no-comments
no-emit-version
no-greeting
keyid-format 0xlong
list-options show-uid-validity
verify-options show-uid-validity
with-fingerprint
require-cross-certification
no-symkey-cache
default-key ${KEYID}
trusted-key ${KEYID}
EOF

chmod 600 ~/.gnupg/*.conf

# 5. Shell environment — managed block in .zshrc
#    Uses markers so the block can be detected, replaced, or removed cleanly.
#    Does not conflict with Bitwarden SSH agent lines outside the markers.
MARKER_BEGIN="# >>> yubikey-gpg-ssh >>>"
MARKER_END="# <<< yubikey-gpg-ssh <<<"

if grep -qF "$MARKER_BEGIN" ~/.zshrc 2>/dev/null; then
    echo "yubikey-gpg-ssh block already present in ~/.zshrc — skipping."
else
cat >> ~/.zshrc <<EOF

${MARKER_BEGIN}
# GPG pinentry needs the terminal (for encrypt/decrypt/sign with the YubiKey)
# \$TTY is a native zsh variable — avoids the \$(tty) subprocess and the
# "not a tty" string when run in non-TTY contexts.
export GPG_TTY=\$TTY

# SSH auth via Bitwarden agent (preferred over gpg-agent for SSH).
# To switch to GPG-agent SSH instead, comment the line below and
# uncomment the gpgconf line after it.
export SSH_AUTH_SOCK="\$HOME/.bitwarden-ssh-agent.sock"
# export SSH_AUTH_SOCK="\$(gpgconf --list-dirs agent-ssh-socket)"

# Launch gpg-agent for GPG signing/encryption (not SSH — that uses
# Bitwarden above). The agent must be running for YubiKey operations.
command -v gpgconf >/dev/null && gpgconf --launch gpg-agent
${MARKER_END}
EOF
fi

# 6. Restart agents and learn the card
gpgconf --kill gpg-agent scdaemon
gpgconf --launch gpg-agent
gpg --card-status >/dev/null

# 7. Show SSH public key
SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
export SSH_AUTH_SOCK
echo "--- SSH public key (add to servers/GitHub): ---"
ssh-add -L

