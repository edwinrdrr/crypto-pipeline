# 02 — GitHub repo: create + go public + branch protection + secret-history sweep

> **Why this comes before GCP/Terraform:** the WIF provider built by Terraform (doc 04)
> hard-pins your repo's numeric `repository_id` into its attribute condition. The infra
> apply will fail if the repo doesn't exist yet — so create it first.

## What you'll have when done
- A GitHub repo with this codebase (if not already)
- **Public visibility** — unlocks unlimited Actions minutes AND free required-reviewer
  protection on Environments (key for prod gate in doc 05)
- A clean secret history (no committed keys / `.env` / `*-key.json`)
- (Optional but recommended) Branch protection on `main`

## Fast path

### Create the repo if needed
```bash
# From the repo root (after git init):
gh repo create crypto-pipeline --source=. --remote=origin --push
```
This creates a **private** repo by default. Public happens below.

### Secret-history sweep (verify no sensitive content was ever committed)
```bash
git log -p --all 2>&1 \
  | grep -nIE "BEGIN (RSA |EC |DSA )?PRIVATE KEY|BEGIN OPENSSH|aws_secret_access_key|aws_access_key_id|gho_[A-Za-z0-9]{30,}|ghp_[A-Za-z0-9]{30,}|github_pat_|xoxb-[0-9]+-[0-9]+|\"private_key\":\\s*\"-----" \
  | head
# Should print nothing.

git log --all --name-only --pretty=format: 2>/dev/null \
  | sort -u \
  | grep -iE "(^|/)(\\.env|sa-key|service-account|gcp-key|credentials|.*-key\\.json)$" \
  | head
# Should print nothing.
```
If anything prints, **don't go public yet** — clean history first (`git filter-repo` or
similar), then re-sweep.

### Go public
```bash
gh repo edit --visibility public
gh repo view --json visibility -q .visibility    # → PUBLIC
```
This is reversible (`gh repo edit --visibility private`) but content may be cached
elsewhere — verify the sweep first.

### Branch protection on `main` (recommended)
```bash
gh api -X PUT "repos/edwinrdrr/crypto-pipeline/branches/main/protection" \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```
Solo: 0 required reviews; the prod gate sits at the Environment level (doc 05). Adjust if
you have collaborators.

## Verify
```bash
gh repo view --json visibility,url -q '.url + "  (" + .visibility + ")"'
# https://github.com/edwinrdrr/crypto-pipeline  (PUBLIC)

# GitHub Secrets — only what WIF needs after doc 05
gh secret list                # empty repo-level (secrets will be Environment-scoped)
```

→ continue to [`03-gcp-projects.md`](03-gcp-projects.md).
