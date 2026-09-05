# Plan: dflash2-official-image

Source brainstorm: `docs/brainstorms/2026-09-04-dflash2-official-dev-image.md` (decided 2026-09-05).
Issue: https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark/issues/6

**Goal:** A fresh clone runs `./start-dflash.sh` and serves DFlash2 from the official multi-arch `lmsysorg/sglang:dev-qwen38-27b-dflash2` image, pulled by digest, with no git clone and no `docker build`; the `patch/` builder is removed and the docs stop claiming DFlash2 has no upstream image. MTP (`start.sh`) and DSpark (`start-dspark.sh`) stay on `lmsysorg/sglang:qwen38-27b`.

**Image facts to pin (verified 2026-09-04/05 against Docker Hub + GitHub):**

| Item | Value |
|---|---|
| Tag | `lmsysorg/sglang:dev-qwen38-27b-dflash2` |
| Multi-arch index digest (the pin) | `sha256:616a3e97f45191af975896cfa644279096cb31bd408a071c2e99ca7209c3cafe` |
| arm64 child manifest | `sha256:088ce12e606cb39b4fc2a20f0bd7c44c512126a29ebbb5c717a1ca0889f093c9` |
| Compressed pull size (arm64) | 14.4 GB, 68 layers |
| Upstream build | commit `5f55db35e`, branch `dflash2-pin-1cf2b8c-nccl`, built 2026-08-22 (`ai.sglang.build.commit` label) |
| Contains | DFlash2 #35371 (`c14312a66`), quantized-lm_head selector #35496 (`1cf2b8c54`), `extra_buffer_lazy` for DFLASH #34763; CUDA 13.0.3 base |
| Cookbook | `docs/src/snippets/configs/Qwen/qwen3.8-27b.jsx` maps `dgx-spark` to this tag; all 48 GB10 cells boot-and-serve on `1cf2b8c` |
| Not in `v0.5.18` | DFlash2 commit is not an ancestor of the tag (GitHub compare: diverged); no `v0.5.19` exists |

Pin the **index** digest, not the arm64 child: `docker pull repo@<index>` resolves linux/arm64 automatically and stays multi-arch.

## Affected files

- `start-dflash.sh` — `IMAGE` default becomes `lmsysorg/sglang@sha256:616a…`; `ensure_image()` becomes probe → `docker pull` → re-verify → local readable tag, with the house-style `|| { echo …; exit 1; }` failure line that names the `IMAGE=` rollback; delete the `*-minoverlay` case and `build_mode`; rewrite the header comment (lines 8-16) to drop "built automatically from patch/" and "nvfp4-fp4 needs the image patch". Everything else (draft pin, `DF_TARGET`, 0.90 pin, `extra_buffer`, `DF_EXTRA`, `exec start.sh`) unchanged.
- `patch/` — delete (`build-dflash2-image.sh`, `dflash2_nvfp4_head.patch`, `overlay-dflash2/`). Tag the pre-removal commit `dflash2-builder-last` (on `751e29e`) so it stays discoverable; name the tag in README and CHANGELOG.
- `.gitignore` — remove `!patch/` and `!patch/**`, reword the line-14 comment; add per-directory whitelist for `docs/brainstorms/*.md` and `docs/plans/*.md` (parent chain must be un-ignored first: `!docs/`, `!docs/brainstorms/`, `!docs/brainstorms/*.md`, `!docs/plans/`, `!docs/plans/*.md`). Not `!docs/**`: analysis write-ups must stay untracked by policy.
- `README.md` — 13 sites: 35 (image table gains a DFlash2 row), 62, 72, 73 (delete row), 80, 84, 134, 136, 185, 263, 266, 282-283, 310; add `docs/` to the layout tree and whitelist prose; relabel the 2026-08-19 DFlash2 numbers as "self-built image, replication on the official image pending"; keep the one-canonical-table rule (no tok/s outside Measured).
- `CHANGELOG.md` — new top entry `## 2026-09-05 — DFlash2 serves from the official SGLang image; builder removed` with `**Changed:**`, `**Removed:**`, `**Docs:**` and the digest/build-commit line.
- `stop.sh` — header lists `start-mtp-8889.sh` (removed) and omits `start-dflash.sh`; fix in passing (comment only).
- `docs/brainstorms/2026-09-04-dflash2-official-dev-image.md`, `docs/plans/2026-09-05-dflash2-official-image.md` — tracked once the whitelist lands.

## Approach

Mirror `ensure_cached()` (`start-dflash.sh:53-69`): probe, fetch, re-verify, hard-fail with a message that quotes the value and names the way out. Keep the local-first branch so `IMAGE=lmsysorg/sglang:qwen38-27b-dflash2 ./start-dflash.sh` still runs an already-built legacy image (that tag exists only on disk; an unconditional pull would fail with `manifest unknown`). After a digest pull, `docker tag` the image to `lmsysorg/sglang:dev-qwen38-27b-dflash2` so `docker images` does not show `<none>` and invite a prune; the container still runs by digest. Print one line naming tag + short digest + upstream commit before `exec start.sh` so `.sglang.log` records which image produced a run. Keep `docker pull` stderr unredirected: the first run is a ~14 GB download before the 2.7 GB draft pull.

## Edge cases

- Existing self-built image on disk: the script silently starts pulling 14 GB and leaves the old image orphaned. Print a notice naming the old tag and `docker image rm`.
- `docker image inspect repo@digest` only matches images that were pulled from a registry (RepoDigests); it never matches a `docker build` output. Fine for the new default, and exactly why the local-first branch must key on the user's `IMAGE` value, not on the digest.
- `DOCKER_DEFAULT_PLATFORM=linux/amd64` in the environment would pull the amd64 child and fail at `docker run`. Out of scope on a GB10; mention in troubleshooting only.
- Anonymous Docker Hub pull limit: `toomanyrequests` on shared networks; `docker login` fixes it. One troubleshooting line.
- `export IMAGE` must stay before `exec start.sh`, and `ensure_image` before `ensure_cached` (draft pull runs inside the image). Current order already correct; do not reorder.
- Mem pin: the 0.90 / 16 profile was validated on the self-built image. The cookbook pins 0.80 on GB10 (0.85 trips earlyoom, exit -15). First boot on the official image should watch `journalctl -u earlyoom`; rollback is `DF_EXTRA="--mem-fraction-static 0.80"` (appended last, wins). Script default stays 0.90 until the box says otherwise.
- `MAMBA_CACHE_SIZE` is sized for S=4 (`extra_buffer_lazy`) but `start-dflash.sh` forces `extra_buffer` (S=5 per cookbook). Pre-existing, image-independent; verify with `grep -E "max_running_requests|max_mamba_cache_size" .sglang.log` on the validation boot. Follow-up, not this change.
- `extra_buffer_lazy` is now supported for DFLASH (#34763). Keep the forced `extra_buffer` here; test lazy on the validation boot as a follow-up.
- Upstream open bugs on this image family: sglang #36548 (cross-request state bleed under concurrency), #38009 (greedy divergence with thinking on). Document as watchpoints in Logs & troubleshooting; do not change defaults.

## Test plan

- Static, on the Mac: `bash -n` on all four scripts; `shellcheck -S warning` (baseline is clean; must stay clean).
- Dry logic, on the Mac (no GPU): `IMAGE=busybox:latest DF_TARGET=nvfp4 bash -x start-dflash.sh` is not viable (it execs start.sh which needs `--gpus`). Instead source-test `ensure_image` in isolation: extract the function into a scratch script with `IMAGE` set to (a) a present local image → "Using …", (b) a bogus digest → pull fails with the rollback message and exit 1, (c) the real digest on a machine with docker → pulls, re-verify passes, tag applied. On this Mac only (a) and (b) are cheap; (c) is 14 GB and belongs on the Spark.
- The A/B harness `bench/ab-image.sh` automates the gate below as a single-session main-vs-branch comparison. Because `start-dflash.sh` is byte-identical from `DF_TARGET` through `exec` on 751e29e and on this branch, side A is reproduced by `IMAGE=lmsysorg/sglang:qwen38-27b-dflash2` rather than a checkout of main, so the image is the only variable and the BF16-head checkpoint is held constant on both sides.
- Validation boot on the GB10 (the gate before merge, not part of this commit): fresh `docker image rm lmsysorg/sglang:qwen38-27b-dflash2` optional; `./start-dflash.sh`; expect in `.sglang.log`: `speculative_algorithm='DFLASH'`, draft `z-lab/Qwen3.8-27B-DFlash2`, `speculative_num_draft_tokens=8`, `Initialized DFLASH draft runner`, `folded into the draft cuda graph`; no `kept eager (reason=quantized lm_head)`; no earlyoom kill. Repeat with `DF_TARGET=nvfp4-fp4` (selector must fold, not error). Then `bench/ndec.py` n≥3: code within noise of 50.9, essay of 25.4. Record numbers in README Measured with date + "official image sha256:616a…".
- Grep gate: `grep -rn "patch/\|build-dflash2\|minoverlay\|no released\|derived image" README.md CHANGELOG.md start-dflash.sh` returns only the CHANGELOG history line and the tag pointer.

## Conventions to follow

- Commits: sentence-case imperative, optional `area:` prefix, no conventional-commit type; body explains why and carries an explicit `Verified:` line stating exactly what was and was not run (the GB10 boot is pending, say so). Name where removed code still lives (tag `dflash2-builder-last`).
- Bash: `set -euo pipefail`, braced+quoted expansions, `[[ ]]`, lowercase `snake_case` functions with `local`, errors as `echo "…"; exit 1` to stdout, optional flags as arrays.
- Precedence rule stays: shell env > `.env` > script default; `start-dflash.sh` does not read `.env`, so only a shell-env `IMAGE=` overrides it (document as today).
- README: one canonical performance table; every number carries date + engine + image; Scripts table one row per script; whitelist prose (line 80) and layout tree mirror `.gitignore`.
- No CI exists; no tests to skip; do not invent a CI file in this change.

## Open questions / risks

- Digest pin means a future upstream rebuild of the tag is invisible until someone bumps the pin. README gets a two-line "how to bump" note (`docker manifest inspect` or the registry HEAD for `docker-content-digest`).
- Local tag alias uses the upstream tag name; if upstream later moves the tag and a user `docker pull`s it manually, the alias points at the newer build while the script keeps running the pinned digest. Document; acceptable.
- Whether to keep `MAX_CONCURRENT_REQUESTS=16` as the sample default while #36548 is open: keep, document.
- No PR yet by decision: land on the local branch, review locally, merge after the GB10 validation boot.

Deferred, pre-existing and out of scope: README line 60 and the Quick-start heading say `MAX_CONCURRENT_REQUESTS=10` while `.env.sample` ships 16 (fixing it touches anchored headings).

**Estimated size:** M (~60-80 LOC of script/gitignore change, ~40 README/CHANGELOG lines touched, 4,800 LOC deleted under `patch/`).

## Commit plan (as landed)

1. `Track docs/brainstorms and docs/plans; add the DFlash2 official-image decision record and plan` — `.gitignore` docs whitelist + the two docs only (the README whitelist/layout lines went into commit 2 with the rest of the README edit).
2. `start-dflash.sh: pull the official DFlash2 image (digest-pinned) and drop the patch/ builder` — script, `patch/` removal, `.gitignore` patch lines, README, CHANGELOG, `stop.sh` header. Tag `dflash2-builder-last` created on the parent commit first (local only; push it with the merge).
3. Review-loop fixes (local panel: correctness, docs-vs-code, security — all GO): alias tag never re-points an existing tag, legacy-image note only after a successful pinned pull, README chronology/draft-name/size fixes, CHANGELOG `stop.sh` bullet.
