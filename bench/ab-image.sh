#!/usr/bin/env bash
set -euo pipefail

# A/B the DFlash2 *serving image* on this box, in one session:
#   side A = main's self-built  lmsysorg/sglang:qwen38-27b-dflash2
#   side B = the official pinned lmsysorg/sglang@sha256:616a3e97… (script default)
#
# IMAGE is the only variable. From DF_TARGET through `exec`, start-dflash.sh is
# byte-identical on main (751e29e) and on this branch, so both sides run the same
# flag stack, the same NVFP4 BF16-head checkpoint and the same pinned draft.
#
# Why one session: this box drifts (essay 19.5 -> 18 tok/s over ~an hour of heavy
# benching — power cap), so cross-day numbers are indicative at best. Within a
# boot the essay probe is stable to ~1% and is the discriminator; treat code
# deltas <15% as noise (README, "Measured on this box").
#
#   ./bench/ab-image.sh                  # A,B            (~20 min)
#   SEQ="A B B A" ./bench/ab-image.sh    # ABBA, cancels linear drift (~40 min)
#   RUNS=5 ./bench/ab-image.sh           # 5 ndec runs per boot instead of 3
#   DRY_RUN=1 ./bench/ab-image.sh        # print the plan, boot nothing
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
CONTAINER_NAME="qwen3.8-27b-sglang"
RUNS="${RUNS:-3}"
SEQ="${SEQ:-A B}"
DRY_RUN="${DRY_RUN:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT}/bench/_ab-image-${STAMP}"

for f in start-dflash.sh stop.sh bench/ndec.py; do
  [[ -f "${ROOT}/${f}" ]] || { echo "run this from the repo (missing ${f})"; exit 1; }
done
command -v docker >/dev/null 2>&1 || { echo "docker is not on PATH"; exit 1; }

side_label() {
  case "$1" in
    A) echo "A:self-built (main)" ;;
    B) echo "B:official (pinned)" ;;
    *) echo "unknown side '$1' in SEQ (use A and B only)"; exit 1 ;;
  esac
}

# --- preflight -------------------------------------------------------------
echo "=== preflight ==="
if [[ " ${SEQ} " == *" A "* ]]; then
  docker image inspect "${LEGACY_IMAGE}" >/dev/null 2>&1 || {
    echo "side A needs ${LEGACY_IMAGE} on disk and it is not here."
    echo "Rebuild it in a scratch worktree (see the header of this script), or run SEQ=\"B\" for side B only."
    exit 1
  }
  echo "side A image: ${LEGACY_IMAGE} ($(docker image inspect -f '{{.Id}}' "${LEGACY_IMAGE}" | cut -c8-19))"
fi
# ./stop.sh only stops qwen3.8-27b-sglang and qwen3.8-27b-sglang-mtp. Anything
# else holding the GPU or port 8888 has to go before this A/B means anything.
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "our container ${CONTAINER_NAME} is up; ./stop.sh will stop it between sides:"
  docker ps --filter "name=^${CONTAINER_NAME}$" --format '  {{.Names}}\t{{.Image}}' || true
fi
others="$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -v "^${CONTAINER_NAME}\b" || true)"
if [[ -n "${others}" ]]; then
  echo "other containers are running — ./stop.sh does NOT touch these, stop them yourself"
  echo "if they hold the GPU, unified memory or port 8888:"
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
echo "plan: SEQ='${SEQ}', ${RUNS} ndec run(s) per boot, artifacts -> ${OUT}"

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
  # $1 = side, $2 = tag used for artifact filenames
  local side="$1" tag="$2"
  local log="${OUT}/${tag}.sglang.log"
  local ok=1
  cp -f .sglang.log "${log}" 2>/dev/null || { echo "  no .sglang.log to verify"; return 1; }

  local ran_image
  ran_image="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo '?')"
  echo "  container image: ${ran_image}"
  echo "${ran_image}" > "${OUT}/${tag}.image"

  grep -q "speculative_algorithm='DFLASH'" "${log}" || { echo "  MISSING: speculative_algorithm='DFLASH'"; ok=0; }
  grep -q "Initialized DFLASH draft runner" "${log}" || echo "  note: 'Initialized DFLASH draft runner' not in log"
  if grep -q "folded into the draft cuda graph" "${log}"; then
    echo "  selector: folded into the draft cuda graph"
  elif grep -qE "kept eager \(reason=|unsupported quantized lm_head" "${log}"; then
    echo "  WARNING: selector kept eager — not the expected path on this image"
  fi
  grep -oE "speculative_draft_model_path='[^']+'|speculative_num_draft_tokens=[0-9]+|max_running_requests=[0-9]+|max_mamba_cache_size=[0-9]+|mem_fraction_static=[0-9.]+|model_path='[^']+'" "${log}" \
    | sort -u | sed 's/^/  /' | tee "${OUT}/${tag}.stack"
  [[ ${ok} -eq 1 ]]
}

run_side() {
  # $1 = side (A|B), $2 = position index
  local side="$1" pos="$2" tag
  tag="$(printf '%02d-%s' "${pos}" "${side}")"
  echo
  echo "=== ${tag} — $(side_label "${side}") ==="

  stop_all
  grep -E 'MemAvailable' /proc/meminfo 2>/dev/null | sed 's/^/  /' || true
  local t_boot; t_boot="$(date -Is)"
  echo "${t_boot}" > "${OUT}/${tag}.started"

  echo "  booting ..."
  if [[ "${side}" == "A" ]]; then
    IMAGE="${LEGACY_IMAGE}" ./start-dflash.sh > "${OUT}/${tag}.boot.log" 2>&1 \
      || { echo "  BOOT FAILED — tail of ${OUT}/${tag}.boot.log:"; tail -n 25 "${OUT}/${tag}.boot.log"; exit 1; }
  else
    ./start-dflash.sh > "${OUT}/${tag}.boot.log" 2>&1 \
      || { echo "  BOOT FAILED — tail of ${OUT}/${tag}.boot.log:"; tail -n 25 "${OUT}/${tag}.boot.log"; exit 1; }
  fi
  grep -q "SGLang is ready" "${OUT}/${tag}.boot.log" \
    || { echo "  server never reported ready; see ${OUT}/${tag}.boot.log"; exit 1; }

  verify_boot "${side}" "${tag}" || { echo "  boot verification failed for ${tag}"; exit 1; }

  local i
  for ((i = 1; i <= RUNS; i++)); do
    echo "  ndec run ${i}/${RUNS}"
    python3 bench/ndec.py 2>&1 | tee -a "${OUT}/${tag}.ndec" | sed 's/^/    /'
  done

  # earlyoom is what kills a too-high mem-fraction on DGX OS (exit code -15).
  journalctl -u earlyoom --since "${t_boot}" --no-pager 2>/dev/null | grep -i "kill\|sglang" \
    | tee "${OUT}/${tag}.earlyoom" | sed 's/^/  earlyoom: /' || true

  stop_all
}

# --- run -------------------------------------------------------------------
pos=0
for side in ${SEQ}; do
  pos=$((pos + 1))
  side_label "${side}" >/dev/null   # validates the letter
  run_side "${side}" "${pos}"
done

# --- summarise -------------------------------------------------------------
echo
echo "=== summary ==="
python3 - "${OUT}" <<'PY'
import glob, os, re, statistics, sys

out = sys.argv[1]
pat = re.compile(r"^(?P<name>.+?)\s+net decode =\s+(?P<tps>[\d.]+) tok/s")
sides = {}
for path in sorted(glob.glob(os.path.join(out, "*.ndec"))):
    side = os.path.basename(path).split("-")[1].split(".")[0]
    for line in open(path):
        m = pat.match(line.strip())
        if m:
            probe = "code" if m.group("name").startswith("code") else "essay"
            sides.setdefault(side, {}).setdefault(probe, []).append(float(m.group("tps")))

label = {"A": "A self-built (main)", "B": "B official (pinned)"}
rows = []
for side in sorted(sides):
    for probe in ("code", "essay"):
        v = sides[side].get(probe, [])
        if v:
            rows.append((side, probe, len(v), min(v), statistics.median(v), max(v)))

if not rows:
    print("no ndec results parsed — check the .ndec files in", out)
    sys.exit(0)

print(f"{'side':22s} {'probe':6s} {'n':>2s} {'min':>7s} {'median':>7s} {'max':>7s}")
for side, probe, n, lo, med, hi in rows:
    print(f"{label.get(side, side):22s} {probe:6s} {n:2d} {lo:7.2f} {med:7.2f} {hi:7.2f}")

med = {(s, p): statistics.median(v) for s, d in sides.items() for p, v in d.items()}
print()
for probe in ("code", "essay"):
    a, b = med.get(("A", probe)), med.get(("B", probe))
    if a and b:
        d = (b - a) / a * 100
        note = ""
        if probe == "code" and abs(d) < 15:
            note = "  (inside the <15% noise band — call it a tie)"
        print(f"{probe:6s}: official vs self-built  {b:.2f} vs {a:.2f} tok/s  = {d:+.1f}%{note}")
print()
print("essay is the discriminator (stable to ~1% within a boot); code <15% is noise.")
PY

echo
echo "artifacts: ${OUT}"
echo "  *.boot.log  launcher output      *.sglang.log server log"
echo "  *.stack     engine settings      *.ndec      raw bench output"
echo "  *.image     container image ref  *.earlyoom  earlyoom kills, if any"
