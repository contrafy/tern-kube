#!/bin/sh
# Tests for bin/tern-kube-drift without a cluster: a fake kubectl replays
# golden `kubectl diff` output and records every invocation. The cases pin
# what CI users rely on: the per-resource split agrees with the plugin's
# diffseg.luau on every shared golden input (so a PR comment and the Tern
# drift view never disagree), exit codes mean drift/no drift/error, the
# Markdown is safe to post as a PR comment, and nothing but read-only and
# dry-run kubectl calls is ever made.
#
#   sh tests/shell/drift/run.sh      (or: make test-shell-drift)
# Set SHELLS="dash bash" to choose the shells the CLI is run under.

set -u

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd -P)
here=$repo/tests/shell/drift
cli=$repo/bin/tern-kube-drift
luau=${LUAU:-$repo/.tools/bin/luau}
case $luau in
/*) ;;
*) luau=$PWD/$luau ;;
esac
[ -x "$luau" ] || {
	echo "missing $luau: run 'make bootstrap'" >&2
	exit 2
}

root=$(mktemp -d "${TMPDIR:-/tmp}/tkd-test.XXXXXX") || exit 2
root=$(cd -P "$root" && pwd -P)
trap 'rm -rf "$root"' EXIT

# Never a real kubectl or helm: only the fakes are on PATH.
PATH=$here/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset KUBECTL HELM KUBECONFIG
FAKE_DIR=$root/fake
TMPDIR=$root/tmp
export FAKE_DIR TMPDIR

shells=
for s in ${SHELLS:-sh dash bash zsh}; do
	command -v "$s" >/dev/null 2>&1 && shells="$shells $s"
done

pass=0
failed=0
case_name=

ok() { pass=$((pass + 1)); }
bad() {
	failed=$((failed + 1))
	printf 'FAIL [%s] %s\n' "$case_name" "$*"
	for f in out err; do
		[ -s "$root/$f" ] && sed "s/^/    $f| /" "$root/$f" | head -n 40
	done
}

fresh() {
	case_name=$1
	rm -rf "$FAKE_DIR" "$TMPDIR"
	mkdir -p "$FAKE_DIR/get" "$TMPDIR"
	echo kind-tern-kube-dev >"$FAKE_DIR/context"
}

# diff_from FILE [EXIT]: the fake's `kubectl diff` replays FILE.
diff_from() {
	cp "$1" "$FAKE_DIR/diff"
	if [ $# -ge 2 ]; then
		echo "$2" >"$FAKE_DIR/diff.exit"
	elif [ -s "$1" ]; then
		echo 1 >"$FAKE_DIR/diff.exit"
	else
		echo 0 >"$FAKE_DIR/diff.exit"
	fi
}

# run SHELL ARGS...: runs the CLI; sets $rc, stdout in out, stderr in err.
run() {
	sh_=$1
	shift
	"$sh_" "$cli" "$@" >"$root/out" 2>"$root/err"
	rc=$?
}

expect_rc() {
	[ "$rc" = "$1" ] && ok || bad "exit $rc, want $1"
}

expect_out() { # PATTERN (fixed string)
	grep -qF -- "$1" "$root/out" && ok || bad "stdout lacks: $1"
}

expect_no_out() {
	grep -qF -- "$1" "$root/out" && bad "stdout has: $1" || ok
}

expect_err() {
	grep -qF -- "$1" "$root/err" && ok || bad "stderr lacks: $1"
}

expect_argv() { # LINE: exact recorded kubectl invocation
	grep -qxF -- "$1" "$FAKE_DIR/argv" && ok || {
		bad "kubectl not called as: $1"
		sed 's/^/    argv| /' "$FAKE_DIR/argv"
	}
}

# Every invocation so far was read-only or a dry run.
expect_read_only() {
	if grep -q '^MUTATION\|^LEAK' "$FAKE_DIR/argv" 2>/dev/null; then
		bad "unsafe kubectl use: $(grep '^MUTATION\|^LEAK' "$FAKE_DIR/argv" | head -n 1)"
	else
		ok
	fi
}

compare() { # DIFF_FILE: CLI JSON segmentation == diffseg.parse
	if (cd "$here" && "$luau" compare.luau -a "$(cat "$1"; printf '\n#END')" "$(cat "$root/out")") >"$root/cmp" 2>&1; then
		ok
	else
		bad "segmentation differs from diffseg.luau on $1"
		sed 's/^/    cmp| /' "$root/cmp"
	fi
}

golden_inputs() {
	for f in "$repo"/tests/fixtures/real/mutate-preview/diff_*.txt; do
		[ -f "$f" ] && printf '%s\n' "$f"
	done
	if [ -d "$repo/tests/fixtures/drift" ]; then
		find "$repo/tests/fixtures/drift" -type f -name '*.txt' | LC_ALL=C sort | while IFS= read -r f; do
			if [ ! -s "$f" ] || head -n 1 "$f" | grep -q '^diff \|^--- '; then
				printf '%s\n' "$f"
			fi
		done
	fi
	for f in "$here"/cases/*.diff; do
		printf '%s\n' "$f"
	done
}

# --- Segmentation agrees with plugin/lib/mutation/diffseg.luau -----------

golden_inputs >"$root/inputs"
while IFS= read -r input; do
	name=${input#"$repo"/}
	exit_file=${input%.txt}.exit
	for variant in lf crlf; do
		fresh "golden $variant $name"
		if [ "$variant" = crlf ]; then
			awk '{ printf "%s\r\n", $0 }' "$input" >"$root/input"
		else
			cp "$input" "$root/input"
		fi
		if [ -f "$exit_file" ]; then
			diff_from "$root/input" "$(cat "$exit_file")"
		else
			diff_from "$root/input"
		fi
		run sh -f manifests --format json
		want=$(cat "$FAKE_DIR/diff.exit")
		expect_rc "$want"
		compare "$root/input"
		expect_read_only
	done
done <"$root/inputs"

# --- Under every available shell -------------------------------------------

mix=$repo/tests/fixtures/real/mutate-preview/diff_-f_preview+apps-mix.yaml.txt
for s in $shells; do
	fresh "$s: argv, quoting and pinned target"
	diff_from "$mix"
	KUBECTL_EXTERNAL_DIFF='colordiff -N' run "$s" -f 'dir with space/a.yaml' -f "it's.yaml" -R \
		--context ctx --kubeconfig '/k k/config' -n ns --format text
	expect_rc 1
	expect_argv "kubectl [--kubeconfig] [/k k/config] [--context] [ctx] [diff] [-n] [ns] [-f] [dir with space/a.yaml] [-f] [it's.yaml] [-R]"
	expect_read_only
	grep -q 'current-context' "$FAKE_DIR/argv" && bad "--context given, current context still queried" || ok
	expect_out "Drift: dir with space/a.yaml it's.yaml (context ctx, namespace ns)"
	expect_out "modify  Deployment.apps/web      tern-test-apps  +2 -2"
	expect_out "create  ConfigMap/preview-extra  tern-test-apps  +11 -0"
	expect_out "3 resources drifted (1 create, 2 modify, 0 delete; +14 -3)."

	fresh "$s: kustomize source, current context reported"
	diff_from "$mix"
	run "$s" -k overlays/prod --format json
	expect_rc 1
	expect_argv "kubectl [diff] [-k] [overlays/prod]"
	expect_out '"context":"kind-tern-kube-dev"'
	expect_out '"source":{"type":"kustomize","label":"overlays/prod"}'

	fresh "$s: no drift"
	: >"$FAKE_DIR/empty"
	diff_from "$FAKE_DIR/empty" 0
	run "$s" -f a.yaml --format markdown
	expect_rc 0
	expect_out "No drift: the cluster matches the manifests."
	expect_no_out "<details>"

	fresh "$s: kubectl diff error is exit 2 with kubectl's message"
	diff_from "$mix" 2
	echo 'Error from server (Forbidden): configmaps "x" is forbidden' >"$FAKE_DIR/diff.err"
	run "$s" -f a.yaml
	expect_rc 2
	expect_err 'Error from server (Forbidden)'
	expect_err 'kubectl diff failed (exit 2)'
	[ -s "$root/out" ] && bad "report printed despite the error" || ok

	fresh "$s: exit 1 without a diff is an error, not drift"
	: >"$FAKE_DIR/empty"
	diff_from "$FAKE_DIR/empty" 1
	echo 'error: something' >"$FAKE_DIR/diff.err"
	run "$s" -f a.yaml
	expect_rc 2

	fresh "$s: helm renders, then diffs the rendered file"
	diff_from "$mix"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: r\n' >"$FAKE_DIR/rendered.yaml"
	run "$s" --helm ./chart --release rel -f values.yaml --values 'prod values.yaml' -n apps --format json
	expect_rc 1
	grep -qxF 'helm [template] [rel] [./chart] [--namespace] [apps] [-f] [values.yaml] [-f] [prod values.yaml]' "$FAKE_DIR/helm.argv" &&
		ok || bad "helm argv: $(cat "$FAKE_DIR/helm.argv")"
	cmp -s "$FAKE_DIR/rendered.yaml" "$FAKE_DIR/rendered.seen" && ok || bad "kubectl diff did not get the rendered chart"
	grep -q '^kubectl \[diff\] \[-n\] \[apps\] \[-f\] \[.*/rendered.yaml\]$' "$FAKE_DIR/argv" && ok || bad "diff argv: $(cat "$FAKE_DIR/argv")"
	expect_out '"label":"helm ./chart (release rel)"'
	[ -z "$(ls "$TMPDIR")" ] && ok || bad "temp files left behind: $(ls "$TMPDIR")"

	fresh "$s: helm failure is exit 2"
	echo 1 >"$FAKE_DIR/helm.exit"
	run "$s" --helm ./chart --release rel
	expect_rc 2
	expect_err "helm template failed"
done

# --- Usage errors are exit 2 and never reach kubectl -----------------------

for args in "" "-f a -k b" "-k a -k b" "--helm c" "--helm c --release r -k d" "-f a --release r" \
	"-f a --format html" "-f a --max-diff-lines x" "-f a --max-bytes -1" "-f a --bogus" "-k a -R" "-f"; do
	fresh "usage: '$args'"
	# shellcheck disable=SC2086
	run sh $args
	expect_rc 2
	[ -s "$FAKE_DIR/argv" ] && bad "kubectl ran: $(cat "$FAKE_DIR/argv")" || ok
done

fresh "help and version"
run sh --help
expect_rc 0
expect_out "usage: tern-kube-drift"
run sh --version
expect_rc 0
expect_out "tern-kube-drift "

# --- Markdown is safe to post as a PR comment ------------------------------

fresh "markdown escapes names and fences diff content"
diff_from "$here/cases/odd-names.diff"
run sh -f 'x`<b>|y.yaml' --format markdown --context 'ctx<script>' -n 'ns@team'
expect_rc 1
expect_no_out '<script>'
expect_no_out '<b>'
expect_no_out '@team'
expect_out '### Drift: x&#96;&#60;b&#62;&#124;y.yaml'
expect_out 'Context ctx&#60;script&#62;, namespace ns&#64;team'
expect_out '| modify | PodDisruptionBudget.policy/a&#96;b&#60;script&#62;&#124;x | ns | 1 | 1 |'
expect_out '<summary>modify PodDisruptionBudget.policy ns/a&#96;b&#60;script&#62;&#124;x (+1 -1)</summary>'
# The diff holds ``` and ```` lines: the fence must be longer than both.
expect_out '`````diff'
# Every table row has exactly 5 cells (no unescaped | from a name).
awk '/^\| (create|modify|delete|unknown) \|/ { n = gsub(/\|/, "|"); if (n != 6) { print; bad = 1 } } END { exit bad }' "$root/out" &&
	ok || bad "table row with a stray |"
[ "$(grep -c '^<details>$' "$root/out")" = "$(grep -c '^</details>$' "$root/out")" ] && ok || bad "unbalanced <details>"
# Fences pair up: each opener is closed by a line of exactly the same backticks.
awk '/^`{3,}/ { f = $0; sub(/[^`].*/, "", f); if (open == "") open = f; else if ($0 == open) open = ""; }
	END { exit open != "" }' "$root/out" && ok || bad "unclosed code fence"

# kubectl masks Secret data but leaves the applied values in clear inside
# the last-applied-configuration annotation (real capture from kind).
for fmt in text markdown json; do
	fresh "$fmt: Secret values never reach the report"
	diff_from "$here/cases/secret-last-applied.diff"
	run sh -f a.yaml --format "$fmt"
	expect_rc 1
	expect_no_out 'tern-kube-test-not-a-secret'
	expect_out '*** (last-applied-configuration redacted by tern-kube-drift)'
	expect_out "'*** (after)'"
done

fresh "markdown: one <details> per resource, notes fenced"
diff_from "$here/cases/stray-truncated.diff"
run sh -f a.yaml --format markdown
expect_rc 1
[ "$(grep -c '^<summary>' "$root/out")" = 3 ] && ok || bad "want 2 resource + 1 notes <summary>"
expect_out '<summary>4 notes</summary>'
expect_out 'Warning: something odd'

fresh "--max-diff-lines truncates every format"
diff_from "$mix"
run sh -f a.yaml --format markdown --max-diff-lines 2
expect_out '_Truncated: 2 of 18 lines shown (--max-diff-lines)._'
expect_out '_Truncated: 2 of 12 lines shown (--max-diff-lines)._'
expect_no_out '+  MODE: preview'
run sh -f a.yaml --format json --max-diff-lines 2
expect_out '"lineCount":15,"truncated":true,"lines":["diff -u -N /tmp/LIVE-2795433448/v1.ConfigMap.tern-test-apps.preview-extra /tmp/MERGED-2701522766/v1.ConfigMap.tern-test-apps.preview-extra","--- /tmp/LIVE-2795433448/v1.ConfigMap.tern-test-apps.preview-extra\t2026-10-08 11:18:54"]'
run sh -f a.yaml --format markdown --max-diff-lines 0
expect_no_out '_Truncated'

fresh "--max-bytes keeps a comment under GitHub's limit"
diff_from "$mix"
run sh -f a.yaml --format markdown --max-bytes 1500
expect_rc 1
size=$(wc -c <"$root/out" | tr -d ' ')
[ "$size" -le 1500 ] && ok || bad "markdown is $size bytes, limit 1500"
expect_out '| create | ConfigMap/preview-extra | tern-test-apps | 11 | 0 |'
expect_out 'omitted to stay under --max-bytes._'
[ "$(grep -c '^<details>$' "$root/out")" = "$(grep -c '^</details>$' "$root/out")" ] && ok || bad "unbalanced <details>"

# --- Unmanaged objects -----------------------------------------------------

unmanaged_setup() {
	t=$(printf '\t')
	cat >"$FAKE_DIR/manifest.tsv" <<EOF
v1${t}ConfigMap${t}apps${t}app-config
apps/v1${t}Deployment${t}apps${t}web
v1${t}Namespace${t}<no value>${t}apps
EOF
	cat >"$FAKE_DIR/get/ConfigMap.apps" <<EOF
v1${t}ConfigMap${t}apps${t}app-config${t}-${t}-${t}
v1${t}ConfigMap${t}apps${t}kube-root-ca.crt${t}-${t}-${t}
v1${t}ConfigMap${t}apps${t}hand-made${t}-${t}-${t}
v1${t}ConfigMap${t}apps${t}from-owner${t}owned${t}-${t}
EOF
	cat >"$FAKE_DIR/get/Deployment.apps.apps" <<EOF
apps/v1${t}Deployment${t}apps${t}web${t}-${t}-${t}
apps/v1${t}Deployment${t}apps${t}debug-copy${t}-${t}-${t}
EOF
	cat >"$FAKE_DIR/get/Namespace.apps" <<EOF
v1${t}Namespace${t}<no value>${t}apps${t}-${t}-${t}
v1${t}Namespace${t}<no value>${t}default${t}-${t}-${t}
v1${t}Namespace${t}<no value>${t}kube-system${t}-${t}-${t}
v1${t}Namespace${t}<no value>${t}scratch${t}-${t}-${t}
EOF
	cat >"$FAKE_DIR/get/secrets.apps" <<EOF
v1${t}Secret${t}apps${t}sh.helm.release.v1.web.v1${t}-${t}helm.sh/release.v1${t}
v1${t}Secret${t}apps${t}tok${t}-${t}kubernetes.io/service-account-token${t}
v1${t}Secret${t}apps${t}stray${t}-${t}Opaque${t}
EOF
	cat >"$FAKE_DIR/get/serviceaccounts.apps" <<EOF
v1${t}ServiceAccount${t}apps${t}default${t}-${t}-${t}
EOF
}

fresh "--unmanaged auto lists undeclared live objects of the source's kinds"
unmanaged_setup
: >"$FAKE_DIR/empty"
diff_from "$FAKE_DIR/empty" 0
run sh -f a.yaml --unmanaged auto --format json
expect_rc 1
expect_argv "kubectl [apply] [--dry-run=client] [-f] [a.yaml] [-o] [go-template={{define \"o\"}}{{.apiVersion}}{{\"\\t\"}}{{.kind}}{{\"\\t\"}}{{.metadata.namespace}}{{\"\\t\"}}{{.metadata.name}}{{\"\\n\"}}{{end}}{{if eq .kind \"List\"}}{{range .items}}{{template \"o\" .}}{{end}}{{else}}{{template \"o\" .}}{{end}}]"
grep -c '^kubectl \[get\] \[\(ConfigMap\|Deployment.apps\|Namespace\)\] \[-n\] \[apps\]' "$FAKE_DIR/argv" | grep -qx 3 && ok ||
	bad "want one get per kind in namespace apps: $(cat "$FAKE_DIR/argv")"
expect_out '"unmanaged":[{"group":null,"version":"v1","kind":"ConfigMap","namespace":"apps","name":"hand-made"},{"group":"apps","version":"v1","kind":"Deployment","namespace":"apps","name":"debug-copy"},{"group":null,"version":"v1","kind":"Namespace","namespace":null,"name":"scratch"}]'
expect_out '"summary":{"resources":0,"create":0,"modify":0,"delete":0,"unknown":0,"added":0,"removed":0,"unmanaged":3}'
expect_read_only

fresh "--unmanaged KINDS skips bookkeeping objects; markdown table"
unmanaged_setup
diff_from "$mix"
run sh -f a.yaml --unmanaged secrets,serviceaccounts --format markdown
expect_rc 1
expect_out '**3 resources drifted** (1 create, 2 modify, 0 delete; +14 -3), **1 unmanaged** in the cluster.'
expect_out '| Secret/stray | apps |'
expect_no_out 'helm.release'
expect_no_out '| ServiceAccount/default'
expect_no_out 'tok'

fresh "--unmanaged with an unknown kind is an error"
unmanaged_setup
diff_from "$mix"
run sh -f a.yaml --unmanaged widgets
expect_rc 2
expect_err "cannot list widgets in namespace apps"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" = 0 ]
