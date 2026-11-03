#!/bin/sh
# Login-shell coverage for what Tern runs in a pane's login shell: the PATH
# probe (Shellenv.probeArgv, read back with Shellenv.parseProbe), the quick
# action split line (Quick.command) and the fish guard snippet. Tern panes are
# login shells, and on remote hosts fish is a common login shell; each shell
# here gets a temp HOME whose rc files add PATH and KUBECONFIG the way users
# do, so a probe that skipped a file, or a line a shell re-parses, fails.
# The strings come from tests/shell/login/build.luau, i.e. the plugin itself.
#
#   sh tests/shell/login/run.sh      (or: make test-shell-login)
# Set SHELLS="fish bash" to choose the shells (default: sh dash bash zsh fish).

set -u

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd -P)
here=$repo/tests/shell/login
luau=${LUAU:-$repo/.tools/bin/luau}
case $luau in
/*) ;;
*) luau=$PWD/$luau ;;
esac
[ -x "$luau" ] || {
	echo "missing $luau: run 'make bootstrap'" >&2
	exit 2
}

root=$(mktemp -d "${TMPDIR:-/tmp}/tk-login.XXXXXX") || exit 2
root=$(cd -P -- "$root" && pwd -P)
trap 'rm -rf "$root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A dir with a space, added only by rc files; it holds the fake kubectl, so
# the quick-action line also proves the login PATH reached the split.
rcbin="$root/rc bin"
kc_env="$root/kc one:$root/kc two"
ctx="it's \$(id) \`x\`; y"
kc_flag="/tmp/a b/c'd"
mkdir -p "$rcbin"
cat >"$rcbin/kubectl" <<EOF
#!/bin/sh
printf '%s\\0' "\$@" >"$root/argv"
EOF
chmod +x "$rcbin/kubectl"

pass=0
failed=0
skipped=0
case_name=

ok() {
	pass=$((pass + 1))
}

bad() {
	failed=$((failed + 1))
	printf 'FAIL [%s] %s\n' "$case_name" "$*"
	if [ -s "$root/out" ]; then
		sed 's/^/    | /' "$root/out"
	fi
}

skip() {
	skipped=$((skipped + 1))
	printf 'SKIP [%s] %s\n' "$case_name" "$*"
}

build() {
	(cd "$here" && "$luau" build.luau -a "$@")
}

# sq WORD: WORD single-quoted for the rc file being written (POSIX and fish
# both read '...' literally for these values: no quote or backslash inside).
sq() {
	printf "'%s'" "$1"
}

# Writes HOME's rc files for shell NAME: PATH in the login file, KUBECONFIG in
# the interactive one (the probe runs -l -i; a quick-action split runs -l -c).
make_home() {
	h=$root/home-$1
	rm -rf "$h"
	mkdir -p "$h/zdot" "$h/.config/fish" "$h/.local/share" "$h/.cache"
	{
		echo "PATH=$(sq "$rcbin"):\$PATH; export PATH"
		echo "ENV=$(sq "$h/.shrc"); export ENV"
	} >"$h/.profile"
	echo "KUBECONFIG=$(sq "$kc_env"); export KUBECONFIG" >"$h/.shrc"
	{
		echo "PATH=$(sq "$rcbin"):\$PATH; export PATH"
		echo "[ -f ~/.bashrc ] && . ~/.bashrc"
	} >"$h/.bash_profile"
	echo "KUBECONFIG=$(sq "$kc_env"); export KUBECONFIG" >"$h/.bashrc"
	echo "PATH=$(sq "$rcbin"):\$PATH; export PATH" >"$h/zdot/.zprofile"
	echo "KUBECONFIG=$(sq "$kc_env"); export KUBECONFIG" >"$h/zdot/.zshrc"
	{
		echo "fish_add_path -g $(sq "$rcbin")"
		echo "set -gx KUBECONFIG $(sq "$kc_env")"
		echo "source $(sq "$repo/shell/tern-kube.fish")"
	} >"$h/.config/fish/config.fish"
}

# in_home NAME CMD...: CMD in a clean environment rooted at NAME's HOME.
in_home() {
	h=$root/home-$1
	shift
	env -i HOME="$h" USER="${USER:-tk}" LOGNAME="${LOGNAME:-tk}" TERM=dumb LANG=C.UTF-8 \
		PATH=/usr/bin:/bin:/usr/sbin:/sbin ZDOTDIR="$h/zdot" XDG_CONFIG_HOME="$h/.config" \
		XDG_DATA_HOME="$h/.local/share" XDG_CACHE_HOME="$h/.cache" TMPDIR="$root" \
		"$@" </dev/null
}

check_probe() {
	case_name="$1 probe"
	probe_home=$1
	eval "$(build probe "$2")" || {
		bad "no probe argv"
		return
	}
	in_home "$probe_home" "$@" >"$root/out" 2>"$root/err"
	if build parse "$(cat "$root/out")" >"$root/parsed" 2>>"$root/err"; then ok; else
		bad "parseProbe found no sentinel line"
		return
	fi
	if grep -qxF "path=$rcbin" "$root/parsed"; then ok; else bad "login PATH lacks the rc-added $rcbin: $(tr '\n' ' ' <"$root/parsed")"; fi
	if grep -qxF "kubeconfig=$kc_env" "$root/parsed"; then ok; else bad "KUBECONFIG from the interactive rc file missing: $(grep '^kubeconfig=' "$root/parsed")"; fi
}

check_line() {
	case_name="$1 quick-action line"
	rm -f "$root/argv"
	line=$(build line "$ctx" "$kc_flag") || {
		bad "no quick-action line"
		return
	}
	in_home "$1" "$2" -l -c "$line" >"$root/out" 2>&1
	eval "$(build argv "$ctx" "$kc_flag")"
	printf '%s\0' "$@" >"$root/want"
	if [ -f "$root/argv" ]; then ok; else
		bad "the fake kubectl on the login PATH did not run"
		return
	fi
	if cmp -s "$root/want" "$root/argv"; then ok; else bad "argv differs: got $(tr '\0' '|' <"$root/argv"), want $(tr '\0' '|' <"$root/want")"; fi
}

check_fish_guard() {
	case_name="fish guard snippet from config.fish"
	rm -f "$root/argv"
	rm -rf "$root/spool"
	mkdir -m 700 "$root/spool"
	in_home fish env TERM_PROGRAM=tern TERN_PANE=7 TKUBE_SPOOL="$root/spool" "$1" -l -c '
		if functions kubectl | string match -q "*_tern_kube_guard_core*"
			echo guard-function
		end
		emit fish_prompt
		kubectl get pods' >"$root/out" 2>&1
	if grep -qx guard-function "$root/out"; then ok; else bad "kubectl is not the guard function in a fish login shell"; fi
	if [ "$(cat "$root/spool/pane-7.env" 2>/dev/null)" = "kubeconfig=$kc_env" ]; then ok; else bad "pane-7.env: $(cat "$root/spool/pane-7.env" 2>&1)"; fi
	printf '%s\0' get pods >"$root/want"
	if cmp -s "$root/want" "$root/argv" 2>/dev/null; then ok; else bad "kubectl get pods did not pass through the guard to kubectl"; fi
}

shells=${SHELLS:-sh dash bash zsh fish}
for name in $shells; do
	path=$(command -v "$name" 2>/dev/null)
	case $path in
	/*) ;;
	*)
		case_name=$name
		skip "$name is not installed"
		continue
		;;
	esac
	make_home "$name"
	check_probe "$name" "$path"
	check_line "$name" "$path"
	[ "$name" = fish ] && check_fish_guard "$path"
done

printf '%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
[ "$failed" = 0 ]
