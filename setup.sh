#!/bin/bash
set -ex

echo "Setting up dotfiles"

# Timing test: measure how long setup takes to complete
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) dotfiles setup started" > "$HOME/.dotfiles-setup-timing"
sleep 30
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) dotfiles setup completed" >> "$HOME/.dotfiles-setup-timing"
touch "$HOME/.dotfiles-setup-complete"


if [[ -z "$ZSH_VERSION" ]]; then
    echo "Installing zsh"
    sudo apt install zsh
fi

if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    echo "Installing oh-my-zsh..."
    sh "$HOME/dotfiles/.oh-my-zsh/install.sh" --unattended
fi

if [[ -d "$HOME/dotfiles" ]]; then
    # In gitpod, dotfiles are stored in this directory
    pushd "$HOME/dotfiles"
        cp .zshrc "$HOME/.zshrc"
        cp -r .oh-my-zsh/themes/* "$HOME/.oh-my-zsh/themes/"
    popd
fi

export SHELL=zsh

# Start PR status → environment name poller
source "$HOME/dotfiles/ona/.run"
