#!/bin/bash
#
# Commit signing for this repository, end to end: an SSH signing key (created
# if this machine has none), repo-local git configuration, and registration
# with GitHub so commits show Verified.
#
# Run once per machine you commit from — setup.sh calls it during initial
# setup, and a new laptop just runs it again. Repo-local git config on
# purpose: your other repositories are left exactly as they were.
#
# The one rule to remember afterward: never delete the signing key from
# GitHub (Settings -> SSH and GPG keys). Machines are disposable — a lost
# laptop means running this on the next one — but removing the public key
# from GitHub retroactively flips every commit it verified back to
# Unverified.
set -euo pipefail

KEY="$HOME/.ssh/github_signing_ed25519"

if [ ! -f "$KEY" ]; then
  # A dedicated signing-only key: registered with GitHub purely as a signing
  # key, it can never authenticate as you. Passphrase-less so commits sign
  # without prompting; its protection is the disk's (FileVault/LUKS + login).
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "git-signing" -q
  echo "created signing key $KEY"
fi

git config gpg.format ssh
git config user.signingkey "$KEY.pub"
git config commit.gpgsign true
git config tag.gpgsign true

pub="$(cat "$KEY.pub")"
if gh api user/ssh_signing_keys --jq '.[].key' 2> /dev/null | grep -qF "$(printf '%s' "$pub" | awk '{print $1, $2}')"; then
  echo "signing key already registered with GitHub"
  exit 0
fi

if ! gh api user/ssh_signing_keys -f title="signing key - $(hostname -s)" -f key="$pub" > /dev/null 2>&1; then
  cat >&2 <<'MSG'
Could not register the signing key with GitHub. Your gh token likely lacks
the admin:ssh_signing_key scope. Grant it and rerun this script:

  gh auth refresh -h github.com -s admin:ssh_signing_key
  ./scripts/setup-signing.sh

MSG
  exit 1
fi
echo "signing key registered with GitHub"
