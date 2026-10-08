# tern-kube shell guard for fish (opt-in). Add to ~/.config/fish/config.fish:
#   source /path/to/tern-kube/shell/tern-kube.fish
# Defines `kubectl` (mutating verbs ask for approval in Tern), a fish_prompt
# handler recording this pane's KUBECONFIG for tern-kube quick actions,
# `tern-kube-guard-status` and `tern-kube-guard-uninstall`. See shell/README.md.

if not set -q _tern_kube_guard_installed
    and begin
        functions -q kubectl
        or abbr -q kubectl
    end
    printf 'tern-kube guard: not installed: kubectl is already defined as a function, alias or abbreviation in this shell.\n' >&2
    printf 'tern-kube guard: your definition was left untouched. To use the guard, remove it (or rename it, e.g. to k) before sourcing %s.\n' (status filename) >&2
    return 1
end

set -g _tern_kube_guard_core (builtin realpath (status dirname))/tern-kube-guard
set -g _tern_kube_guard_installed 1

function kubectl --description 'kubectl through the tern-kube guard'
    if not test -x "$_tern_kube_guard_core"
        printf 'tern-kube guard: the guard core %s is missing, so kubectl was not run.\n' "$_tern_kube_guard_core" >&2
        printf 'tern-kube guard: restore it, run tern-kube-guard-uninstall, or bypass the guard (no preview, no confirmation) with: command kubectl ...\n' >&2
        return 127
    end
    $_tern_kube_guard_core kubectl $argv
end

function _tern_kube_pane_env --on-event fish_prompt
    test -n "$TERN_PANE" -a -n "$TKUBE_SPOOL"; and test -d "$TKUBE_SPOOL"; or return 0
    set -l file "$TKUBE_SPOOL/pane-$TERN_PANE.env"
    set -l kc "$KUBECONFIG"
    set -l key "$file"\n"$kc"
    test "$key" = "$_tern_kube_pane_env_last"; and return 0
    string match -q -- "*"\n"*" "$kc"; and return 0
    command sh -c 'umask 077; t=$2.tmp.$$; printf "kubeconfig=%s\n" "$1" >"$t" && mv -f "$t" "$2" || { rm -f "$t"; exit 1; }' \
        tern-kube-pane-env "$kc" "$file" 2>/dev/null
    and set -g _tern_kube_pane_env_last "$key"
    return 0
end

function tern-kube-guard-status --description 'show what the tern-kube guard does in this shell'
    if string match -q -- '*_tern_kube_guard_core*' (functions kubectl 2>/dev/null)
        echo "kubectl function: tern-kube guard (fish)"
    else
        echo "kubectl function: not the tern-kube guard"
    end
    if functions -q _tern_kube_pane_env
        echo "pane env hook: installed (fish_prompt event)"
    else
        echo "pane env hook: not installed"
    end
    if test -x "$_tern_kube_guard_core"
        $_tern_kube_guard_core status
    else
        echo "tern-kube guard core: MISSING at $_tern_kube_guard_core (kubectl is refused)"
        return 1
    end
end

function tern-kube-guard-uninstall --description 'remove the tern-kube guard from this shell'
    if string match -q -- '*_tern_kube_guard_core*' (functions kubectl 2>/dev/null)
        functions -e kubectl
    end
    functions -e _tern_kube_pane_env tern-kube-guard-status
    set -e _tern_kube_guard_core
    set -e _tern_kube_guard_installed
    set -e _tern_kube_pane_env_last
    echo "tern-kube guard removed from this shell; also delete the 'source .../tern-kube.fish' line from your config.fish."
    functions -e tern-kube-guard-uninstall
end
