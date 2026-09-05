# Brainstorm: move DFlash2 serving onto the official SGLang dev image

Source: https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark/issues/6#issuecomment-5544433193
Date: 2026-09-04

## Facts established (verified 2026-09-04)

- **The stable-release premise in issue #6 is still false.** `v0.5.18` (tag 2026-08-22, image commit `71de97b26`) does *not* contain the DFlash2 commit `c14312a66` (#35371) — GitHub compare says "diverged". The Qwen3.8 rebase only landed on main on 2026-08-29 (#35758). No `v0.5.19` tag exists. So there is still nothing "stable" to move to.
- **What the commenter means by "the new dflash2 image" is `lmsysorg/sglang:dev-qwen38-27b-dflash2`.** Multi-arch (amd64 + arm64), built 2026-08-22 by `workflow_dispatch` from branch `dflash2-pin-1cf2b8c-nccl` at commit `5f55db35e`. That branch is `1cf2b8c54` (#35496, quantized target `lm_head` in the DFlash2 selector) plus three Docker/NCCL build fixes. It therefore contains: DFlash2 (#35371), the quantized-head selector (#35496), and `extra_buffer_lazy` support for DFLASH (#34763, merged 2026-08-15). CUDA 13.0.3 base, same as the pinned `qwen38-27b`.
- **Upstream cookbook now points DGX Spark at that tag** for *all* speculative modes (`docs/src/snippets/configs/Qwen/qwen3.8-27b.jsx`: `"dgx-spark": "lmsysorg/sglang:dev-qwen38-27b-dflash2"`), and states all 48 GB10 cells (3 checkpoints x MTP/DSpark/DFlash2 x strategy x SSM dtype) boot-and-serve on `1cf2b8c`. Boot-and-serve only, no throughput numbers.
- **This repo's `patch/` machinery is now redundant for the default path.** `patch/dflash2_nvfp4_head.patch` re-implements what #35496 merged upstream (`lm_head.quant_method.apply` selector). `start-dflash.sh` still *builds* a derived image (git clone + overlay) whenever the local tag is missing; it never tries `docker pull`.
- **Reported result on the dev image (issue #6, ruicatxiao, 2026-08-24):** ~47/44/57 tok/s (Q&A/code/JSON) vs ~29/29/35 on MTP — the same ~1.5x this repo measured on its self-built image, i.e. the official image performs like ours.
- **Known upstream DFlash2 bugs on this image family (open):** #36548 state corruption / cross-request context bleed under concurrent load; #38009 greedy DFlash2 output diverges from target-only when thinking is on. Both matter for the repo's `MAX_CONCURRENT_REQUESTS=16` default and thinking-on default.
- **Cookbook DGX Spark pins** are `--mem-fraction-static 0.80` (0.85 trips DGX OS earlyoom at boot/long prefill). This repo runs 0.90 (DFlash2/DSpark) and 0.95 (MTP), validated on-box on the *old* image. Re-validation on the new image is required before publishing numbers.
- `README.md` asserts "no released SGLang image has DFlash2 support" in ~12 places (lines 62, 72, 73, 84, 136, 185, 222, 282-283, 310). `CHANGELOG.md`, `patch/build-dflash2-image.sh` header, and `start-dflash.sh` header repeat it.

## Clarified Problem Statement

**Goal:** Make `./start-dflash.sh` serve DFlash2 from the official multi-arch `lmsysorg/sglang:dev-qwen38-27b-dflash2` image (pulled, not built) by default, and bring the docs in line with the fact that an upstream DFlash2 image exists.

**Constraints:**
- Fresh clone must work with only docker + curl (no git clone of sglang, no local image build) — that is the whole point of the issue.
- Keep the DFlash2 A/B numbers honest: any number in README must say which image produced it; the existing 2026-08-19 numbers were on the self-built image.
- Keep `IMAGE=` env override semantics (shell env wins; unset = default) so users can roll back to the self-built image or forward to a newer tag.
- Do not silently change MTP/DSpark behavior (they run on `qwen38-27b`, measured 2026-08-18) unless that is an explicit decision with its own bench.
- Reproducibility: the `dev-*` tag is a rolling `workflow_dispatch` tag; pin by digest (`lmsysorg/sglang@sha256:…`) or record the digest + build commit in README/CHANGELOG.

**Non-goals:**
- Waiting for `v0.5.19` — it does not exist and its content is unknown.
- Re-tuning the DFlash2 stack (draft tokens, mem-fraction sweep, `extra_buffer` vs `extra_buffer_lazy`) beyond a boot + replication bench.
- Touching YaRN / long-context behavior (still MTP-only).
- Fixing upstream bugs #36548 / #38009; only document them as watchpoints.

**Success criteria:**
- On a box with no local `qwen38-27b-dflash2` image, `./start-dflash.sh` pulls the official image and reaches READY without git/network builds.
- `.sglang.log` shows `speculative_algorithm='DFLASH'`, the pinned draft, `speculative_num_draft_tokens=8`, and `folded into the draft cuda graph` (not `kept eager (reason=quantized lm_head)`), for both `DF_TARGET=nvfp4` and `nvfp4-fp4`.
- `bench/ndec.py` n>=3 on the new image within noise of the 50.9 / 25.4 (code / essay) baseline, at 0.90 / 16 concurrent, no earlyoom kill or reboot.
- README no longer claims DFlash2 has no upstream image; Scripts / Configuration / Notable serving choices / Logs / Repository layout / Credits rows updated; CHANGELOG entry dated; issue #6 answered with the commit.

## Approaches Considered

### Approach A: Swap the DFlash2 default image, keep the builder as fallback
- Sketch: `start-dflash.sh` default `IMAGE` becomes the official tag (digest-pinned). `ensure_image()` order becomes: local present -> `docker pull` -> only if `IMAGE` matches the legacy `qwen38-27b-dflash2*` names, fall through to `patch/build-dflash2-image.sh`. `patch/` stays tracked as the documented escape hatch.
- Affected files: `start-dflash.sh` (IMAGE default, `ensure_image`, header comment), `README.md` (~12 lines listed above), `CHANGELOG.md` (new dated entry), `patch/build-dflash2-image.sh` header (no longer "no released tag ships DFlash2"; now "legacy / pin-your-own-commit builder").
- Tradeoffs: smallest diff, fully reversible via `IMAGE=`. MTP/DSpark untouched, so their numbers stay valid. Leaves two images on disk and two image stories in the README. Still need one bench session on the box to re-stamp the DFlash2 column.
- Effort: S (code) + one bench boot.

### Approach B: One official image for all three launchers, delete the builder
- Sketch: `start.sh` default `IMAGE` -> the official tag (digest-pinned); `start-dflash.sh` inherits it; remove `patch/` and its `.gitignore` whitelist (history stays in git; optionally tag `dflash2-build-artifacts-2` first). Re-bench MTP, DSpark and DFlash2 on the same boot and republish the canonical table.
- Affected files: `start.sh`, `start-dflash.sh`, `patch/` (deleted), `.gitignore`, `README.md` (image row, Scripts, Which engine, Measured, Repository layout, Credits), `CHANGELOG.md`.
- Tradeoffs: matches upstream cookbook exactly (one image, 48 validated cells) and removes 200 KB of build machinery. Invalidates every MTP/DSpark number in README until re-measured — the dev image is a different build (branch of 2026-08-22 vs nightly 2026-08-14, different FlashInfer) and the MTP mem-fraction 0.95 may not survive. Largest bench cost; highest chance of regressions in the engines that were not the subject of the issue.
- Effort: M–L (mostly bench time).

### Approach C: Docs-only — point users at the official image via `IMAGE=`
- Sketch: no script changes except making `ensure_image` try `docker pull` before building. README Quick start adds `IMAGE=lmsysorg/sglang:dev-qwen38-27b-dflash2 ./start-dflash.sh` and rewrites the "no released image" claims into "official dev tag exists; self-built image remains the measured default".
- Affected files: `start-dflash.sh` (pull-before-build only), `README.md`, `CHANGELOG.md`.
- Tradeoffs: near-zero risk and no bench needed, but the fresh-clone default still builds an image — the issue is only half answered and the repo keeps shipping a redundant patch as the default path.
- Effort: XS.

## Recommendation

**Decided 2026-09-05 (user):** Approach A's image swap plus Approach B's cleanup, without Approach B's MTP/DSpark change. Concretely:

1. `start-dflash.sh` defaults to the official image, pinned by digest, with `docker pull` as the only acquisition path (no build fallback, no `-minoverlay` mode). `IMAGE=` override semantics unchanged.
2. Delete `patch/` (builder, NVFP4 head patch, overlay) and its `.gitignore` whitelist. Tag the pre-removal commit so the builder stays findable in history.
3. `start.sh` / `start-dspark.sh` stay on `lmsysorg/sglang:qwen38-27b`; their numbers stay valid. Unifying all three launchers is a separate change gated on its own bench.
4. README / CHANGELOG stop claiming DFlash2 has no upstream image; record the digest + upstream build commit (`5f55db35e`, branch `dflash2-pin-1cf2b8c-nccl`) and mark the 2026-08-19 DFlash2 numbers as "self-built image; replication on the official image pending".
5. No PR yet: the change lands on the local branch and is reviewed locally; it merges only after a boot + `bench/ndec.py` replication on the GB10.

Why not keep the builder as a fallback: both gaps it closed (no DFlash2 image; no NVFP4 head support) are closed upstream in the same image, and a digest pin covers the "tag rebuilt" case. The residual risk (tag deleted) would need a new image anyway.

## Open questions (non-blocking)

- Pin by digest or by tag? Digest is reproducible; tag auto-picks up upstream rebuilds. Recommend digest in the script, tag in the docs, with a one-line "how to bump" note.
- Keep the forced `--mamba-radix-cache-strategy extra_buffer`? The new image supports `extra_buffer_lazy` with DFLASH (#34763), which is what `start.sh` uses and what the GDN pool sizing (`S=4`) assumes. Worth one boot to check; otherwise keep `extra_buffer` and the existing note.
- hasso5703's proposed DGX Spark cell (sglang #35860) adds `--speculative-draft-model-quantization unquant` and runs at `--mem-fraction-static 0.50` with torch.compile. Not needed for parity, but a candidate for a follow-up sweep.
- Should `MAX_CONCURRENT_REQUESTS=16` stay the DFlash2 default while sglang #36548 (cross-request state corruption under concurrency) is open? At minimum document it in Logs & troubleshooting.
- Does the pull path need `HF_TOKEN`? No (Docker Hub anonymous pull), but the draft pull still does — unchanged.
- Reply on issue #6 once merged, and note that `v0.5.18` does not actually include DFlash2 so the "wait for stable" plan is moot.
