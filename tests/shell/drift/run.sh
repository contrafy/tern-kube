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

expect_no_err() {
	grep -qF -- "$1" "$root/err" && bad "stderr has: $1" || ok
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

compare() { # DIFF_FILE [N]: CLI JSON segmentation == diffseg.parse (N: contexts[N] of a v2 report)
	if (cd "$here" && "$luau" compare.luau -a "$(cat "$1"; printf '\n#END')" "$(cat "$root/out")" ${2:+"$2"}) >"$root/cmp" 2>&1; then
		ok
	else
		bad "segmentation differs from diffseg.luau on $1"
		sed 's/^/    cmp| /' "$root/cmp"
	fi
}

# golden NAME: stdout equals golden/NAME byte for byte. TKD_UPDATE_GOLDEN=1
# writes missing goldens (delete one to regenerate it).
golden() {
	g=$here/golden/$1
	if [ "${TKD_UPDATE_GOLDEN:-}" = 1 ] && [ ! -f "$g" ]; then
		cp "$root/out" "$g"
	fi
	if cmp -s "$g" "$root/out"; then
		ok
	else
		bad "stdout differs from golden/$1"
		diff -u "$g" "$root/out" | head -n 40 | sed 's/^/    golden| /'
	fi
}

ext() {
	case $1 in
	text) echo txt ;;
	markdown) echo md ;;
	*) echo "$1" ;;
	esac
}

# Two contexts replayed by the fake: kind-tern-kube-dev drifted only in
# ConfigMap app-config and has an undeclared Secret; kind-tern-kube-dev2
# drifted in all three declared objects.
mc_setup() {
	t=$(printf '\t')
	for c in kind-tern-kube-dev kind-tern-kube-dev2; do
		mkdir -p "$FAKE_DIR/ctx/$c/get"
		cat >"$FAKE_DIR/ctx/$c/manifest.tsv" <<EOF
apps/v1${t}Deployment${t}tern-test-apps${t}web
v1${t}ConfigMap${t}tern-test-apps${t}app-config
v1${t}ConfigMap${t}tern-test-apps${t}preview-extra
EOF
		echo 1 >"$FAKE_DIR/ctx/$c/diff.exit"
	done
	cp "$here/cases/mc-dev.diff" "$FAKE_DIR/ctx/kind-tern-kube-dev/diff"
	cp "$mix" "$FAKE_DIR/ctx/kind-tern-kube-dev2/diff"
	cat >"$FAKE_DIR/ctx/kind-tern-kube-dev/get/secrets.tern-test-apps" <<EOF
v1${t}Secret${t}tern-test-apps${t}stray${t}-${t}Opaque${t}
EOF
	: >"$FAKE_DIR/ctx/kind-tern-kube-dev2/get/secrets.tern-test-apps"
	printf 'kind-tern-kube-dev\nkind-tern-kube-dev2\n' >"$FAKE_DIR/contexts"
}

# mc_down NAME: a context whose API server is unreachable.
mc_down() {
	mkdir -p "$FAKE_DIR/ctx/$1"
	: >"$FAKE_DIR/ctx/$1/diff"
	echo 1 >"$FAKE_DIR/ctx/$1/diff.exit"
	echo 'Unable to connect to the server: dial tcp 127.0.0.1:1: connect: connection refused' >"$FAKE_DIR/ctx/$1/diff.err"
}

mc_args="-f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 -n tern-test-apps --unmanaged secrets"

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

	fresh "$s: helm renders without hooks, then diffs the rendered file"
	diff_from "$mix"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: r\n' >"$FAKE_DIR/rendered.yaml"
	run "$s" --helm ./chart --release rel -f values.yaml --values 'prod values.yaml' -n apps --format json
	expect_rc 1
	# Hooks (e.g. pre-upgrade) never exist after an install: rendering them
	# would report a create on every in-sync release.
	grep -qxF 'helm [template] [rel] [./chart] [--no-hooks] [--namespace] [apps] [-f] [values.yaml] [-f] [prod values.yaml]' "$FAKE_DIR/helm.argv" &&
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

	fresh "$s: two contexts: one kubectl run per context, in --context order"
	mc_setup
	# shellcheck disable=SC2086
	run "$s" $mc_args --format text
	expect_rc 1
	golden multi.txt
	grep '\[diff\]' "$FAKE_DIR/argv" >"$root/diffs"
	printf '%s\n' "kubectl [--context] [kind-tern-kube-dev] [diff] [-n] [tern-test-apps] [-f] [a.yaml]" \
		"kubectl [--context] [kind-tern-kube-dev2] [diff] [-n] [tern-test-apps] [-f] [a.yaml]" >"$root/want"
	cmp -s "$root/want" "$root/diffs" && ok || bad "diff calls: $(cat "$root/diffs")"
	# Per context: diff, the declared listing, then the unmanaged listing.
	awk '{ sub(/ \[-o\].*/, ""); print }' "$FAKE_DIR/argv" >"$root/calls"
	printf '%s\n' "kubectl [--context] [kind-tern-kube-dev] [diff] [-n] [tern-test-apps] [-f] [a.yaml]" \
		"kubectl [--context] [kind-tern-kube-dev] [create] [--dry-run=client] [-n] [tern-test-apps] [-f] [a.yaml]" \
		"kubectl [--context] [kind-tern-kube-dev] [get] [secrets] [-n] [tern-test-apps]" \
		"kubectl [--context] [kind-tern-kube-dev2] [diff] [-n] [tern-test-apps] [-f] [a.yaml]" \
		"kubectl [--context] [kind-tern-kube-dev2] [create] [--dry-run=client] [-n] [tern-test-apps] [-f] [a.yaml]" \
		"kubectl [--context] [kind-tern-kube-dev2] [get] [secrets] [-n] [tern-test-apps]" >"$root/want"
	cmp -s "$root/want" "$root/calls" && ok || bad "kubectl calls: $(cat "$root/calls")"
	expect_read_only

	fresh "$s: --all-contexts reads the kubeconfig's contexts"
	mc_setup
	run "$s" -f a.yaml --all-contexts --kubeconfig /k/config -n tern-test-apps --unmanaged secrets --format text
	expect_rc 1
	golden multi.txt
	expect_argv "kubectl [--kubeconfig] [/k/config] [config] [get-contexts] [-o] [name]"
	grep -c '^kubectl \[--kubeconfig\] \[/k/config\] \[--context\] \[kind-tern-kube-dev2\{0,1\}\] \[diff\]' "$FAKE_DIR/argv" |
		grep -qx 2 && ok || bad "want one diff per listed context: $(cat "$FAKE_DIR/argv")"

	fresh "$s: a failing context is an error column, the others still run"
	mc_setup
	mc_down kind-tern-kube-down
	run "$s" -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-down --context kind-tern-kube-dev2 \
		-n tern-test-apps --format text
	expect_rc 2
	expect_out 'Drift: a.yaml across 3 contexts (namespace tern-test-apps)'
	expect_out 'kind-tern-kube-down: error: kubectl diff exited 1 without a diff: Unable to connect to the server: dial tcp 127.0.0.1:1: connect: connection refused'
	expect_out 'kind-tern-kube-dev2: 3 resources drifted (1 create, 2 modify, 0 delete; +14 -3).'
	expect_out '=== [kind-tern-kube-dev2] modify Deployment.apps tern-test-apps/web (+2 -2)'
	expect_err '[kind-tern-kube-down] Unable to connect to the server'
	expect_err 'tern-kube-drift: [kind-tern-kube-down] kubectl diff exited 1 without a diff'

	fresh "$s: two contexts in sync: exit 0"
	mc_setup
	for c in kind-tern-kube-dev kind-tern-kube-dev2; do
		: >"$FAKE_DIR/ctx/$c/diff"
		echo 0 >"$FAKE_DIR/ctx/$c/diff.exit"
	done
	run "$s" -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 --format json
	expect_rc 0
	expect_out '"drift":false,"summary":{"contexts":2,"drifted":0,"errors":0}'
	expect_out '{"key":"apps.v1.Deployment.tern-test-apps.web","group":"apps","version":"v1","kind":"Deployment","namespace":"tern-test-apps","name":"web","cells":[{"context":"kind-tern-kube-dev","state":"insync","added":null,"removed":null},{"context":"kind-tern-kube-dev2","state":"insync","added":null,"removed":null}]}'

	fresh "$s: duplicate --context is a usage error"
	mc_setup
	run "$s" -f a.yaml --context kind-tern-kube-dev --context=kind-tern-kube-dev
	expect_rc 2
	expect_err '--context kind-tern-kube-dev given twice'
	[ -s "$FAKE_DIR/argv" ] && bad "kubectl ran: $(cat "$FAKE_DIR/argv")" || ok
done

# --- Usage errors are exit 2 and never reach kubectl -----------------------

for args in "" "-f a -k b" "-k a -k b" "--helm c" "--helm c --release r -k d" "-f a --release r" \
	"-f a --format html" "-f a --max-diff-lines x" "-f a --max-bytes -1" "-f a --bogus" "-k a -R" "-f" \
	"-f a --context x --context x" "-f a --all-contexts --context x" "-f a --context x --all-contexts" \
	"-f a --context x --context="; do
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
expect_out "tern-kube-drift 0.2.0"

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

# The source's objects, listed with `create --dry-run=client` (apply would
# print the live object of one that exists, hiding the source's Secret
# values): name and the keys of export placeholder values per object.
listing_argv="kubectl [create] [--dry-run=client] [-f] [a.yaml] [-o] [go-template={{define \"o\"}}{{.apiVersion}}{{\"\\t\"}}{{.kind}}{{\"\\t\"}}{{.metadata.namespace}}{{\"\\t\"}}{{.metadata.name}}{{\"\\t\"}}{{if and (eq .kind \"Secret\") (eq .apiVersion \"v1\")}}{{range \$k, \$v := .stringData}}{{if eq (printf \"%v\" \$v) \"REPLACE_ME\"}}{{\$k}},{{end}}{{end}}{{range \$k, \$v := .data}}{{if eq (printf \"%v\" \$v) \"UkVQTEFDRV9NRQ==\"}}{{\$k}},{{end}}{{end}}{{end}}{{\"\\n\"}}{{end}}{{if eq .kind \"List\"}}{{range .items}}{{template \"o\" .}}{{end}}{{else}}{{template \"o\" .}}{{end}}]"

# Live rows: apiVersion, kind, namespace, name, owned, type, bootstrapping
# label, helm.sh/hook annotation, meta.helm.sh/release-name annotation.
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
expect_argv "$listing_argv"
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

# A Helm release owns its objects (and its hooks, which a render without
# hooks never declares): they are never "unmanaged", whatever the source.
fresh "--unmanaged never lists objects of a Helm release or Helm hooks"
unmanaged_setup
cat >>"$FAKE_DIR/get/ConfigMap.apps" <<EOF
v1${t}ConfigMap${t}apps${t}web-pre-upgrade${t}-${t}-${t}${t}pre-upgrade,pre-rollback${t}<no value>
v1${t}ConfigMap${t}apps${t}other-config${t}-${t}-${t}${t}<no value>${t}other
EOF
cat >>"$FAKE_DIR/get/secrets.apps" <<EOF
v1${t}Secret${t}apps${t}other-tls${t}-${t}Opaque${t}${t}<no value>${t}other
v1${t}Secret${t}apps${t}stray-annotated${t}-${t}Opaque${t}${t}<no value>${t}<no value>
EOF
: >"$FAKE_DIR/empty"
diff_from "$FAKE_DIR/empty" 0
run sh -f a.yaml --unmanaged ConfigMap,secrets --format text
expect_rc 1
expect_argv "kubectl [get] [secrets] [-n] [apps] [-o] [go-template={{range .items}}{{.apiVersion}}{{\"\\t\"}}{{.kind}}{{\"\\t\"}}{{.metadata.namespace}}{{\"\\t\"}}{{.metadata.name}}{{\"\\t\"}}{{if .metadata.ownerReferences}}owned{{else}}-{{end}}{{\"\\t\"}}{{if .type}}{{.type}}{{else}}-{{end}}{{\"\\t\"}}{{with .metadata.labels}}{{index . \"kubernetes.io/bootstrapping\"}}{{end}}{{\"\\t\"}}{{with .metadata.annotations}}{{index . \"helm.sh/hook\"}}{{end}}{{\"\\t\"}}{{with .metadata.annotations}}{{index . \"meta.helm.sh/release-name\"}}{{end}}{{\"\\n\"}}{{end}}]"
expect_no_out 'web-pre-upgrade'
expect_no_out 'other-config'
expect_no_out 'other-tls'
expect_out '  Secret/stray-annotated (namespace apps)'
expect_out '  ConfigMap/hand-made (namespace apps)'

fresh "--helm: live objects of the release itself are not unmanaged either"
unmanaged_setup
cat >>"$FAKE_DIR/get/ConfigMap.apps" <<EOF
v1${t}ConfigMap${t}apps${t}rel-leftover${t}-${t}-${t}${t}<no value>${t}rel
EOF
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: app-config\n' >"$FAKE_DIR/rendered.yaml"
: >"$FAKE_DIR/empty"
diff_from "$FAKE_DIR/empty" 0
run sh --helm ./chart --release rel -n apps --unmanaged ConfigMap --format text
expect_rc 1
expect_no_out 'rel-leftover'
expect_out '  ConfigMap/hand-made (namespace apps)'

# --- One context: the 0.1.0 report, byte for byte --------------------------
# golden/single-* were written by tern-kube-drift 0.1.0, before contexts
# became repeatable: one context must keep producing exactly that report.

for fmt in text markdown json; do
	fresh "golden single $fmt: pinned context and namespace"
	diff_from "$mix"
	run sh -f a.yaml --context kind-tern-kube-dev -n tern-test-apps --format "$fmt"
	expect_rc 1
	golden "single-mix.$(ext "$fmt")"

	fresh "golden single $fmt: current context, unmanaged"
	unmanaged_setup
	diff_from "$mix"
	run sh -f a.yaml --unmanaged secrets,serviceaccounts --format "$fmt"
	expect_rc 1
	golden "single-unmanaged.$(ext "$fmt")"

	fresh "golden single $fmt: notes, truncation, size budget"
	diff_from "$here/cases/stray-truncated.diff"
	run sh -f a.yaml -n apps --max-diff-lines 3 --max-bytes 520 --format "$fmt"
	expect_rc 1
	golden "single-notes.$(ext "$fmt")"

	fresh "$fmt: --all-contexts with one context is the one-context report"
	mc_setup
	echo kind-tern-kube-dev >"$FAKE_DIR/contexts"
	run sh -f a.yaml --context kind-tern-kube-dev --unmanaged secrets --format "$fmt"
	expect_rc 1
	cp "$root/out" "$root/one"
	run sh -f a.yaml --all-contexts --unmanaged secrets --format "$fmt"
	expect_rc 1
	cmp -s "$root/one" "$root/out" && ok || bad "--all-contexts (one context) differs from --context"
done

# --- Two or more contexts --------------------------------------------------

for fmt in markdown json; do
	fresh "golden two contexts $fmt"
	mc_setup
	# shellcheck disable=SC2086
	run sh $mc_args --format "$fmt"
	expect_rc 1
	golden "multi.$(ext "$fmt")"
done

fresh "two contexts json: each context's segmentation equals diffseg.luau"
mc_setup
run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 --format json
expect_rc 1
expect_out '{"version":2,'
compare "$here/cases/mc-dev.diff" 1
compare "$mix" 2

fresh "two contexts markdown: --max-bytes drops diffs from the last context backwards"
mc_setup
# shellcheck disable=SC2086
run sh $mc_args --format markdown --max-bytes 2000
expect_rc 1
size=$(wc -c <"$root/out" | tr -d ' ')
[ "$size" -le 2000 ] && ok || bad "markdown is $size bytes, limit 2000"
expect_out '| Deployment.apps/web | tern-test-apps | in sync | modify +2 -2 |'
expect_out '| kind-tern-kube-dev2 | **3 resources drifted** (1 create, 2 modify, 0 delete; +14 -3), 0 unmanaged |'
expect_out '<summary>[kind-tern-kube-dev] modify ConfigMap tern-test-apps/app-config (+1 -1)</summary>'
expect_no_out '<summary>[kind-tern-kube-dev2]'
expect_out '_3 diffs omitted to stay under --max-bytes._'
[ "$(grep -c '^<details>$' "$root/out")" = "$(grep -c '^</details>$' "$root/out")" ] && ok || bad "unbalanced <details>"

fresh "two contexts markdown: the matrix and summary survive any --max-bytes"
mc_setup
# shellcheck disable=SC2086
run sh $mc_args --format markdown --max-bytes 100
expect_rc 1
expect_out '| ConfigMap/preview-extra | tern-test-apps | in sync | create |'
expect_out '| Secret/stray | tern-test-apps | unmanaged | - |'
expect_out '| kind-tern-kube-dev | **1 resource drifted** (0 create, 1 modify, 0 delete; +1 -1), 1 unmanaged |'
expect_no_out '<details>'

for fmt in text markdown json; do
	fresh "two contexts $fmt: Secret values never reach the report"
	mc_setup
	cp "$here/cases/secret-last-applied.diff" "$FAKE_DIR/ctx/kind-tern-kube-dev2/diff"
	run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 --format "$fmt"
	expect_rc 1
	expect_no_out 'tern-kube-test-not-a-secret'
	expect_out '*** (last-applied-configuration redacted by tern-kube-drift)'
done

fresh "two contexts json: an unknown context is an error entry"
mc_setup
run sh -f a.yaml --context kind-tern-kube-dev --context nope --format json
expect_rc 2
expect_out '"summary":{"contexts":2,"drifted":1,"errors":1}'
expect_out '{"context":"nope","status":"error","error":"kubectl diff exited 1 without a diff: error: context \"nope\" does not exist","drift":null,"summary":null,"resources":[],"unmanaged":null,"notes":[]}'
expect_out '{"context":"nope","state":"error","added":null,"removed":null}'

fresh "two contexts: notes are tagged with their context"
mc_setup
cp "$here/cases/stray-truncated.diff" "$FAKE_DIR/ctx/kind-tern-kube-dev2/diff"
run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 --format text
expect_rc 1
expect_out '  [kind-tern-kube-dev2] Warning: something odd'
run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 --format markdown
expect_rc 1
expect_out '<summary>[kind-tern-kube-dev2] 4 notes</summary>'

fresh "two contexts markdown: context names are escaped"
mc_setup
mkdir -p "$FAKE_DIR/ctx/x<b>|y"
cp "$FAKE_DIR/ctx/kind-tern-kube-dev/diff" "$FAKE_DIR/ctx/kind-tern-kube-dev/diff.exit" \
	"$FAKE_DIR/ctx/kind-tern-kube-dev/manifest.tsv" "$FAKE_DIR/ctx/x<b>|y/"
run sh -f a.yaml --context kind-tern-kube-dev --context 'x<b>|y' --format markdown
expect_rc 1
expect_no_out '<b>'
expect_out '| Resource | Namespace | kind-tern-kube-dev | x&#60;b&#62;&#124;y |'
expect_out '| x&#60;b&#62;&#124;y | **1 resource drifted** (0 create, 1 modify, 0 delete; +1 -1) |'
expect_out '<summary>[x&#60;b&#62;&#124;y] modify ConfigMap tern-test-apps/app-config (+1 -1)</summary>'

# --- Export placeholders ---------------------------------------------------
# An export replaces Secret values with REPLACE_ME. kubectl diff masks every
# Secret value, so without the source's own listing a reviewer cannot tell
# "apply would write REPLACE_ME over the real password" from a real change.

placeholder_setup() {
	t=$(printf '\t')
	diff_from "$here/cases/secret-last-applied.diff"
	cat >"$FAKE_DIR/manifest.tsv" <<EOF
v1${t}Secret${t}tern-test-apps${t}app-secret${t}token,password,
v1${t}ConfigMap${t}tern-test-apps${t}app-config${t}
EOF
}

fresh "placeholders text: marked row, section, unmasked diff line, warning"
placeholder_setup
run sh -f a.yaml --format text
expect_rc 1
expect_argv "$listing_argv"
expect_out 'modify  Secret/app-secret  tern-test-apps  +1 -3  placeholders: password, token'
expect_out 'Warning: 1 Secret has placeholder values (REPLACE_ME) from an export: applying would overwrite the live values.'
expect_out 'placeholder values (password, token): REPLACE_ME from an export, applying would overwrite the live values'
expect_out "+  password: 'REPLACE_ME (placeholder)'"
expect_out "-  password: '*** (before)'"
expect_no_out "'*** (after)'"
expect_no_out 'tern-kube-test-not-a-secret'
expect_read_only

fresh "placeholders markdown"
placeholder_setup
run sh -f a.yaml --format markdown
expect_rc 1
expect_out '| modify | Secret/app-secret (placeholder values) | tern-test-apps | 1 | 3 |'
expect_out '**Warning:** 1 Secret has placeholder values (REPLACE_ME) from an export: applying would overwrite the live values.'
expect_out '<summary>modify Secret tern-test-apps/app-secret (+1 -3), placeholder values</summary>'
expect_out '**placeholder values (password, token): REPLACE_ME from an export, applying would overwrite the live values**'
expect_out "+  password: 'REPLACE_ME (placeholder)'"

fresh "placeholders json: only the Secret carries the field"
placeholder_setup
run sh -f a.yaml --format json
expect_rc 1
expect_out '"action":"modify","added":1,"removed":3,"binary":false,"lineCount":20,"truncated":false,"placeholders":["password","token"],"lines":['
expect_out "\"+  password: 'REPLACE_ME (placeholder)'\""
[ "$(grep -o '"placeholders"' "$root/out" | wc -l | tr -d ' ')" = 1 ] && ok || bad "want one placeholders field"

fresh "placeholders: a Secret the diff creates is flagged too"
diff_from "$here/cases/secret-create.diff"
printf 'v1\tSecret\tapps\tnew-creds\tpw,\n' >"$FAKE_DIR/manifest.tsv"
run sh -f a.yaml --format text
expect_rc 1
expect_out 'create  Secret/new-creds  apps       +9 -0  placeholders: pw'
expect_out "+  pw: 'REPLACE_ME (placeholder)'"
expect_out "+  user: '***'"

fresh "placeholders: without placeholder values nothing changes"
diff_from "$here/cases/secret-last-applied.diff"
printf 'v1\tSecret\ttern-test-apps\tapp-secret\t\n' >"$FAKE_DIR/manifest.tsv"
run sh -f a.yaml --format json
expect_rc 1
expect_no_out 'placeholder'

fresh "placeholders across two contexts"
mc_setup
cp "$here/cases/secret-last-applied.diff" "$FAKE_DIR/ctx/kind-tern-kube-dev2/diff"
printf 'v1\tSecret\ttern-test-apps\tapp-secret\tpassword,\n' >>"$FAKE_DIR/ctx/kind-tern-kube-dev2/manifest.tsv"
run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 --format text
expect_rc 1
expect_out 'Warning: 1 Secret has placeholder values (REPLACE_ME) from an export: applying would overwrite the live values.'
expect_out '=== [kind-tern-kube-dev2] modify Secret tern-test-apps/app-secret (+1 -3)'
expect_out "+  password: 'REPLACE_ME (placeholder)'"

# --- Target namespace missing on a context ---------------------------------
# kubectl diff aborts the whole run on the first object whose namespace does
# not exist (real kind: exit 2, no diff, `Error from server (NotFound):
# namespaces "X" not found`). That is drift (the namespace and its objects
# would be created), not an error: the CLI re-diffs the objects in existing
# namespaces and reports the others as create.

missing_setup() { # DIR
	t=$(printf '\t')
	cat >"$1/manifest.tsv" <<EOF
v1${t}ConfigMap${t}tern-test-apps${t}app-config${t}
rbac.authorization.k8s.io/v1${t}RoleBinding${t}gone${t}rb${t}
v1${t}Secret${t}gone2${t}creds${t}pw,
EOF
	cat >"$1/source.yaml" <<'EOF'
apiVersion: v1
data:
  LOG_LEVEL: debug
kind: ConfigMap
metadata:
  name: app-config
  namespace: tern-test-apps
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rb
  namespace: gone
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: r
subjects:
- kind: ServiceAccount
  name: x
  namespace: tern-test-apps
---
apiVersion: v1
kind: Secret
metadata:
  name: creds
  namespace: gone2
stringData:
  pw: REPLACE_ME
EOF
	: >"$1/diff"
	echo 2 >"$1/diff.exit"
	echo 'Error from server (NotFound): namespaces "gone" not found' >"$1/diff.err"
	: >"$1/diff.2"
	echo 2 >"$1/diff.2.exit"
	echo 'Error from server (NotFound): namespaces "gone2" not found' >"$1/diff.2.err"
	cp "$here/cases/mc-dev.diff" "$1/diff.3"
	echo 1 >"$1/diff.3.exit"
}

for s in $shells; do
	fresh "$s: missing namespaces: creates plus a note, exit 1"
	missing_setup "$FAKE_DIR"
	run "$s" -f a.yaml --context kind-tern-kube-dev --format text
	expect_rc 1
	expect_out 'modify  ConfigMap/app-config                      tern-test-apps  +1 -1'
	expect_out 'create  RoleBinding.rbac.authorization.k8s.io/rb  gone            +0 -0'
	expect_out 'create  Secret/creds                              gone2           +0 -0  placeholders: pw'
	expect_out '3 resources drifted (2 create, 1 modify, 0 delete; +1 -1).'
	expect_out '  namespace gone does not exist on context kind-tern-kube-dev: create it first (kubectl create namespace gone)'
	expect_out '  namespace gone2 does not exist on context kind-tern-kube-dev: create it first (kubectl create namespace gone2)'
	expect_out '=== create RoleBinding.rbac.authorization.k8s.io gone/rb (+0 -0)'
	expect_out '(namespace missing: whole object would be created)'
	expect_no_err 'kubectl diff failed'
	expect_argv "kubectl [--context] [kind-tern-kube-dev] [create] [--dry-run=client] [-f] [a.yaml] [-o] [yaml]"
	# Each re-diff drops the namespaces found missing so far, by the
	# object's own namespace (not the RoleBinding subject's).
	grep -q 'name: creds' "$FAKE_DIR/present.seen.2" && grep -q 'name: app-config' "$FAKE_DIR/present.seen.2" &&
		! grep -q 'name: rb' "$FAKE_DIR/present.seen.2" && ok || bad "second diff input: $(cat "$FAKE_DIR/present.seen.2")"
	grep -q 'name: rb' "$FAKE_DIR/present.seen.3" && bad "third diff still has gone/rb" || ok
	grep -q 'name: creds' "$FAKE_DIR/present.seen.3" && bad "third diff still has gone2/creds" || ok
	grep -q 'name: app-config' "$FAKE_DIR/present.seen.3" && ok || bad "third diff lost app-config"
	expect_read_only
done

fresh "missing namespaces json: create entries without diff lines"
missing_setup "$FAKE_DIR"
run sh -f a.yaml --format json
expect_rc 1
expect_out '{"key":"rbac.authorization.k8s.io.v1.RoleBinding.gone.rb","group":"rbac.authorization.k8s.io","version":"v1","kind":"RoleBinding","namespace":"gone","name":"rb","action":"create","added":0,"removed":0,"binary":false,"lineCount":0,"truncated":false,"lines":[]}'
expect_out '"action":"create","added":0,"removed":0,"binary":false,"lineCount":0,"truncated":false,"placeholders":["pw"],"lines":[]}'
expect_out '"notes":["namespace gone does not exist on context kind-tern-kube-dev: create it first (kubectl create namespace gone)","namespace gone2 does not exist on context kind-tern-kube-dev: create it first (kubectl create namespace gone2)"]'

fresh "missing namespaces markdown: no empty diff fence"
missing_setup "$FAKE_DIR"
run sh -f a.yaml --format markdown
expect_rc 1
expect_out '<summary>create RoleBinding.rbac.authorization.k8s.io gone/rb (+0 -0)</summary>'
expect_out '_(namespace missing: whole object would be created)_'
[ "$(grep -c '^```diff$' "$root/out")" = 1 ] && ok || bad "want one diff fence (app-config only)"

fresh "every object in a missing namespace: no re-diff, all create"
printf 'v1\tConfigMap\tgone\ta\t\n' >"$FAKE_DIR/manifest.tsv"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n  namespace: gone\n' >"$FAKE_DIR/source.yaml"
: >"$FAKE_DIR/diff"
echo 2 >"$FAKE_DIR/diff.exit"
echo 'Error from server (NotFound): namespaces "gone" not found' >"$FAKE_DIR/diff.err"
run sh -f a.yaml -n gone --format text
expect_rc 1
expect_out 'create  ConfigMap/a  gone       +0 -0'
[ "$(grep -c '\[diff\]' "$FAKE_DIR/argv")" = 1 ] && ok || bad "want a single diff: $(cat "$FAKE_DIR/argv")"

fresh "missing namespace, then another error: still exit 2"
missing_setup "$FAKE_DIR"
echo 'Error from server (Forbidden): configmaps "app-config" is forbidden' >"$FAKE_DIR/diff.2.err"
run sh -f a.yaml --format text
expect_rc 2
expect_err 'Error from server (Forbidden)'

fresh "missing namespace on one of two contexts: create cells, exit 1"
mc_setup
missing_setup "$FAKE_DIR/ctx/kind-tern-kube-dev"
run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-dev2 --format text
expect_rc 1
expect_out 'RoleBinding.rbac.authorization.k8s.io/rb  gone            create              -'
expect_out '  [kind-tern-kube-dev] namespace gone does not exist on context kind-tern-kube-dev: create it first (kubectl create namespace gone)'
expect_out 'kind-tern-kube-dev: 3 resources drifted (2 create, 1 modify, 0 delete; +1 -1).'

# --- Error reasons ---------------------------------------------------------
# client-go logs (klog) after the real error, so the last stderr line is
# often noise: the reason must be the last line that is not a klog line.

fresh "a failed context's reason skips klog lines"
mc_setup
mc_down kind-tern-kube-down
cat >>"$FAKE_DIR/ctx/kind-tern-kube-down/diff.err" <<'EOF'
E1110 10:00:00.123456   12345 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list"
I1110 10:00:00.223456   12345 request.go:1000] retrying
EOF
run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-down --format text
expect_rc 2
expect_out 'kind-tern-kube-down: error: kubectl diff exited 1 without a diff: Unable to connect to the server: dial tcp 127.0.0.1:1: connect: connection refused'

fresh "only klog lines: the last one is the reason"
mc_setup
mkdir -p "$FAKE_DIR/ctx/kind-tern-kube-down"
: >"$FAKE_DIR/ctx/kind-tern-kube-down/diff"
echo 1 >"$FAKE_DIR/ctx/kind-tern-kube-down/diff.exit"
printf '%s\n' 'E1110 10:00:00.123456   12345 a.go:1] first' 'E1110 10:00:00.223456   12345 b.go:2] second' >"$FAKE_DIR/ctx/kind-tern-kube-down/diff.err"
run sh -f a.yaml --context kind-tern-kube-dev --context kind-tern-kube-down --format text
expect_rc 2
expect_out 'kind-tern-kube-down: error: kubectl diff exited 1 without a diff: E1110 10:00:00.223456   12345 b.go:2] second'

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" = 0 ]
