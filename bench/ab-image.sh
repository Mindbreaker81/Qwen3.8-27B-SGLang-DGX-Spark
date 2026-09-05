#!/usr/bin/env bash
set -euo pipefail

# One-session A/B (or A/B/M) of the DFlash2 serving path on this box.
#
#   A = main's self-built  lmsysorg/sglang:qwen38-27b-dflash2   (start-dflash.sh)
#   B = official pinned    lmsysorg/sglang@sha256:616a3e97…     (start-dflash.sh)
#   M = EAGLE/MTP on the stock lmsysorg/sglang:qwen38-27b       (start.sh)
#
# A vs B isolates the *image*: from DF_TARGET through `exec`, start-dflash.sh is
# byte-identical on main (751e29e) and on this branch, so both sides run the same
# flag stack, checkpoint and pinned draft.
# B vs M is the *engine* question (DFlash2 vs MTP) measured in one session, which
# is what makes it quotable — see the ratio printed in the summary.
#
# Why one session: this box drifts, and two boots of the SAME image measured
# 6.5% apart on the essay probe (2026-09-05). Interleave, never compare boots
# across a session, and treat code deltas <15% as noise.
#
#   ./bench/ab-image.sh                      # A,B
#   SEQ="A B B A" ./bench/ab-image.sh        # ABBA, cancels linear drift
#   SEQ="M B B M" ./bench/ab-image.sh        # DFlash2 vs MTP, same session
#   MODEL_PATH=org/ckpt ./bench/ab-image.sh  # retarget every side at one checkpoint
#   LABEL=uncensored ./bench/ab-image.sh     # names the artifact directory
#   RUNS=3 WARMUP=0 DRY_RUN=1 ./bench/ab-image.sh
#
# Each boot runs one DISCARDED warmup pass before the timed runs: the two-call
# delta method is wrecked by cold start on a fresh boot (the 60-token call
# absorbs graph warm-up, shrinking the denominator), which produced readings of
# 183 and even -371 tok/s on 2026-09-05. WARMUP=0 restores the old behaviour.
#
# Side A needs the retired self-built image on disk. If it is gone, rebuild it
# without touching this working tree:
#   git worktree add /tmp/dflash2-builder 751e29e
#   /tmp/dflash2-builder/patch/build-dflash2-image.sh
#   git worktree remove /tmp/dflash2-builder
#
# This script only stops containers. It never removes images, checkpoints or caches.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

LEGACY_IMAGE="${LEGACY_IMAGE:-lmsysorg/sglang:qwen38-27b-dflash2}"
STOCK_IMAGE="${STOCK_IMAGE:-lmsysorg/sglang:qwen38-27b}"
CONTAINER_NAME="qwen3.8-27b-sglang"
RUNS="${RUNS:-3}"
WARMUP="${WARMUP:-1}"
SEQ="${SEQ:-A B}"
MODEL_PATH="${MODEL_PATH:-}"
LABEL="${LABEL:-}"
DRY_RUN="${DRY_RUN:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT}/bench/_ab${LABEL:+-${LABEL}}-${STAMP}"

for f in start.sh start-dflash.sh stop.sh bench/ndec.py; do
  [[ -f "${ROOT}/${f}" ]] || { echo "run this from the repo (missing ${f})"; exit 1; }
done
command -v docker >/dev/null 2>&1 || { echo "docker is not on PATH"; exit 1; }

side_label() {
  case "$1" in
    A) echo "A DFlash2 self-built" ;;
    B) echo "B DFlash2 official" ;;
    M) echo "M MTP/EAGLE stock" ;;
    *) echo "unknown side '$1' in SEQ (use A, B or M)"; exit 1 ;;
  esac
}
side_engine() { case "$1" in M) echo "EAGLE" ;; *) echo "DFLASH" ;; esac; }

# --- preflight -------------------------------------------------------------
echo "=== preflight ==="
if [[ " ${SEQ} " == *" A "* ]]; then
  docker image inspect "${LEGACY_IMAGE}" >/dev/null 2>&1 || {
    echo "side A needs ${LEGACY_IMAGE} on disk and it is not here."
    echo "Rebuild it in a scratch worktree (see the header), or drop A from SEQ."
    exit 1
  }
  echo "side A image: ${LEGACY_IMAGE}"
fi
if [[ " ${SEQ} " == *" M "* ]]; then
  docker image inspect "${STOCK_IMAGE}" >/dev/null 2>&1 || {
    echo "side M needs ${STOCK_IMAGE} on disk and it is not here."; exit 1
  }
  echo "side M image: ${STOCK_IMAGE}"
fi
[[ -n "${MODEL_PATH}" ]] && echo "checkpoint override (all sides): ${MODEL_PATH}"

# ./stop.sh only stops qwen3.8-27b-sglang and qwen3.8-27b-sglang-mtp. Anything
# else holding the GPU or port 8888 has to go before this comparison means anything.
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "our container ${CONTAINER_NAME} is up; ./stop.sh will stop it between sides"
fi
others="$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -v "^${CONTAINER_NAME}\b" || true)"
if [[ -n "${others}" ]]; then
  echo "other containers are running — ./stop.sh does NOT touch these, stop them"
  echo "yourself if they hold the GPU, unified memory or port 8888:"
  echo "${others}" | sed 's/^/  /'
fi
if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q '[:.]8888 '; then
    echo "port 8888 is already in use by something that is not ${CONTAINER_NAME}."
    echo "The bench talks to 127.0.0.1:8888 and would measure that instead. Stop it first."
    exit 1
  fi
fi
grep -E 'MemAvailable' /proc/meminfo 2>/dev/null || true
echo "plan: SEQ='${SEQ}', ${RUNS} timed run(s) per boot, warmup=${WARMUP}, artifacts -> ${OUT}"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY_RUN=1 — nothing booted."
  exit 0
fi
mkdir -p "${OUT}"

# --- helpers ---------------------------------------------------------------
stop_all() {
  ./stop.sh >/dev/null 2>&1 || true
  local tries=0
  while docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; do
    tries=$((tries + 1))
    [[ ${tries} -gt 60 ]] && { echo "container ${CONTAINER_NAME} did not stop"; exit 1; }
    sleep 2
  done
}

verify_boot() {
  # $1 = side, $2 = artifact tag
  local side="$1" tag="$2"
  local log="${OUT}/${tag}.sglang.log"
  local want ok=1
  want="$(side_engine "${side}")"
  cp -f .sglang.log "${log}" 2>/dev/null || { echo "  no .sglang.log to verify"; return 1; }

  local ran_image
  ran_image="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo '?')"
  echo "  container image: ${ran_image}"
  echo "${ran_image}" > "${OUT}/${tag}.image"

  grep -q "speculative_algorithm='${want}'" "${log}" \
    || { echo "  MISSING: speculative_algorithm='${want}'"; ok=0; }
  if [[ "${want}" == "DFLASH" ]]; then
    if grep -q "folded into the draft cuda graph" "${log}"; then
      echo "  selector: folded into the draft cuda graph"
    elif grep -qE "kept eager \(reason=|unsupported quantized lm_head" "${log}"; then
      echo "  WARNING: selector kept eager — not the expected path on this image"
    fi
  fi
  grep -oE "speculative_draft_model_path='[^']+'|speculative_num_draft_tokens=[0-9]+|max_running_requests=[0-9]+|max_mamba_cache_size=[0-9]+|mem_fraction_static=[0-9.]+|model_path='[^']+'" "${log}" \
    | sort -u | sed 's/^/  /' | tee "${OUT}/${tag}.stack"
  [[ ${ok} -eq 1 ]]
}

launch_side() {
  # $1 = side, $2 = boot log path
  local side="$1" boot="$2"
  local dfx="${DF_EXTRA:-}" mx=""
  [[ -n "${MODEL_PATH}" ]] && { dfx="${dfx} --model-path ${MODEL_PATH}"; mx="--model-path ${MODEL_PATH}"; }
  case "${side}" in
    A) IMAGE="${LEGACY_IMAGE}" DF_EXTRA="${dfx}" ./start-dflash.sh > "${boot}" 2>&1 ;;
    B) DF_EXTRA="${dfx}" ./start-dflash.sh > "${boot}" 2>&1 ;;
    M) IMAGE="${STOCK_IMAGE}" EXTRA_ARGS="${mx}" ./start.sh > "${boot}" 2>&1 ;;
  esac
}

run_side() {
  # $1 = side, $2 = position index
  local side="$1" pos="$2" tag
  tag="$(printf '%02d-%s' "${pos}" "${side}")"
  echo
  echo "=== ${tag} — $(side_label "${side}") ==="

  stop_all
  grep -E 'MemAvailable' /proc/meminfo 2>/dev/null | sed 's/^/  /' || true
  local t_boot; t_boot="$(date -Is)"
  echo "${t_boot}" > "${OUT}/${tag}.started"

  echo "  booting ..."
  launch_side "${side}" "${OUT}/${tag}.boot.log" \
    || { echo "  BOOT FAILED — tail:"; tail -n 25 "${OUT}/${tag}.boot.log"; exit 1; }
  grep -q "SGLang is ready" "${OUT}/${tag}.boot.log" \
    || { echo "  server never reported ready; see ${OUT}/${tag}.boot.log"; exit 1; }

  verify_boot "${side}" "${tag}" || { echo "  boot verification failed for ${tag}"; exit 1; }

  # Cold start wrecks the first two-call delta; throw one full pass away.
  if [[ "${WARMUP}" == "1" ]]; then
    echo "  warmup pass (discarded)"
    python3 bench/ndec.py > "${OUT}/${tag}.warmup" 2>&1 || true
  fi

  local i
  for ((i = 1; i <= RUNS; i++)); do
    echo "  ndec run ${i}/${RUNS}"
    python3 bench/ndec.py 2>&1 | tee -a "${OUT}/${tag}.ndec" | sed 's/^/    /'
  done

  journalctl -u earlyoom --since "${t_boot}" --no-pager 2>/dev/null | grep -i "kill\|sglang" \
    | tee "${OUT}/${tag}.earlyoom" | sed 's/^/  earlyoom: /' || true

  stop_all
}

# --- run -------------------------------------------------------------------
pos=0
for side in ${SEQ}; do
  pos=$((pos + 1))
  side_label "${side}" >/dev/null
  run_side "${side}" "${pos}"
done

# --- summarise -------------------------------------------------------------
echo
echo "=== summary ==="
python3 - "${OUT}" <<'PY'
import glob, itertools, os, re, statistics, sys

out = sys.argv[1]
pat = re.compile(r"^(?P<name>.+?)\s+net decode =\s+(?P<tps>-?[\d.]+) tok/s")
label = {"A": "A DFlash2 self-built", "B": "B DFlash2 official", "M": "M MTP/EAGLE stock"}
sides, per_boot = {}, {}

for path in sorted(glob.glob(os.path.join(out, "*.ndec"))):
    tag = os.path.basename(path)[:-len(".ndec")]
    side = tag.split("-")[1]
    for line in open(path):
        m = pat.match(line.strip())
        if m:
            probe = "code" if m.group("name").startswith("code") else "essay"
            tps = float(m.group("tps"))
            sides.setdefault(side, {}).setdefault(probe, []).append(tps)
            per_boot.setdefault(tag, {}).setdefault(probe, []).append(tps)

if not sides:
    print("no ndec results parsed — check the .ndec files in", out)
    sys.exit(0)

print(f"{'side':22s} {'probe':6s} {'n':>2s} {'min':>7s} {'median':>7s} {'max':>7s}")
for side in sorted(sides):
    for probe in ("code", "essay"):
        v = sides[side].get(probe, [])
        if v:
            print(f"{label.get(side, side):22s} {probe:6s} {len(v):2d} "
                  f"{min(v):7.2f} {statistics.median(v):7.2f} {max(v):7.2f}")

print("\nper boot (watch this for drift — same side, different boot):")
for tag in sorted(per_boot):
    c = per_boot[tag].get("code", []); e = per_boot[tag].get("essay", [])
    cm = f"{statistics.median(c):6.2f}" if c else "     -"
    em = f"{statistics.median(e):6.2f}" if e else "     -"
    print(f"  {tag}  code {cm}   essay {em}")

med = {(s, p): statistics.median(v) for s, d in sides.items() for p, v in d.items()}
print()
for lo, hi in itertools.combinations(sorted(sides), 2):
    for probe in ("code", "essay"):
        a, b = med.get((lo, probe)), med.get((hi, probe))
        if a and b and a > 0:
            d = (b - a) / a * 100
            note = ""
            if {lo, hi} in ({"A", "B"},) and probe == "code" and abs(d) < 15:
                note = "  (inside the <15% noise band — a tie)"
            print(f"{probe:6s}: {hi} vs {lo}  {b:.2f} vs {a:.2f} tok/s  {d:+.1f}%  ({b/a:.2f}x){note}")

spec = "B" if "B" in sides else ("A" if "A" in sides else None)
if spec and "M" in sides:
    print(f"\nDFlash2 ({spec}) over MTP (M), same session:")
    for probe in ("code", "essay"):
        a, b = med.get(("M", probe)), med.get((spec, probe))
        if a and b:
            print(f"  {probe:6s} {b/a:.2f}x  ({b:.2f} vs {a:.2f} tok/s)")

print("\nessay is the discriminator (~1% within a boot); code <15% is noise.")
print("Boot-to-boot drift on this box reached 6.5% on 2026-09-05 — compare within a session only.")
PY

echo
echo "artifacts: ${OUT}"
