# Git Basics: the commands we used, explained

> Written 2026-09-24, after the first push of `garamchai-k8s` to GitHub.

## 1. The big picture: 4 places your files live

Think of posting a parcel:

```
 ① Working folder        ② Staging area         ③ Local repository        ④ Remote (GitHub)
 G:\k8S-with-claude  →   "the parcel box"   →   "sealed, labelled     →   "the warehouse"
 (files you edit)        (what goes in the       parcels" = commits        (a copy on the internet)
                          next commit)           (hidden .git folder)
        git add ───────────────►  git commit ──────────────►  git push ──────────────►
```

| Place | What it is | Analogy |
|---|---|---|
| ① Working folder | Normal files in `G:\k8S-with-claude` | Items on your desk |
| ② Staging area (the "index") | The list of changes that go into the **next** commit | Items you've put **in the box** |
| ③ Local repository (`.git` folder) | Every commit ever made: the full history | **Sealed and labelled** boxes on your shelf |
| ④ Remote (`origin` = GitHub) | A copy of the repository on a server | The **warehouse**: safe if your laptop dies |

**Why the extra staging step?** You choose *exactly* what goes into each commit. For example, you commit the runbook but not a half-finished draft.

**What is a commit?** A snapshot of the staged files + a message + an author + a time + a unique ID (like `d1f3519`, the one on your GitHub page). You can always go back to any commit.

---

## 2. The commands we used, one by one

### `git config --global user.name "Vishal Bhilare"` / `user.email "..."`
Tells Git **who you are**. Every commit is stamped with this name and email. `--global` = for all repositories on this laptop (stored in `C:\Users\Lemnovo\.gitconfig`). It's done once per laptop.
Check it: `git config --global --list`

### `git status`
**The most important command.** It shows which branch you're on, what's staged, what's changed but not staged, and which files Git doesn't track yet.
- `A` = added (new, staged) · `M` = modified · `??` = untracked (Git ignores it until you `add`)
- Run it **before and after every other command**, the way we run `kubectl get` after every `apply`.

### `git add -A`
Puts **all** changes (new, modified, deleted files) into the staging area, except files matched by `.gitignore`.
- `git add docs/phases/phase-00-rebuild.md` = stage just one file
- `git add .` = everything in the current folder and below
- Undo (unstage, keeps your edits): `git restore --staged <file>`

### `git commit -m "Phase 0: scaffold, ..."`
Seals the staging area into a **commit** on your laptop, with the message after `-m`.
- A good message says **what and why**: `Rebuild: pin Calico to 10.0.0.0/24`, not `update`.
- Nothing goes to GitHub yet; it's only on your laptop.

### `git branch -M main`
Renames the current branch to `main`. `-M` = rename, even if a branch named main already exists.
- **Branch** = a named line of commits. `main` is the main line. Later we might use a branch like `phase-3-deployments` to try something without touching `main`.
- Why rename? Git's old default name was `master`; GitHub's default is `main`. Using the same name avoids confusion.

### `git remote add origin https://github.com/vishalbhilare9788-eng/garamchai-k8s.git`
Saves the GitHub address under the short name **`origin`** (the usual name for "the main remote").
Check it: `git remote -v`

### `git push -u origin main`
Uploads your commits on branch `main` to `origin` (GitHub).
- `-u` (upstream) remembers "my `main` goes to `origin/main`". From now on, a plain **`git push`** is enough.
- The first time, Git Credential Manager opened the browser for GitHub login. It stores the login safely, so you don't type passwords.

---

## 3. The special files in our repo

| File | What it does |
|---|---|
| `.gitignore` | A list of patterns Git must **never** track: secrets (`*secret*.yaml`, `*.key`, `*kubeconfig*`), backups (`*.db`, `*.tgz`), build junk. Check a file: `git check-ignore -v <file>` (no output = not ignored) |
| `.gitattributes` | `* text=auto eol=lf` = store files with **Linux line endings**. Windows uses CRLF; a CRLF shell script or YAML file can break on the Linux nodes |

---

## 4. ⚠️ The one rule that matters most: never commit secrets
Once a secret is **pushed** (especially to a public repo), treat it as **leaked**, even if you delete it in the next commit, because the **history keeps it**. Bots scan GitHub for keys within minutes. The only fix is to **rotate** the secret (make a new one).
That's why, before the first push, we checked: `.gitignore` rules, `git ls-files`, and a search for the token and private keys.

---

## 5. Your daily workflow
```powershell
cd G:\k8S-with-claude
git status                          # 1. what changed?
git diff                            # 2. see the exact line changes (q to quit)
git add -A                          # 3. stage
git status                          # 4. check what's staged: no secrets!
git commit -m "Phase 3: deploy menu-service with probes"   # 5. commit with a clear message
git push                            # 6. upload to GitHub
```

## 6. Useful extras
| Command | What it does |
|---|---|
| `git log --oneline` | Short history: one line per commit |
| `git log --oneline -- docs/phases/` | History of one folder |
| `git diff --staged` | What's staged (what the next commit will contain) |
| `git restore <file>` | Throw away **unstaged** edits to a file (careful: they're gone) |
| `git pull` | Download new commits from GitHub (needed if you ever edit on GitHub or on another PC) |
| `git show d1f3519` | Show one commit's details and changes |

## 7. Interview-level one-liners
- **Working tree → staging → commit → push**: add chooses, commit records, push shares.
- **Git is distributed**: every clone has the full history, so GitHub is a copy, not the only home.
- **`origin`** is just a nickname for a remote URL; **`main`** is just a branch name.
- **A leaked secret = rotate it**; deleting it from Git isn't enough.
