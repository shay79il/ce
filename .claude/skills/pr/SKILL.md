---
name: pr
description: Analyze branch changes and generate a fully filled PR description ready to paste into GitHub. Also applies mlrun-ce reviewer guardrails learned from past PR reviews.
allowed-tools: Bash(git diff*) Bash(git log*)
disable-model-invocation: false
---

Analyze the current branch changes and generate a fully filled PR description ready to paste into GitHub.

Before writing the PR description, run the **Reviewer guardrails** checklist below against the diff.

If the diff violates any guardrail, flag it in **Warnings** and suggest a fix — do not silently omit it.

## Reviewer guardrails (learned from past mlrun-ce PR reviews)

Apply these when **authoring changes** and when **preparing or reviewing a PR**.

They are general patterns — not a checklist of one-off fixes.

### 1. Examples and documentation

- **Keep example files small.**

  If an example overlay, values snippet, or config file needs long comments, deploy commands, or auth walkthroughs, move that prose to a **README next to the examples** (e.g. `charts/mlrun-ce/examples/README.md`).

  The example file itself should stay values/config only.

- **Document non-default paths, not defaults.**

  If behaviour is already the chart default, it belongs in `values.yaml` — not in a separate example or README section.

### 2. Optional Helm values

- **Expose overridable settings in `values.yaml`** when users may need to change them (ports, endpoints, feature flags).

- **Apply defaults in `_helpers.tpl`** (via `default` / `coalesce`), not by repeating literals across templates.

  One helper, one default — templates call the helper.

- **Intentionally unset is valid.**

  Some optional values should stay empty in `values.yaml` so the user must choose (e.g. a `provider` enum). Validation/templates should `required` or `fail` when enabled without a choice — do not silently pick a default in `values.yaml`.

### 3. `_helpers.tpl` hygiene

- **Avoid define blocks that only forward to a single value or another helper.**

  Call the underlying helper or value directly from templates.

  Add a helper only when it combines logic, computes a default, or is reused in multiple places.

- **Same rule for hardcoded one-liners** — inline obvious constants in templates rather than wrapping them in a define.

### General (still worth flagging)

- **Scope:** unrelated component changes in a feature PR → call out in Warnings.
- **Coupled version bumps:** when one image/tag in a component set changes, check whether siblings need the same bump.
- **Install-mode values:** new defaults or `enabled` flags that affect installation → all four values files (`values.yaml` + three install-mode overlays).
- **`requirements.yaml` changed** → remind to run `make helm-update-dependencies` and commit `requirements.lock`.

### Pre-submit scan

| Signal in diff | Suggest |
| --- | --- |
| Example file with large comment blocks | README beside examples |
| Same literal repeated in multiple templates | Value in `values.yaml`, default in `_helpers.tpl` |
| New `define` that only wraps one call or value | Remove; use direct reference |
| Example that only restates default install | Drop example; keep default in `values.yaml` |
| Unrelated area changed | Flag scope creep |

## Steps

1. **Gather context** — run these in parallel:
   - `git diff upstream/development...HEAD` — full diff against the base branch
   - `git log upstream/development..HEAD --oneline` — commit list
   - `git diff upstream/development...HEAD --name-only` — changed files

2. **Analyze the diff** carefully:
   - What components or templates were changed? (check which `templates/` subdirs, `values.yaml` sections, `requirements.yaml`, `Chart.yaml`)
   - Were any new values keys added? Do they need to be reflected in the three install-mode values files?
   - Were any Secrets, ConfigMaps, or port numbers changed? (potential breaking changes)
   - Was `Chart.yaml` version bumped? If not, flag it.
   - Were `requirements.yaml` or `requirements.lock` changed?
   - Does `charts/mlrun-ce/README.md` need updating (new NodePort, new component, new install step)?

3. **Detect breaking changes** — flag as breaking if any of:
   - A value key was renamed or removed
   - A Secret or ConfigMap name changed
   - A NodePort number changed
   - A sub-chart was upgraded with a major version bump
   - The storage credentials structure changed
   - Any hook annotation or hook-weight changed in a way that affects upgrade order

4. Provide an optional PR title following the `[Scope] description` format, where Scope is one of: `['feature', 'fix', 'docs', 'improvement', 'revert', 'breaking', 'ci']`. For example: `[Feature] Add Redis support to mlrun-ce`.
5. **Fill the PR template** — produce the complete filled template below. Be specific and concrete; do not use placeholder text.

---

Apply these checklist rules before writing the output:
- `[x]` — you can confirm this item is satisfied from the diff alone
- `[ ]` — requires human action, judgment, or external system access

Specific rules:
- "tested" → always `[ ]`
- "documentation PR" → always `[ ]`
- "QA tests / Jira ticket" → always `[ ]`
- "installation verified" → always `[ ]`
- `Chart.yaml` version bump → `[x]` if diff shows version changed, otherwise `[ ]` and add to Warnings
- Multi-namespace values files → `[x]` if all three are in the diff OR the change has no effect on install-mode values; `[ ]` with a note if a new value was added only to `values.yaml`
- README update → `[x]` if `charts/mlrun-ce/README.md` is in the diff OR no new NodePorts/components were added; otherwise `[ ]`

Output exactly this structure with real content (no placeholder text):

```markdown
### 📝 Description
<2-4 sentences: what changed, why, and what it affects>

---

### 🛠️ Changes Made
<concrete bullet list — file paths, value keys, resource names>

---

### ✅ Checklist
- [ ] I have tested the changes in this PR
- [ ] I confirmed whether my changes require a change in documentation and if so, I created another PR in MLRun for the relevant documentation.
- [ ] I confirmed whether my changes require changes in QA tests, for example: credentials changes, resources naming change and if so, I updated the relevant Jira ticket for QA.
- [ ] I increased the Chart version in `charts/mlrun-ce/Chart.yaml`.
- [ ] I confirmed that the installation works both on a local Docker Desktop environment and on a real cluster when using the required [prerequisites](https://docs.mlrun.org/en/stable/install-mlrun-ce/kubernetes-install.html#prerequisites).
  - [ ] If installation issues were found, I updated the relevant Jira ticket with the issue and steps to reproduce, or updated the prerequisites documentation if the issue is related to missing or outdated prerequisites.
- [ ] If needed, update https://github.com/mlrun/ce/blob/development/charts/mlrun-ce/README.md with the relevant installation instructions and version Matrix.
- [ ] If needed, update the following values files for multi namespace support:
  - [ ] [Admin values](https://github.com/mlrun/ce/blob/development/charts/mlrun-ce/admin_installation_values.yaml)
  - [ ] [User values Node Port](https://github.com/mlrun/ce/blob/development/charts/mlrun-ce/non_admin_installation_values.yaml)
  - [ ] [User values ClusterIP](https://github.com/mlrun/ce/blob/development/charts/mlrun-ce/non_admin_cluster_ip_installation_values.yaml)

---

### 🧪 Testing
<what was tested: lint, helm template dry-run, Kind cluster, manual — based on nature of changes>

---

### 🔗 References
- Ticket link:
- External links:
- Design docs links (Optional):

---

### 🚨 Breaking Changes?

- [ ] Yes (explain below)
- [ ] No

<if breaking: bullet list of what downstream consumers must change — value keys to rename, Secrets to recreate, ports to update>

---

### 🔍️ Additional Notes
<follow-up tasks, known issues, affected areas — omit if nothing to add>
```

Then replace each `[ ]` with `[x]` on items you can confirm from the diff, following the rules above.

After outputting the filled template, add a short **"Warnings"** section (outside the template) listing anything that needs human attention before opening the PR (missing version bump, unsynced values files, potential breaking changes, etc.).
