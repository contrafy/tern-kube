#!/bin/sh
# Tests for scripts/tern-kube-aliases. Every case runs with a temporary HOME
# (its own rc files) and a temporary plugin dir; nothing reads the real rc
# files, the real plugin dir or a real tern.
#
#   sh tests/shell/aliases/run.sh      (or: make test-shell-aliases)

set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tool=$repo/scripts/tern-kube-aliases
src_manifest=$repo/plugin.toml

root=$(mktemp -d "${TMPDIR:-/tmp}/tka-test.XXXXXX") || exit 2
trap 'rm -rf "$root"' EXIT

# Never let the tool see the real environment's rc dirs or tern.
HOME=$root/home
mkdir -p "$HOME"
export HOME
unset ZDOTDIR XDG_CONFIG_HOME TKUBE_ALIASES_TIMEOUT
TERN_BIN=$root/no-such-tern
export TERN_BIN
# A minimal PATH (plus wherever the probed shells live) so commands installed
# here cannot shadow the test aliases (macOS ships /usr/bin/kcc, hence kclr).
safe_path=/usr/bin:/bin:/usr/sbin:/sbin
for s in zsh bash fish; do
	p=$(command -v "$s" 2>/dev/null) && safe_path=$safe_path:$(dirname -- "$p")
done
PATH=$safe_path
export PATH

pass=0
failed=0
skipped=0

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

# run ARGS...: runs the tool, output (stdout+stderr) in $root/out, status in $st.
run() {
	"$tool" "$@" >"$root/out" 2>&1
	st=$?
}

expect_status() {
	if [ "$st" = "$1" ]; then ok; else bad "$2: exit $st, want $1"; fi
}

expect_out() {
	if grep -E -q -- "$1" "$root/out"; then ok; else bad "$2: output lacks /$1/"; fi
}

expect_no_out() {
	if grep -E -q -- "$1" "$root/out"; then bad "$2: output has /$1/"; else ok; fi
}

expect_same() {
	if cmp -s "$1" "$2"; then ok; else bad "$3: $1 differs from $2"; fi
}

# Writes the rc files of shell $1 with aliases k, kc (-> k), kclr (absolute
# kubecolor), kp (with args), ll (not kubectl), function kf, and rc noise.
write_rc() {
	rm -rf "$HOME"
	mkdir -p "$HOME"
	case $1 in
	zsh | bash)
		cat >"$HOME/.$1rc" <<'EOF'
echo "rc noise on stdout"
echo "rc noise on stderr" >&2
alias k=kubectl
alias kc=k
alias kclr=/opt/homebrew/bin/kubecolor
alias kp='kubectl get pods'
alias ll='ls -l'
kf() { kubectl "$@"; }
EOF
		;;
	fish)
		mkdir -p "$HOME/.config/fish"
		cat >"$HOME/.config/fish/config.fish" <<'EOF'
echo "rc noise on stdout"
echo "rc noise on stderr" >&2
alias k kubectl
alias kc k
alias kclr /opt/homebrew/bin/kubecolor
alias kp 'kubectl get pods'
alias ll 'ls -l'
function kf
	kubectl $argv
end
EOF
		;;
	esac
}

drop_alias() { # shell name
	case $1 in
	fish) f=$HOME/.config/fish/config.fish ;;
	*) f=$HOME/.$1rc ;;
	esac
	grep -v "^alias $2[ =]" "$f" >"$f.new" && mv "$f.new" "$f"
}

fresh_plugin() {
	rm -rf "$root/plugin"
	mkdir -p "$root/plugin"
	cp "$src_manifest" "$root/plugin/plugin.toml"
	P=$root/plugin
	M=$P/plugin.toml
}

block() {
	awk '/# END tern-kube aliases/ { b = 0 } b { print } /# BEGIN tern-kube aliases/ { b = 1 }' "$1"
}

# The source manifest must carry the empty marker block the tool edits.
case_name=manifest
if [ "$(grep -c '^	# BEGIN tern-kube aliases$' "$src_manifest")" = 1 ] &&
	[ "$(grep -c '^	# END tern-kube aliases$' "$src_manifest")" = 1 ]; then ok; else bad "plugin.toml lacks the marker block"; fi
if [ -z "$(block "$src_manifest")" ]; then ok; else bad "plugin.toml alias block is not empty"; fi
kubectl_forms=$(grep -c '^	"kubectl[ "]' "$src_manifest")

shell_cases() {
	sh=$1
	write_rc "$sh"
	fresh_plugin
	cp "$M" "$root/pristine.toml"

	case_name="$sh detect"
	run --shell "$sh" detect
	expect_status 0 "detect"
	expect_out '^k +alias +ok +k -> kubectl$' "k accepted"
	expect_out '^kc +alias +ok +kc -> k -> kubectl$' "chain followed"
	expect_out '^kclr +alias +ok .*/opt/homebrew/bin/kubecolor$' "absolute kubecolor accepted"
	expect_out '^kp +alias +refused +alias carries arguments' "arg-carrying alias refused"
	expect_out '^kf +function +needs-force' "function needs --force"
	expect_no_out '^ll ' "unrelated alias listed"
	expect_no_out 'rc noise' "rc noise leaked"
	expect_same "$M" "$root/pristine.toml" "detect modified the manifest"

	case_name="$sh add"
	run --shell "$sh" --plugin-dir "$P" add k
	expect_status 0 "add k"
	expect_out 'tern plugin reload' "reload hint"
	n=$(block "$M" | grep -c '^	"k[ "]')
	if [ "$n" = "$kubectl_forms" ]; then ok; else bad "k has $n globs, want $kubectl_forms"; fi
	block "$M" | grep -q '^	"k get",$' && ok || bad 'missing "k get"'
	block "$M" | grep -q '^	"k -\* rollout restart \*",$' && ok || bad 'missing "k -* rollout restart *"'
	cp "$M" "$root/after-k.toml"
	run --shell "$sh" --plugin-dir "$P" add k
	expect_status 0 "re-add k"
	expect_same "$M" "$root/after-k.toml" "add is not idempotent"

	run --shell "$sh" --plugin-dir "$P" add kclr kc
	expect_status 0 "add kclr kc"
	order=$(block "$M" | sed -n 's/^	"\([^ "]*\).*/\1/p' | uniq | tr '\n' ' ')
	if [ "$order" = "k kc kclr " ]; then ok; else bad "block order '$order', want 'k kc kclr '"; fi
	# Everything outside the block is untouched.
	if [ "$(grep -v -E '^	"(k|kc|kclr)[ "]' "$M")" = "$(cat "$root/pristine.toml")" ]; then ok; else bad "lines outside the block changed"; fi

	case_name="$sh refuse"
	cp "$M" "$root/before.toml"
	run --shell "$sh" --plugin-dir "$P" add kp
	expect_status 1 "add kp"
	expect_out 'carries arguments' "kp reason"
	run --shell "$sh" --plugin-dir "$P" add ll
	expect_status 1 "add ll"
	expect_out 'not kubectl/kubecolor' "ll reason"
	run --shell "$sh" --plugin-dir "$P" add nope
	expect_status 1 "add nope"
	expect_out 'not an alias, function or command' "nope reason"
	run --shell "$sh" --plugin-dir "$P" add kf
	expect_status 1 "add kf"
	expect_out 'needs-force' "kf reason"
	run --shell "$sh" --plugin-dir "$P" add k kp
	expect_status 1 "add k kp (all or nothing)"
	expect_same "$M" "$root/before.toml" "refused add modified the manifest"
	run --shell "$sh" --plugin-dir "$P" --force add kp
	expect_status 1 "--force does not accept arg-carrying aliases"
	run --shell "$sh" --plugin-dir "$P" --force add kf
	expect_status 0 "--force add kf"
	block "$M" | grep -q '^	"kf get",$' && ok || bad "kf globs missing after --force"

	case_name="$sh check"
	run --shell "$sh" --plugin-dir "$P" check
	expect_status 1 "check without --force (kf is a function)"
	expect_out 'kf is a function' "check names the function"
	run --shell "$sh" --plugin-dir "$P" --force check
	expect_status 0 "check --force"
	drop_alias "$sh" kclr
	run --shell "$sh" --plugin-dir "$P" --force check
	expect_status 1 "check after alias removed"
	expect_out 'kclr no longer resolves' "check names the alias"

	case_name="$sh remove"
	run --plugin-dir "$P" remove kclr kf
	expect_status 0 "remove kclr kf"
	run --plugin-dir "$P" list
	if [ "$(cat "$root/out")" = "$(printf 'k\nkc')" ]; then ok; else bad "list after remove"; fi
	cp "$M" "$root/after-rm.toml"
	run --plugin-dir "$P" remove kclr
	expect_status 0 "remove twice"
	expect_same "$M" "$root/after-rm.toml" "remove is not idempotent"
	run --plugin-dir "$P" remove k kc
	expect_status 0 "remove all"
	expect_same "$M" "$root/pristine.toml" "add+remove did not restore the manifest"

	case_name="$sh timeout"
	case $sh in
	fish) printf 'sleep 30\n' >>"$HOME/.config/fish/config.fish" ;;
	*) printf 'sleep 30\n' >>"$HOME/.${sh}rc" ;;
	esac
	t0=$(date +%s)
	env TKUBE_ALIASES_TIMEOUT=1 "$tool" --shell "$sh" detect >"$root/out" 2>&1
	st=$?
	t1=$(date +%s)
	expect_status 2 "hung rc"
	expect_out 'did not finish within 1s' "timeout message"
	if [ $((t1 - t0)) -lt 10 ]; then ok; else bad "timeout took $((t1 - t0))s"; fi
}

for sh in zsh bash fish; do
	if command -v "$sh" >/dev/null 2>&1; then
		shell_cases "$sh"
	else
		skipped=$((skipped + 1))
		printf 'SKIP %s: not installed, its probe is untested\n' "$sh"
	fi
done

# Shell-independent cases use bash (always present where this runs).
write_rc bash
fresh_plugin

case_name="no markers"
grep -v 'tern-kube aliases$' "$M" >"$M.new" && mv "$M.new" "$M"
cp "$M" "$root/nomark.toml"
run --shell bash --plugin-dir "$P" add k
expect_status 2 "marker-less add"
expect_out 'refusing to edit' "marker-less message"
run --plugin-dir "$P" remove k
expect_status 2 "marker-less remove"
expect_same "$M" "$root/nomark.toml" "marker-less manifest modified"

case_name="bad markers"
fresh_plugin
printf '\t# END tern-kube aliases\n' >>"$M"
run --shell bash --plugin-dir "$P" add k
expect_status 2 "duplicate END"
fresh_plugin
awk '/# BEGIN tern-kube aliases/ { next } { print } /^\[\[blocks\]\]/ && !d { print "# BEGIN tern-kube aliases"; d = 1 }' "$src_manifest" >"$M"
run --shell bash --plugin-dir "$P" add k
expect_status 2 "BEGIN outside lens kubectl"

case_name="names"
fresh_plugin
for n in 'k*' kubectl kubecolor -x 'a b'; do
	run --shell bash --plugin-dir "$P" add "$n"
	expect_status 2 "add '$n'"
done
expect_same "$M" "$src_manifest" "invalid names modified the manifest"
run --plugin-dir "$P" list k
expect_status 2 "list takes no names"
run --plugin-dir "$P" frob
expect_status 2 "unknown command"
run --shell tcsh detect
expect_status 2 "unsupported shell"

case_name="symlinked command"
mkdir -p "$root/bin" "$root/opt"
# A (non-executing) stand-in named kubectl, reached through a relative link.
printf '#!/bin/sh\nexit 0\n' >"$root/opt/kubectl"
chmod +x "$root/opt/kubectl"
ln -s ../opt/kubectl "$root/bin/kx"
printf '#!/bin/sh\nexec kubectl "$@"\n' >"$root/bin/kw"
chmod +x "$root/bin/kw"
ln -s /bin/ls "$root/bin/kls"
printf 'PATH=%s:$PATH\n' "$root/bin" >>"$HOME/.bashrc"
run --shell bash --plugin-dir "$P" add kx
expect_status 0 "command symlinked to kubectl"
run --shell bash --plugin-dir "$P" add kw
expect_status 1 "wrapper script needs --force"
expect_out 'opaque wrapper' "wrapper reason"
run --shell bash --plugin-dir "$P" add kls
expect_status 1 "command symlinked elsewhere"

case_name="plugin dir resolution"
cat >"$root/tern" <<EOF
#!/bin/sh
[ "\$*" = "plugin dir" ] || { echo "fake tern: unexpected \$*" >&2; exit 9; }
echo "$root/plugins"
EOF
chmod +x "$root/tern"
TERN_BIN=$root/tern
mkdir -p "$root/plugins/tern-kube"
cp "$src_manifest" "$root/plugins/tern-kube/plugin.toml"
run --shell bash add k
expect_status 0 "installed plugin"
block "$root/plugins/tern-kube/plugin.toml" | grep -q '"k get"' && ok || bad "installed manifest not edited"
fresh_plugin
printf '%s\n' "$P" >"$root/plugins/tern-kube.path"
run --shell bash add k
expect_status 0 "linked plugin"
expect_out 'linked' "linked note"
block "$M" | grep -q '"k get"' && ok || bad "linked manifest not edited"
rm -rf "$root/plugins"
mkdir -p "$root/plugins"
run --shell bash list
expect_status 2 "not installed"
expect_out 'not installed' "not installed message"
TERN_BIN=$root/no-such-tern
run --shell bash list
expect_status 2 "no tern"

case_name="foreign HOME"
if [ "$(id -u)" = 0 ]; then
	skipped=$((skipped + 1))
	echo "SKIP foreign HOME: running as root"
else
	env HOME=/ "$tool" --shell bash detect >"$root/out" 2>&1
	st=$?
	expect_status 2 "HOME owned by another user"
	expect_out 'not owned by you' "foreign HOME message"
fi

case_name=help
run --help
expect_status 0 "--help"
expect_out 'install --force' "help mentions reinstall"
expect_out 'zsh reports alias-expanded' "help mentions zsh"

printf '%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
[ "$failed" = 0 ]
