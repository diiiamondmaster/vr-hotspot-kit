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

## Publishing a release (the easy-download file)

Every version gets a **GitHub Release** - the section below/right of the
code listing on the repo page. This is the primary download path for
users: they grab the attached zip without cloning anything.

1. Commit + push your changes, then tag the version:
   `git tag -a v1.0.1 -m "..."` and `git push --tags`.
2. On github.com: repo page -> **Releases** (right sidebar) ->
   **Draft a new release** -> choose the tag -> write notes ->
   **attach files** by dragging the zip into the attachment box ->
   **Publish release**.
3. Or by API (what the AI publisher does):
   `POST /repos/{owner}/{repo}/releases` with `{"tag_name":"v1.0.1",...}`,
   then upload the asset to
   `https://uploads.github.com/repos/{owner}/{repo}/releases/{id}/assets?name=file.zip`.

The attached zip should contain the **runnable files only** - no `.git`,
no maintainer tooling (the publisher scripts) - so it stays small and
extract-and-run.

## The download path for users

Once published, anyone (including you, from any machine) can:

- open the repo URL,
- grab `vr-hotspot-kit.zip` from **Releases** (right sidebar) - no git,
  no login,
- extract, run `VR-Hotspot-Studio.bat`.

The green **<> Code** button -> **Download ZIP** remains as the
everything-including-history option for developers.

That flow is documented in the README so it needs no explanation here.
