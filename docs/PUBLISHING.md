# Publishing this repo to GitHub (maintainer notes)

The repo ships as a folder **with full git history already in it**
(`.git` directory). Publishing it to GitHub takes one token and one
double-click.

## One-time setup (about 2 minutes)

1. Go to <https://github.com/settings/tokens/new?scopes=repo&description=vr-hotspot-kit>
   (this link pre-selects the only permission needed: **repo**).
2. Pick an expiration (7 days is plenty), scroll down, click
   **Generate token**.
3. Copy the token (`ghp_...`). Treat it like a password - it can push code
   to your account.

Never use your GitHub *password* for this: GitHub has refused passwords for
git operations since August 2021. And never paste either the password or a
long-lived token into a chat window.

## Publish

Double-click **`Publish-to-GitHub.bat`** in the repo root. It will:

1. ask you to paste the token once (input is hidden),
2. ask for a repository name (default `vr-hotspot-kit`) and
   public/private,
3. create the repository on your GitHub account via the API,
4. push the full commit history,
5. scrub the token out of the git remote and tell you the repo URL.

You can delete the token afterwards (github.com -> Settings -> Developer
settings -> Personal access tokens -> Delete).

## Publishing updates later

Edit files in this folder, then run `Publish-to-GitHub.bat` again - it
commits any changes and pushes them. For meaningful history, run it after
each logical change, or commit manually with git if you prefer.

## The download path for users

Once published, anyone (including you, from any machine) can:

- open the repo URL,
- click the green **<> Code** button -> **Download ZIP** (or clone),
- extract, run `VR-Hotspot-Studio.bat`.

That flow is documented in the README so it needs no explanation here.
