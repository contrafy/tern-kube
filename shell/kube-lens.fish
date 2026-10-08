# kube-lens shell guard for fish (opt-in). Add to ~/.config/fish/config.fish:
#   source /path/to/tern-kube-lens/shell/kube-lens.fish
# Defines `kubectl` (mutating verbs ask for approval in Tern), a fish_prompt
# handler recording this pane's KUBECONFIG for kube-lens quick actions,
# `kube-lens-guard-status` and `kube-lens-guard-uninstall`. See shell/README.md.

if not set -q _kube_lens_guard_installed
    and begin
        functions -q kubectl
        or abbr -q kubectl
    end
    printf 'kube-lens guard: not installed: kubectl is already defined as a function, alias or abbreviation in this shell.\n' >&2
    printf 'kube-lens guard: your definition was left untouched. To use the guard, remove it (or rename it, e.g. to k) before sourcing %s.\n' (status filename) >&2
    return 1
end

set -g _kube_lens_guard_core (builtin realpath (status dirname))/kube-lens-guard
set -g _kube_lens_guard_installed 1

function kubectl --description 'kubectl through the kube-lens guard'
    if not test -x "$_kube_lens_guard_core"
        printf 'kube-lens guard: the guard core %s is missing, so kubectl was not run.\n' "$_kube_lens_guard_core" >&2
        printf 'kube-lens guard: restore it, run kube-lens-guard-uninstall, or bypass the guard (no preview, no confirmation) with: command kubectl ...\n' >&2
        return 127
    end
    $_kube_lens_guard_core kubectl $argv
end

function _kube_lens_pane_env --on-event fish_prompt
    test -n "$TERN_PANE" -a -n "$KUBE_LENS_SPOOL"; and test -d "$KUBE_LENS_SPOOL"; or return 0
    set -l file "$KUBE_LENS_SPOOL/pane-$TERN_PANE.env"
    set -l kc "$KUBECONFIG"
    set -l key "$file"\n"$kc"
    test "$key" = "$_kube_lens_pane_env_last"; and return 0
    string match -q -- "*"\n"*" "$kc"; and return 0
    command sh -c 'umask 077; t=$2.tmp.$$; printf "kubeconfig=%s\n" "$1" >"$t" && mv -f "$t" "$2" || { rm -f "$t"; exit 1; }' \
        kube-lens-pane-env "$kc" "$file" 2>/dev/null
    and set -g _kube_lens_pane_env_last "$key"
    return 0
end

function kube-lens-guard-status --description 'show what the kube-lens guard does in this shell'
    if string match -q -- '*_kube_lens_guard_core*' (functions kubectl 2>/dev/null)
        echo "kubectl function: kube-lens guard (fish)"
    else
        echo "kubectl function: not the kube-lens guard"
    end
    if functions -q _kube_lens_pane_env
        echo "pane env hook: installed (fish_prompt event)"
    else
        echo "pane env hook: not installed"
    end
    if test -x "$_kube_lens_guard_core"
        $_kube_lens_guard_core status
    else
        echo "kube-lens guard core: MISSING at $_kube_lens_guard_core (kubectl is refused)"
        return 1
    end
end

function kube-lens-guard-uninstall --description 'remove the kube-lens guard from this shell'
    if string match -q -- '*_kube_lens_guard_core*' (functions kubectl 2>/dev/null)
        functions -e kubectl
    end
    functions -e _kube_lens_pane_env kube-lens-guard-status
    set -e _kube_lens_guard_core
    set -e _kube_lens_guard_installed
    set -e _kube_lens_pane_env_last
    echo "kube-lens guard removed from this shell; also delete the 'source .../kube-lens.fish' line from your config.fish."
    functions -e kube-lens-guard-uninstall
end
