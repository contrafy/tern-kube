# tern-kube shell guard for bash (opt-in). Add to ~/.bashrc:
#   source /path/to/tern-kube/shell/tern-kube.bash
# Defines `kubectl` (mutating verbs ask for approval in Tern), a
# PROMPT_COMMAND hook recording this pane's KUBECONFIG for tern-kube quick
# actions, `tern-kube-guard-status` and `tern-kube-guard-uninstall`. See
# shell/README.md.

if [[ -z ${_tern_kube_guard_installed-} ]] && { alias kubectl >/dev/null 2>&1 || declare -F kubectl >/dev/null; }; then
	printf 'tern-kube guard: not installed: kubectl is already defined as %s in this shell.\n' "$(type -t kubectl)" >&2
	printf 'tern-kube guard: your definition was left untouched. To use the guard, remove it (or rename it, e.g. to k) before sourcing %s.\n' "${BASH_SOURCE[0]}" >&2
	return 1
fi

_tern_kube_guard_core=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tern-kube-guard
_tern_kube_guard_installed=1

kubectl() {
	if [[ ! -x $_tern_kube_guard_core ]]; then
		printf 'tern-kube guard: the guard core %s is missing, so kubectl was not run.\n' "$_tern_kube_guard_core" >&2
		printf 'tern-kube guard: restore it, run tern-kube-guard-uninstall, or bypass the guard (no preview, no confirmation) with: command kubectl ...\n' >&2
		return 127
	fi
	"$_tern_kube_guard_core" kubectl "$@"
}

_tern_kube_pane_env() {
	[[ -n ${TERN_PANE-} && -n ${TKUBE_SPOOL-} && -d $TKUBE_SPOOL ]] || return 0
	local file=$TKUBE_SPOOL/pane-$TERN_PANE.env
	local key=$file$'\n'${KUBECONFIG-}
	[[ $key == "${_tern_kube_pane_env_last-}" ]] && return 0
	[[ ${KUBECONFIG-} == *$'\n'* ]] && return 0
	command sh -c 'umask 077; t=$2.tmp.$$; printf "kubeconfig=%s\n" "$1" >"$t" && mv -f "$t" "$2" || { rm -f "$t"; exit 1; }' \
		tern-kube-pane-env "${KUBECONFIG-}" "$file" 2>/dev/null && _tern_kube_pane_env_last=$key
	return 0
}

# Appended, never replacing the user's PROMPT_COMMAND (array form on bash 5.1+).
_tern_kube_pc_array() {
	[[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]] &&
		((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1)))
}

if _tern_kube_pc_array; then
	case " ${PROMPT_COMMAND[*]} " in
	*' _tern_kube_pane_env '*) ;;
	*) PROMPT_COMMAND+=(_tern_kube_pane_env) ;;
	esac
else
	case $'\n'${PROMPT_COMMAND-}$'\n' in
	*$'\n'_tern_kube_pane_env$'\n'*) ;;
	*) PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}_tern_kube_pane_env ;;
	esac
fi

tern-kube-guard-status() {
	if [[ $(declare -f kubectl 2>/dev/null) == *_tern_kube_guard_core* ]]; then
		echo "kubectl function: tern-kube guard (bash)"
	else
		echo "kubectl function: not the tern-kube guard ($(type -t kubectl))"
	fi
	if [[ $'\n'${PROMPT_COMMAND[*]-}$'\n' == *_tern_kube_pane_env* ]]; then
		echo "pane env hook: installed (PROMPT_COMMAND)"
	else
		echo "pane env hook: not installed"
	fi
	if [[ -x $_tern_kube_guard_core ]]; then
		"$_tern_kube_guard_core" status
	else
		echo "tern-kube guard core: MISSING at $_tern_kube_guard_core (kubectl is refused)"
		return 1
	fi
}

tern-kube-guard-uninstall() {
	local i pc
	if _tern_kube_pc_array; then
		pc=("${PROMPT_COMMAND[@]}")
		PROMPT_COMMAND=()
		for i in "${pc[@]}"; do
			[[ $i == _tern_kube_pane_env ]] || PROMPT_COMMAND+=("$i")
		done
	else
		pc=$'\n'${PROMPT_COMMAND-}$'\n'
		pc=${pc//$'\n'_tern_kube_pane_env$'\n'/$'\n'}
		pc=${pc#$'\n'}
		PROMPT_COMMAND=${pc%$'\n'}
	fi
	[[ $(declare -f kubectl 2>/dev/null) == *_tern_kube_guard_core* ]] && unset -f kubectl
	unset -f _tern_kube_pane_env _tern_kube_pc_array tern-kube-guard-status tern-kube-guard-uninstall
	unset _tern_kube_guard_core _tern_kube_guard_installed _tern_kube_pane_env_last
	echo "tern-kube guard removed from this shell; also delete the 'source .../tern-kube.bash' line from your ~/.bashrc."
}
