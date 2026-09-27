# Curated-Merge Plan for a Large Feature Branch

A brief for an agentic coding assistant (e.g. Claude Code) with the repository checked out.
The goal is to land a large feature branch on `main` as a clean, comprehensible contribution
that does not degrade `main`'s quality, and to do so **cost-efficiently** by proposing precise
boundaries with eyes on the actual code.

This is a **human-supervised, gated** process. You (the assistant) **propose at each gate and
stop for approval before executing.** Do not rewrite history or apply edits until the relevant
gate is approved.

---

## Context

**The branch.** Typically dozens of commits and files changed, often co-developing several
layers that grew together, for example:

1. **API** changes — the foundation; the other layers depend on it.
2. a **CLI** that exercises the server's capabilities via the API.
3. an **integration-test framework**.
4. **tests** written on that framework.

Confirm these layers against the actual code and rename/add layers if reality differs. Because
they co-evolved, expect **coupling**: single files — possibly single functions — carrying
changes that belong to more than one layer.

**Two parallel deliverables.**

- **Track A — a curated commit series** that sums *exactly* to the branch's final diff, sliced
  into a small number (target ~4–8) of logically coherent, dependency-ordered commits with
  high-quality messages.
- **Track B — durable insight surfaced in the right place**: newly written inline comments
  sited at the lines they explain, plus one or more ADRs (Architecture Decision Records).
  Insight is **derived from** the commit history but **written onto** the final tree — never
  copied verbatim.

---

## Principles (hold throughout)

- A **commit message** explains a *transition* (why a delta happened). A **code comment**
  explains *current-state rationale* (why the code is the way it is). An **ADR** captures the
  *chosen-over-alternatives* narrative. Route each piece of commentary to the home that matches
  its kind.
- **Never inline transition narrative or commentary about superseded states.** Those rot. Fold
  superseded / fixup states away entirely; they have no future value to a reader of `main`.
- **Curation cost is a function of the final diff's logical structure, not the commit count.**
  The branch's commits collapse to the final tree for free; the work is re-slicing that tree
  along clean seams.
- Each curated commit's diff should match the lines its message describes, so that `git blame`
  yields line-level attribution **without** polluting source with history.
- **Correctness invariant:** the curated series' tip tree must be byte-identical to the
  approved final tree (raw tip + the new comments + ADR). Verify explicitly (Execute phase).
  The series only ever *re-partitions* the final diff; it never changes it.
- **Bias hard toward durable, current-state insight.** Over-inclusion — a comment for every
  change — is the expected failure mode; resist it.
- **Front-load analysis, back-load state changes.** All non-destructive phases (Recon, Slice,
  Harvest) run before any irreversible git operations (tagging, branch creation). This
  minimises the cost of recovering state if analysis reveals the plan needs reworking.
- **Self-containment trumps subsystem purity.** A commit covering files from more than one
  subsystem is fine — good, even — when the change genuinely affected those subsystems together
  as one self-contained unit. Splitting a commit along subsystem lines purely to keep e.g.
  "backend" and "frontend" separate, when the underlying change doesn't actually decompose that
  way, produces two commits each harder to understand than the one real change they came from.
  Self-containment of the change is the goal; subsystem purity is a secondary, non-binding
  preference that only applies where the change actually does decompose that way.

---

## Inputs to confirm before starting

Confirm or discover each; do not proceed on assumptions.

- `FEATURE` — the feature branch ref.
- `TARGET` — the branch it merges into (likely `main`).
- `BASE` — the merge base: `git merge-base $TARGET $FEATURE`.
- `BUILD_CMD` — how to build.
- `UNIT_CMD` — the **fast, stable** test layer that does **not** depend on the integration
  framework being complete. This is your per-commit oracle.
- `INTEG_CMD` — the full integration suite, plus its runtime and known flakiness.
- The repo's ADR location/format (e.g. `docs/adr/NNNN-title.md`); ask if none exists.
- The repo's comment/docstring and commit-message conventions, including any explicit
  documentation rules it enforces (e.g. no narrative history in comments, no references to files
  outside the repo) — these become the compliance sweep's checklist (see below).
- Who approves each gate.

---

## Detecting whether a branch already landed

Before assuming `$FEATURE` is unmerged, check for the `Raw-History:` trailer convention (see
Phase 4 below) — a squashed/rewritten landing on `$TARGET` won't show up via a plain `git diff`
or `git merge-base --is-ancestor` check, since it's a deliberate history rewrite, not a rebase.
Landing commits produced by this process cite the tag that preserves the branch's
otherwise-unrecoverable pre-squash history, e.g.:

```
Raw-History: raw/ide-launch-hardening (64bfb36)
```

Check for these first:

```sh
git log origin/main --format='%H %s' | while read hash subject; do
  raw=$(git show -s --format='%B' "$hash" | grep -oP 'Raw-History:\s*\K.*')
  [ -n "$raw" ] && echo "$hash  $subject  ::  $raw"
done
```

A single-commit branch doesn't need a dedicated `raw/` tag or trailer — even landed under a
different hash (rebase/cherry-pick), that one commit's content is the whole story, so a plain
ancestor/content-absorbed check is sufficient. Absence of a trailer only means "check the diff
yourself"; it's expected, not a red flag, for single-commit branches.

---

## Phase 1 — Recon (report, then stop)

*Read-only. Produces a written report; changes nothing.*

0. **Check for existing structure before reconstructing it.** Run `git log --decorate --oneline
   $BASE..$FEATURE` and, if the remote is on GitHub, `gh pr list --state all` before assuming
   chapter boundaries have to be inferred from the diff alone — a real tag, a branch-tip
   decoration, or prior PR history often already marks exactly where one logical chapter ends
   and the next begins, cheaper and more reliable than reconstructing it from commit messages.
   This same check also reveals whether `$FEATURE` is itself staged on top of another
   still-unlanded branch (its PR's base ref isn't `$TARGET`) rather than branching directly off
   it. If so, this is a **multi-stage landing**: land the upstream branch into `$TARGET` first,
   then rebase/retarget `$FEATURE` onto the new `$TARGET` before continuing — don't assume a
   single flat branch-onto-target shape until this is checked.
1. **File-to-layer map.** Assign each changed file to a layer (or your corrected set). Flag
   files that span layers.
2. **Churn partition.** Split the deletions into *intra-branch churn* (deletes lines this
   branch itself added earlier — these fold away for free) and *modifications to pre-existing
   `TARGET` code* (this set localises the **coupling hotspots** and is where any real
   disentangling effort goes). Report it explicitly.
3. **Green-window risk.** Determine whether the API changes break existing tests until the new
   tests replace them — i.e. whether any commit ordering has a window where no slicing can be
   green. Report it; it constrains the Slice ordering and oracle policy.
4. **Test ergonomics.** Is there a fast build + unit layer *independent* of the integration
   framework? How slow/flaky is the integration suite (which this branch is itself
   destabilising)? This decides the per-commit test policy.

**Gate 1:** present `churn-coupling-report.md` and a feasible-granularity recommendation
(clean ~4–5 commit series vs. coarser landing). Wait.

## Phase 2 — Slice (propose, then stop)

*Read-only. Plan only; do not re-stage. May run alongside Harvest.*

1. Propose a **dependency-ordered series** (API → CLI → framework → tests). Per commit: message
   intent, files/hunks, dependencies, and whether it builds + passes unit tests standalone.
2. Call out **hunks that cannot be cleanly assigned** (the coupled spots from Recon). For
   each, propose either coarsening (merge two commits) or a small refactor to separate concerns
   — and mark which need a human decision rather than being decided autonomously.
3. Propose the **test-passing policy.** Default given this branch's instability: **build +
   unit tests pass at every commit**, but the **full integration suite** is required only at
   **layer boundaries** (after the API commit, after the CLI commit) and at the **tip** — not
   after every slice, because the branch is destabilising that suite mid-series. If the suite
   proves too flaky to serve as a mid-series oracle, **fall back to coarser slicing** rather
   than thrashing against it.

**Gate 2:** present `commit-series-proposal.md` and the policy. Wait.

## Phase 3 — Harvest (propose, then stop)

*Read-only. Draft only; do not apply. May run alongside Slice.*

1. Read all commit messages and their diffs. Triage, per logical area, into: candidate
   **durable inline insight** (invariants, constraints, non-obvious gotchas about the *current*
   code); candidate **ADR material** (alternatives tried/rejected, decisions, trade-offs); and
   **superseded noise to drop** (logged, not silently discarded).
2. For each survivor, mark a **proposed destination** (inline at `file:line`, or a named ADR)
   and your **confidence**. Do not invent rationale not grounded in the commits or code; flag
   uncertainty rather than guessing.
3. **Draft the ADR(s)** in the repo's location/format.
4. **Draft the inline comments**, sited at specific final-tree lines, presented as a reviewable
   diff — **not yet applied**.
5. **Run the compliance sweep** (see the dedicated section below) alongside 1–4.

**Gate 3:** present `insight-map.md`, `discarded-commentary.md` (audit trail), the ADR drafts,
the inline-comment diff, and the compliance sweep's findings (below). Wait.

## Compliance sweep (part of Harvest)

Alongside harvesting positive insight (Phase 3 above), sweep for the negative case: content
already in the tree that violates this repo's own documentation conventions (the rules
established under "Inputs to confirm before starting"). Two things make this different from
ordinary Harvest work, and each earns its own step.

**Sweep `$TARGET` too, not just `$FEATURE`.** A large branch's own final tree is the obvious
place to check, but `$TARGET`'s current tip can carry its own pre-existing violations in files
`$FEATURE` never touches at all — invisible to any sweep scoped only to the branch's diff. Run
an independent sweep of `$TARGET` (same methodology below) and land its fixes as their own small,
standalone PR, on its own schedule, merged into `$FEATURE` before that branch's own final-tree
sweep runs — so the final-tree sweep only has to run once, against content that already reflects
`$TARGET`'s own fix, rather than needing a second reconciling pass.

**Detection methodology: semantic reading, not keyword search.** A keyword/grep pass (searching
for phrases like "previously", "no longer", "used to", or a specific external repo's name) is
fast but structurally incomplete in two ways: it misses any paraphrase that avoids the exact
words searched for, and — more importantly where the rule concerns external-file references — it
can only search for a name already known in advance. If the risk is exactly an *undisclosed*
external reference, a keyword list is blind to it by construction (a private filesystem path or
an unfamiliar repo name mentioned once in a comment will never match a list built from the
external repos you already know about). Prefer judging each file's actual content against the
rule's meaning — would a reader conclude this narrates a past state rather than describing the
current one; does this reference something that doesn't resolve to a file inside this repo,
whether or not its name is recognisable — over pattern-matching specific phrasings. A grep pass
is still worth keeping as a cheap, fast supplementary cross-check alongside the semantic read,
never as the sole method.

**Execution.** Each file or functional area's compliance is independent to judge, so parallelise:
dispatch one subagent per top-level directory/subsystem, each reading full file content (not
grep excerpts) against the rules' actual meaning, rather than one large agent working through the
whole tree serially. The specific mechanism that makes this affordable at scale: the expensive
part — reading entire files in full — happens **inside each subagent's own, disposable context**,
and only a compact findings report (file:line, the line content, which rule, a one-line reason)
crosses back to the orchestrator. That subagent's context, full file text included, is then
discarded — it never accumulates in the orchestrator and never carries forward into any other
subagent's context. This is what makes exhaustive full-text reading cheap in aggregate: the cost
of reading is bounded per subagent and thrown away, not accumulated across one ever-growing
context that has to hold everything read so far. Because this is a bounded classification task
on independent chunks, default to a cheaper model for the classification pass itself — reserve a
stronger model for adjudicating genuinely ambiguous findings the cheaper pass flags as uncertain,
not for the bulk sweep. Exclude vendored/build/generated content and pure-binary assets from
scope; they carry no comments worth reading and inflate cost for no signal.

**Where the fixes land.** Don't distribute each fix to whichever original commit "caused" the
violation, chasing precise attribution — for comment-only content that costs real per-line
git-blame-style effort for no real benefit, and cuts against self-containment (see Principles): a
documentation-hygiene pass is itself one coherent change. Gather sweep fixes into one or two
dedicated commits (per logical landing group, if `$FEATURE` is itself split into multiple) rather
than shredding them across the curated series.

## Phase 4 — Setup (execute, low risk)

*First phase with state changes. Run immediately before Execute.*

1. **Archive the raw branch** before anything else: `git tag raw/$FEATURE $FEATURE`. This
   applies when `$FEATURE` is a multi-commit branch — squashing away its intermediate history
   is exactly what makes the tag necessary; a single-commit branch has nothing to archive. The
   full commit record must remain recoverable forever even though it won't enter `TARGET`'s
   history. Every landing commit built from this tag (whether `$FEATURE` lands as one squashed
   commit or a curated multi-commit series) must cite it in a trailer, so later archaeology can
   tell a squash-rewrite apart from a genuinely unmerged branch — a plain diff/ancestor check
   can't:
   ```
   Raw-History: raw/$FEATURE (<original-tip-short-hash>)
   ```
2. Capture `git diff --stat $BASE..$FEATURE` and the per-file list. Record
   `git rev-parse $FEATURE` as `FEATURE_TIP`.
3. Establish the **baseline oracle**: confirm the tip builds and the full suite passes at the
   tip. Record build/test times. If the tip is not green, stop and report — curation can't
   proceed on a broken tip.
4. Create the staging branch: `git switch -c $FEATURE-curated-staging $TARGET`. All curated
   commits land here first; fast-forward `$TARGET` afterwards.

## Phase 5 — Execute (only after Gates 2 and 3 are approved)

1. Apply the approved **inline comments and ADR(s)** to the tip tree first, so they become part
   of the final diff and ride into whichever commit owns their lines. Re-run `BUILD_CMD` +
   `UNIT_CMD`. Then tag the canonical target:
   ```
   git tag final/$FEATURE
   ```
2. Build the curated branch and collapse to the final tree:
   ```
   git switch -c $FEATURE-curated raw/$FEATURE
   git checkout final/$FEATURE -- .   # bring in comments + ADR
   git reset --soft $BASE             # all branch changes now staged at BASE
   git reset                          # unstage; changes now in the working tree
   ```
3. Re-stage into the approved buckets (`git add <pathspec>` / `git add -p`) and commit each in
   dependency order with the drafted messages. After **each** commit run `BUILD_CMD` +
   `UNIT_CMD`; run `INTEG_CMD` at the **layer boundaries** and the **tip** per the policy. On
   failure, re-bucket or split; if a commit cannot be made green, **surface it to the human**
   rather than landing anything questionable.
4. **Verify the correctness invariant:**
   ```
   git diff final/$FEATURE $FEATURE-curated   # must be EMPTY
   ```
   If non-empty, stop — re-slicing has lost, added, or altered code.
5. Confirm `INTEG_CMD` passes at the curated tip. Optional: `git bisect` sanity over the stable
   (API/CLI) layers.

## Phase 6 — Handoff

Produce a summary for final human review: the curated series with messages, the ADR(s), the
applied inline-comment diff, the Recon churn/coupling report, and any unresolved
human-decision items. Prepare the merge of `$FEATURE-curated` into `$TARGET`. `raw/$FEATURE`
stays as the permanent record of the full exploratory history.

---

## Guardrails (non-negotiable)

- **Propose before executing at every gate.** This is supervised, not autonomous. Stop at the
  end of Recon, Slice, and Harvest.
- **Never lose code.** The tip-equality invariant (Execute step 4) is the backstop; check it.
- **Never lose information silently.** Discards are logged; `raw/$FEATURE` stays intact.
- **Inline comments = current-state rationale only.** Transition narrative goes in commit
  bodies; chosen-over-alternatives narrative goes in ADRs.
- **Don't fabricate rationale.** Ground every inline comment and ADR claim in the commits or
  the code; mark anything uncertain.
- **Don't thrash on a flaky oracle.** If the integration suite can't be a reliable mid-series
  signal, prefer coarser commits over fighting it.

## Deliverables checklist

- [ ] `raw/$FEATURE` and `final/$FEATURE` tags, cited via a `Raw-History:` trailer on the
  landing commit(s)
- [ ] `churn-coupling-report.md` (with green-window risk and granularity recommendation)
- [ ] `commit-series-proposal.md` (Track A) and approved test-passing policy
- [ ] `insight-map.md` + `discarded-commentary.md` (Track B audit trail)
- [ ] ADR(s) in the repo's ADR location
- [ ] applied inline-comment diff
- [ ] compliance sweep findings for both `$FEATURE` and `$TARGET`, and `$TARGET`'s own fixes
  landed as their own PR ahead of the rest
- [ ] `$FEATURE-curated` branch, verified byte-identical to `final/$FEATURE`
