# Git hooks

Not run automatically by a fresh `git clone` — git only trusts hooks from `.git/hooks/` by
default, and that directory isn't versioned. Point git at this one instead, once per clone:

```
git config core.hooksPath .githooks
```

## pre-commit

Scans staged changes for secrets with [gitleaks](https://github.com/gitleaks/gitleaks) before
the commit is created. Install it once:

```
curl -sL https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_$(curl -s https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep -oP '"tag_name": "v\K[^"]+')_linux_x64.tar.gz | tar -xz gitleaks
install -m 755 gitleaks ~/.local/bin/gitleaks   # make sure ~/.local/bin is on PATH
```

Without gitleaks installed, the hook prints a warning and lets the commit through — it never
blocks a commit just because the scanner itself is missing.

Bypass for a reviewed false positive: `SKIP_GITLEAKS=1 git commit ...` or `git commit --no-verify`.
