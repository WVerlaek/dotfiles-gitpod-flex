#!/bin/bash
# Dotfiles setup — runs async to avoid blocking env startup.
# A sentinel file signals completion so the shell can wait if needed.

DOTFILES_READY="$HOME/.dotfiles-ready"
DOTFILES_LOG="/tmp/dotfiles-setup.log"

rm -f "$DOTFILES_READY"

# Background the actual setup work
(
    set -ex

    if ! command -v zsh &>/dev/null; then
        sudo apt-get install -y -qq zsh
    fi

    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        sh "$HOME/dotfiles/.oh-my-zsh/install.sh" --unattended
    fi

    if [[ -d "$HOME/dotfiles" ]]; then
        pushd "$HOME/dotfiles"
            cp .zshrc "$HOME/.zshrc"
            cp -r .oh-my-zsh/themes/* "$HOME/.oh-my-zsh/themes/"
        popd
    fi

    sudo chsh "$(id -un)" --shell "$(command -v zsh)"

    # Start PR status → environment name poller
    source "$HOME/dotfiles/ona/.run"

    touch "$DOTFILES_READY"
) &>"$DOTFILES_LOG" &

echo "dotfiles: setup running in background (pid $!, log $DOTFILES_LOG)"
