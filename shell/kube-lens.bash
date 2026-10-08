# kube-lens shell guard for bash (opt-in). Add to ~/.bashrc:
#   source /path/to/tern-kube-lens/shell/kube-lens.bash
# Defines `kubectl` (mutating verbs ask for approval in Tern), a
# PROMPT_COMMAND hook recording this pane's KUBECONFIG for kube-lens quick
# actions, `kube-lens-guard-status` and `kube-lens-guard-uninstall`. See
# shell/README.md.

if [[ -z ${_kube_lens_guard_installed-} ]] && { alias kubectl >/dev/null 2>&1 || declare -F kubectl >/dev/null; }; then
	printf 'kube-lens guard: not installed: kubectl is already defined as %s in this shell.\n' "$(type -t kubectl)" >&2
	printf 'kube-lens guard: your definition was left untouched. To use the guard, remove it (or rename it, e.g. to k) before sourcing %s.\n' "${BASH_SOURCE[0]}" >&2
	return 1
fi

_kube_lens_guard_core=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/kube-lens-guard
_kube_lens_guard_installed=1

kubectl() {
	if [[ ! -x $_kube_lens_guard_core ]]; then
		printf 'kube-lens guard: the guard core %s is missing, so kubectl was not run.\n' "$_kube_lens_guard_core" >&2
		printf 'kube-lens guard: restore it, run kube-lens-guard-uninstall, or bypass the guard (no preview, no confirmation) with: command kubectl ...\n' >&2
		return 127
	fi
	"$_kube_lens_guard_core" kubectl "$@"
}

_kube_lens_pane_env() {
	[[ -n ${TERN_PANE-} && -n ${KUBE_LENS_SPOOL-} && -d $KUBE_LENS_SPOOL ]] || return 0
	local file=$KUBE_LENS_SPOOL/pane-$TERN_PANE.env
	local key=$file$'\n'${KUBECONFIG-}
	[[ $key == "${_kube_lens_pane_env_last-}" ]] && return 0
	[[ ${KUBECONFIG-} == *$'\n'* ]] && return 0
	command sh -c 'umask 077; t=$2.tmp.$$; printf "kubeconfig=%s\n" "$1" >"$t" && mv -f "$t" "$2" || { rm -f "$t"; exit 1; }' \
		kube-lens-pane-env "${KUBECONFIG-}" "$file" 2>/dev/null && _kube_lens_pane_env_last=$key
	return 0
}

# Appended, never replacing the user's PROMPT_COMMAND (array form on bash 5.1+).
_kube_lens_pc_array() {
	[[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]] &&
		((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1)))
}

if _kube_lens_pc_array; then
	case " ${PROMPT_COMMAND[*]} " in
	*' _kube_lens_pane_env '*) ;;
	*) PROMPT_COMMAND+=(_kube_lens_pane_env) ;;
	esac
else
	case $'\n'${PROMPT_COMMAND-}$'\n' in
	*$'\n'_kube_lens_pane_env$'\n'*) ;;
	*) PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}_kube_lens_pane_env ;;
	esac
fi

kube-lens-guard-status() {
	if [[ $(declare -f kubectl 2>/dev/null) == *_kube_lens_guard_core* ]]; then
		echo "kubectl function: kube-lens guard (bash)"
	else
		echo "kubectl function: not the kube-lens guard ($(type -t kubectl))"
	fi
	if [[ $'\n'${PROMPT_COMMAND[*]-}$'\n' == *_kube_lens_pane_env* ]]; then
		echo "pane env hook: installed (PROMPT_COMMAND)"
	else
		echo "pane env hook: not installed"
	fi
	if [[ -x $_kube_lens_guard_core ]]; then
		"$_kube_lens_guard_core" status
	else
		echo "kube-lens guard core: MISSING at $_kube_lens_guard_core (kubectl is refused)"
		return 1
	fi
}

kube-lens-guard-uninstall() {
	local i pc
	if _kube_lens_pc_array; then
		pc=("${PROMPT_COMMAND[@]}")
		PROMPT_COMMAND=()
		for i in "${pc[@]}"; do
			[[ $i == _kube_lens_pane_env ]] || PROMPT_COMMAND+=("$i")
		done
	else
		pc=$'\n'${PROMPT_COMMAND-}$'\n'
		pc=${pc//$'\n'_kube_lens_pane_env$'\n'/$'\n'}
		pc=${pc#$'\n'}
		PROMPT_COMMAND=${pc%$'\n'}
	fi
	[[ $(declare -f kubectl 2>/dev/null) == *_kube_lens_guard_core* ]] && unset -f kubectl
	unset -f _kube_lens_pane_env _kube_lens_pc_array kube-lens-guard-status kube-lens-guard-uninstall
	unset _kube_lens_guard_core _kube_lens_guard_installed _kube_lens_pane_env_last
	echo "kube-lens guard removed from this shell; also delete the 'source .../kube-lens.bash' line from your ~/.bashrc."
}
