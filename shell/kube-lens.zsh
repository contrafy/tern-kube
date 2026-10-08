# kube-lens shell guard for zsh (opt-in). Add to ~/.zshrc:
#   source /path/to/tern-kube-lens/shell/kube-lens.zsh
# Defines `kubectl` (mutating verbs ask for approval in Tern), a precmd hook
# recording this pane's KUBECONFIG for kube-lens quick actions,
# `kube-lens-guard-status` and `kube-lens-guard-uninstall`. See shell/README.md.

if (( ! ${+_kube_lens_guard_installed} )) && { (( ${+aliases[kubectl]} )) || (( ${+functions[kubectl]} )); }; then
	print -u2 -r -- "kube-lens guard: not installed: kubectl is already defined as $(whence -w kubectl | sed 's/^kubectl: //') in this shell."
	print -u2 -r -- "kube-lens guard: your definition was left untouched. To use the guard, remove it (or rename it, e.g. to k) before sourcing $(print -r -- ${(%):-%x})."
	return 1
fi

typeset -g _kube_lens_guard_core=${${(%):-%x}:A:h}/kube-lens-guard
typeset -g _kube_lens_guard_installed=1

kubectl() {
	if [[ ! -x $_kube_lens_guard_core ]]; then
		print -u2 -r -- "kube-lens guard: the guard core $_kube_lens_guard_core is missing, so kubectl was not run."
		print -u2 -r -- "kube-lens guard: restore it, run kube-lens-guard-uninstall, or bypass the guard (no preview, no confirmation) with: command kubectl ..."
		return 127
	fi
	"$_kube_lens_guard_core" kubectl "$@"
}

_kube_lens_pane_env() {
	[[ -n ${TERN_PANE-} && -n ${KUBE_LENS_SPOOL-} && -d $KUBE_LENS_SPOOL ]] || return 0
	local file=$KUBE_LENS_SPOOL/pane-$TERN_PANE.env
	local key=$file$'\n'${KUBECONFIG-}
	[[ $key == ${_kube_lens_pane_env_last-} ]] && return 0
	[[ ${KUBECONFIG-} == *$'\n'* ]] && return 0
	command sh -c 'umask 077; t=$2.tmp.$$; printf "kubeconfig=%s\n" "$1" >"$t" && mv -f "$t" "$2" || { rm -f "$t"; exit 1; }' \
		kube-lens-pane-env "${KUBECONFIG-}" "$file" 2>/dev/null && typeset -g _kube_lens_pane_env_last=$key
	return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _kube_lens_pane_env

kube-lens-guard-status() {
	if [[ ${functions[kubectl]-} == *_kube_lens_guard_core* ]]; then
		print -r -- "kubectl function: kube-lens guard (zsh)"
	else
		print -r -- "kubectl function: not the kube-lens guard ($(whence -w kubectl))"
	fi
	if (( ${precmd_functions[(Ie)_kube_lens_pane_env]} )); then
		print -r -- "pane env hook: installed (precmd)"
	else
		print -r -- "pane env hook: not installed"
	fi
	if [[ -x $_kube_lens_guard_core ]]; then
		"$_kube_lens_guard_core" status
	else
		print -r -- "kube-lens guard core: MISSING at $_kube_lens_guard_core (kubectl is refused)"
		return 1
	fi
}

kube-lens-guard-uninstall() {
	add-zsh-hook -d precmd _kube_lens_pane_env
	[[ ${functions[kubectl]-} == *_kube_lens_guard_core* ]] && unfunction kubectl
	unfunction _kube_lens_pane_env kube-lens-guard-status kube-lens-guard-uninstall
	unset _kube_lens_guard_core _kube_lens_guard_installed _kube_lens_pane_env_last
	print -r -- "kube-lens guard removed from this shell; also delete the 'source .../kube-lens.zsh' line from your ~/.zshrc."
}
