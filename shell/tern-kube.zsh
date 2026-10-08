# tern-kube shell guard for zsh (opt-in). Add to ~/.zshrc:
#   source /path/to/tern-kube/shell/tern-kube.zsh
# Defines `kubectl` (mutating verbs ask for approval in Tern), a precmd hook
# recording this pane's KUBECONFIG for tern-kube quick actions,
# `tern-kube-guard-status` and `tern-kube-guard-uninstall`. See shell/README.md.

if (( ! ${+_tern_kube_guard_installed} )) && { (( ${+aliases[kubectl]} )) || (( ${+functions[kubectl]} )); }; then
	print -u2 -r -- "tern-kube guard: not installed: kubectl is already defined as $(whence -w kubectl | sed 's/^kubectl: //') in this shell."
	print -u2 -r -- "tern-kube guard: your definition was left untouched. To use the guard, remove it (or rename it, e.g. to k) before sourcing $(print -r -- ${(%):-%x})."
	return 1
fi

typeset -g _tern_kube_guard_core=${${(%):-%x}:A:h}/tern-kube-guard
typeset -g _tern_kube_guard_installed=1

kubectl() {
	if [[ ! -x $_tern_kube_guard_core ]]; then
		print -u2 -r -- "tern-kube guard: the guard core $_tern_kube_guard_core is missing, so kubectl was not run."
		print -u2 -r -- "tern-kube guard: restore it, run tern-kube-guard-uninstall, or bypass the guard (no preview, no confirmation) with: command kubectl ..."
		return 127
	fi
	"$_tern_kube_guard_core" kubectl "$@"
}

_tern_kube_pane_env() {
	[[ -n ${TERN_PANE-} && -n ${TKUBE_SPOOL-} && -d $TKUBE_SPOOL ]] || return 0
	local file=$TKUBE_SPOOL/pane-$TERN_PANE.env
	local key=$file$'\n'${KUBECONFIG-}
	[[ $key == ${_tern_kube_pane_env_last-} ]] && return 0
	[[ ${KUBECONFIG-} == *$'\n'* ]] && return 0
	command sh -c 'umask 077; t=$2.tmp.$$; printf "kubeconfig=%s\n" "$1" >"$t" && mv -f "$t" "$2" || { rm -f "$t"; exit 1; }' \
		tern-kube-pane-env "${KUBECONFIG-}" "$file" 2>/dev/null && typeset -g _tern_kube_pane_env_last=$key
	return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _tern_kube_pane_env

tern-kube-guard-status() {
	if [[ ${functions[kubectl]-} == *_tern_kube_guard_core* ]]; then
		print -r -- "kubectl function: tern-kube guard (zsh)"
	else
		print -r -- "kubectl function: not the tern-kube guard ($(whence -w kubectl))"
	fi
	if (( ${precmd_functions[(Ie)_tern_kube_pane_env]} )); then
		print -r -- "pane env hook: installed (precmd)"
	else
		print -r -- "pane env hook: not installed"
	fi
	if [[ -x $_tern_kube_guard_core ]]; then
		"$_tern_kube_guard_core" status
	else
		print -r -- "tern-kube guard core: MISSING at $_tern_kube_guard_core (kubectl is refused)"
		return 1
	fi
}

tern-kube-guard-uninstall() {
	add-zsh-hook -d precmd _tern_kube_pane_env
	[[ ${functions[kubectl]-} == *_tern_kube_guard_core* ]] && unfunction kubectl
	unfunction _tern_kube_pane_env tern-kube-guard-status tern-kube-guard-uninstall
	unset _tern_kube_guard_core _tern_kube_guard_installed _tern_kube_pane_env_last
	print -r -- "tern-kube guard removed from this shell; also delete the 'source .../tern-kube.zsh' line from your ~/.zshrc."
}
