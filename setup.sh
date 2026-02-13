#!/bin/bash
set -ex

echo "Setting up dotfiles"


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
