#!/usr/bin/env bash
# 本地构建 AuthCore workspace 中带二进制可执行文件的 crate，并 scp 到远程 /mnt/huiwing/<crate>/
# 含: htyuc, certutil, upyun_tool（htycommons/htyuc_models/htyuc_remote 为库，无单独 deploy）
#
# certutil / upyun_tool 为 CLI，仅上传可执行文件，无 start.sh
#
# 用法与 huiwing/scripts/build_and_deploy_huiwing.sh 相同（见该文件）
#
# .env: 查找顺序（命中即用；开源仓库可只提交 <crate>.env.sample）:
#   1) $AUTHCORE_ENV_ROOT/<profile>/<crate>.env 然后 <crate>.env.sample
#   2) AuthCore/envs/<profile>/ 同上
#   3) ../huiwing/envs/<profile>/ 同上（与 cp_envs_*.sh 同源）
#
# 环境变量: CARGO_TARGET, DRY_RUN=1, SKIP_BUILD=1, ENV_PROFILE, SKIP_ENV=1, AUTHCORE_ENV_ROOT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ALL_CRATES=(htyuc certutil upyun_tool)

resolve_alias_ssh() {
  case "$1" in
    alchemy) echo "weli@alchemy-studio.cn" ;;
    moicen) echo "weli@moicen.com" ;;
    *) return 1 ;;
  esac
}

resolve_env_profile() {
  local host_arg="$1"
  local h="$host_arg"
  if [[ "$h" =~ ^(.+@[^:]+):(/.*)$ ]]; then
    h="${BASH_REMATCH[1]}"
  fi
  case "$host_arg" in
    alchemy) echo "alchemy"; return ;;
    moicen) echo "moicen"; return ;;
  esac
  case "$h" in
    *alchemy-studio.cn) echo "alchemy" ;;
    *moicen.com) echo "moicen" ;;
    *)
      if [[ -n "${ENV_PROFILE:-}" ]]; then
        echo "${ENV_PROFILE}"
      fi
      ;;
  esac
}

# 打印第一个存在的 env 文件路径（优先 <crate>.env，其次 <crate>.env.sample），否则空
resolve_env_file() {
  local profile="$1"
  local crate="$2"
  local f
  if [[ -n "${AUTHCORE_ENV_ROOT:-}" ]]; then
    f="${AUTHCORE_ENV_ROOT}/${profile}/${crate}.env"
    [[ -f "$f" ]] && { echo "$f"; return; }
    f="${AUTHCORE_ENV_ROOT}/${profile}/${crate}.env.sample"
    [[ -f "$f" ]] && { echo "$f"; return; }
  fi
  f="${ROOT}/envs/${profile}/${crate}.env"
  [[ -f "$f" ]] && { echo "$f"; return; }
  f="${ROOT}/envs/${profile}/${crate}.env.sample"
  [[ -f "$f" ]] && { echo "$f"; return; }
  f="${ROOT}/../huiwing/envs/${profile}/${crate}.env"
  [[ -f "$f" ]] && { echo "$f"; return; }
  f="${ROOT}/../huiwing/envs/${profile}/${crate}.env.sample"
  [[ -f "$f" ]] && { echo "$f"; return; }
  echo ""
}

is_crate() {
  local c="$1"
  local x
  for x in "${ALL_CRATES[@]}"; do
    if [[ "$x" == "$c" ]]; then return 0; fi
  done
  return 1
}

dry_run() {
  if [[ "${DRY_RUN:-}" == "1" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

resolve_binary() {
  local crate="$1"
  if [[ -n "${CARGO_TARGET:-}" ]]; then
    echo "${ROOT}/target/${CARGO_TARGET}/release/${crate}"
  else
    echo "${ROOT}/target/release/${crate}"
  fi
}

parse_target() {
  local host_arg="$1"
  local default_rdir="$2"
  local ssh_host rdir
  if [[ "$host_arg" =~ ^(.+@[^:]+):(/.*)$ ]]; then
    ssh_host="${BASH_REMATCH[1]}"
    rdir="${BASH_REMATCH[2]}"
  elif ssh_host="$(resolve_alias_ssh "$host_arg" 2>/dev/null)"; then
    rdir="${default_rdir}"
  elif [[ "$host_arg" == *@* ]]; then
    ssh_host="$host_arg"
    rdir="${default_rdir}"
  else
    echo "unknown: ${host_arg}" >&2
    exit 1
  fi
  echo "${ssh_host}"
  echo "${rdir}"
}

build_release() {
  if [[ "${SKIP_BUILD:-}" == "1" ]]; then
    return 0
  fi
  cd "${ROOT}"
  local args=()
  for c in "${CRATES[@]}"; do
    args+=(-p "$c")
  done
  if [[ -n "${CARGO_TARGET:-}" ]]; then
    dry_run cargo build --release "${args[@]}" --target "${CARGO_TARGET}"
  else
    dry_run cargo build --release "${args[@]}"
  fi
}

deploy_one() {
  local host_arg="$1"
  local crate="$2"
  local default_rdir="/mnt/huiwing/${crate}"
  local bin_path start_sh ssh_host rdir
  bin_path="$(resolve_binary "$crate")"
  start_sh="${ROOT}/${crate}/start.sh"

  if [[ ! -f "${bin_path}" ]]; then
    echo "missing binary: ${bin_path}" >&2
    exit 1
  fi

  IFS=$'\n' read -r ssh_host rdir < <(parse_target "$host_arg" "$default_rdir")

  echo "==> ${crate} -> ${ssh_host}:${rdir}"
  dry_run ssh "${ssh_host}" "mkdir -p '${rdir}'"
  dry_run scp -C "${bin_path}" "${ssh_host}:${rdir}/${crate}.new"
  if [[ -f "${start_sh}" ]]; then
    dry_run scp -C "${start_sh}" "${ssh_host}:${rdir}/start.sh.new"
  fi

  local profile env_local
  profile="$(resolve_env_profile "$host_arg")"
  env_local=""
  if [[ -n "${profile}" ]]; then
    env_local="$(resolve_env_file "$profile" "$crate")"
  fi
  if [[ "${SKIP_ENV:-}" == "1" ]]; then
    :
  elif [[ -z "${profile}" ]]; then
    echo "    warn: cannot resolve env profile for host '${host_arg}' (set ENV_PROFILE or SKIP_ENV=1)" >&2
  elif [[ -n "${env_local}" ]]; then
    dry_run scp -C "${env_local}" "${ssh_host}:${rdir}/.env.new"
    dry_run ssh "${ssh_host}" "mv -f '${rdir}/.env.new' '${rdir}/.env'"
    echo "    .env <- ${env_local}"
  else
    echo "    warn: no ${crate}.env or ${crate}.env.sample for profile ${profile}" >&2
  fi

  if [[ -f "${start_sh}" ]]; then
    dry_run ssh "${ssh_host}" "mv -f '${rdir}/${crate}.new' '${rdir}/${crate}' && mv -f '${rdir}/start.sh.new' '${rdir}/start.sh' && chmod +x '${rdir}/${crate}' '${rdir}/start.sh'"
  else
    dry_run ssh "${ssh_host}" "mv -f '${rdir}/${crate}.new' '${rdir}/${crate}' && chmod +x '${rdir}/${crate}'"
  fi
  echo "    ok ${rdir}/${crate}"
}

parse_cli_args() {
  HOST_ARGS=()
  CRATES=()
  local arg
  for arg in "$@"; do
    if is_crate "$arg"; then
      CRATES+=("$arg")
    elif [[ "$arg" == *@* ]] || resolve_alias_ssh "$arg" &>/dev/null; then
      HOST_ARGS+=("$arg")
    else
      echo "unknown arg: ${arg} (expect alchemy|moicen|user@host or ${ALL_CRATES[*]})" >&2
      exit 1
    fi
  done
  if [[ ${#HOST_ARGS[@]} -eq 0 ]]; then
    HOST_ARGS=(alchemy moicen)
  fi
  if [[ ${#CRATES[@]} -eq 0 ]]; then
    CRATES=("${ALL_CRATES[@]}")
  fi
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "AuthCore binaries: ${ALL_CRATES[*]}"
    echo "htyuc 有 start.sh；certutil、upyun_tool 仅二进制"
    echo ".env: ENV_PROFILE / host; file from AUTHCORE_ENV_ROOT, AuthCore/envs, or ../huiwing/envs"
    exit 0
  fi

  parse_cli_args "$@"
  build_release

  local h c
  for h in "${HOST_ARGS[@]}"; do
    for c in "${CRATES[@]}"; do
      deploy_one "$h" "$c"
    done
  done
}

main "$@"
