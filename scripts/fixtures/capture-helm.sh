#!/bin/sh
# Captures real Helm 3 output for the Helm specs into
# tests/fixtures/helm/captured/. Recreates namespace tern-test-helm in the
# kind test cluster (context kind-tern-kube-dev; nothing else is touched),
# installs throwaway releases, records list/history/status/values/manifest/
# hooks/extras output, a rollback dry run and a kubectl diff, then deletes
# the namespace with everything in it (KEEP=1 keeps it). Values are fake
# (`*-REDACTME`); the specs check that they never reach a rendered view
# unmasked.
#
# Reruns are idempotent: what changes between runs (times, uids,
# resourceVersions, cluster IPs, kubectl's temp dirs, live Deployment
# status, the cluster CA) is replaced with stable stand-ins that keep order
# and equality, so a rerun rewrites the same bytes unless helm or the
# cluster behave differently.
set -eu

cd "$(dirname "$0")/../.."

HELM=${HELM:-.tools/bin/helm}
KUBECTL=${KUBECTL:-kubectl}
LUAU=${LUAU:-.tools/bin/luau}
CTX=kind-tern-kube-dev
NS=tern-test-helm
SHOP=${SHOP_CHART:-tests/fixtures/gitops/helm/chart}
STAGING=${STAGING_VALUES:-tests/fixtures/gitops/helm/values-staging.yaml}
WEB=${WEB_CHART:-tests/fixtures/helm/web}
OUT=${OUT:-tests/fixtures/helm/captured}

export KUBECONFIG="$PWD/.sandbox/kubeconfig"
# helm records times in the local zone; UTC keeps the fixtures independent
# of the machine that captured them.
export TZ=UTC
tmp=$(mktemp -d /tmp/tk-helm-capture.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
# Never read or write the user's Helm repositories, registry logins or cache.
export HELM_CONFIG_HOME="$tmp/helm/config" HELM_CACHE_HOME="$tmp/helm/cache" HELM_DATA_HOME="$tmp/helm/data"

[ -x "$HELM" ] || {
	echo "capture-helm: $HELM missing; run 'make bootstrap'" >&2
	exit 1
}
[ "$("$KUBECTL" config current-context)" = "$CTX" ] || {
	echo "capture-helm: refusing: $KUBECONFIG is not the kind test cluster ($CTX)" >&2
	exit 1
}

h() { "$HELM" --kube-context "$CTX" -n "$NS" "$@"; }
k() { "$KUBECTL" --context "$CTX" "$@"; }
# One helm write, then a pause: every revision's last_deployed falls in its
# own second, which is how normalize() maps list.json's second-precision
# times back to revisions.
w() {
	h "$@" >/dev/null
	sleep 1
}

if [ -n "${TEMPLATE_FILE:-}" ]; then
	cp "$TEMPLATE_FILE" "$tmp/extras.tpl"
else
	"$LUAU" scripts/fixtures/helm-template.luau >"$tmp/extras.tpl"
fi
extras=$(cat "$tmp/extras.tpl")

# A fresh namespace: nothing left by an earlier (or failed) run can change
# what this one records.
if k get namespace "$NS" >/dev/null 2>&1; then
	k delete namespace "$NS" --wait=true --timeout=180s >/dev/null
fi
k create namespace "$NS" >/dev/null

w install shop-a "$SHOP"
w upgrade shop-a "$SHOP" -f "$STAGING"
w upgrade shop-a "$SHOP" --reuse-values --set image.tag=1.27.3-alpine

# web-b: notes, hooks, a Secret; a chart version bump, then a rollback.
w install web-b "$WEB" --set auth.password=hunter2-REDACTME --set-string auth.apiToken=tok-REDACTME
"$HELM" package "$WEB" --version 0.2.1 --app-version 2.1 -d "$tmp" >/dev/null
w upgrade web-b "$tmp/web-0.2.1.tgz" --reuse-values --set config.mode=canary --description "canary rollout"
w rollback web-b 1

# broken-c: the API server rejects the Service; the release is recorded failed.
h install broken-c "$SHOP" --set service.port=99999 >/dev/null 2>&1 || true
sleep 1

# stuck-d: an upgrade killed mid-flight stays pending-upgrade forever. It is
# killed only once the new image is applied (helm is then waiting), so the
# Deployment is the same on every run.
w install stuck-d "$SHOP"
h upgrade stuck-d "$SHOP" --set image.tag=does-not-exist --wait --timeout 2m >/dev/null 2>&1 &
pid=$!
i=0
until [ "$(k -n "$NS" get deployment stuck-d-shop -o 'jsonpath={.spec.template.spec.containers[0].image}')" = nginx:does-not-exist ] &&
	h history stuck-d -o json | grep -q '"pending-upgrade"'; do
	i=$((i + 1))
	[ "$i" -lt 100 ] || {
		echo "capture-helm: stuck-d never reached pending-upgrade with the new image" >&2
		exit 1
	}
	sleep 0.2
done
kill -9 "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
sleep 1

# tricky-e: values Go's %+q quotes in ways JSON does not accept (\a, \x00,
# \U0001f600), lists, null, big numbers. --reuse-values copies them into
# revision 2's stored chart defaults, which only the extras template reads.
w install tricky-e "$SHOP" -f "${TRICKY_VALUES:-tests/fixtures/helm/values-tricky.yaml}"
w upgrade tricky-e "$SHOP" --reuse-values --set config.mode=reused

mkdir -p "$OUT"
rm -f "$OUT"/*.json "$OUT"/*.yaml "$OUT"/*.txt "$OUT"/*.tpl "$OUT"/*.norm
TIME=2006-01-02T15:04:05Z07:00
h list -a -o json --time-format "$TIME" >"$OUT/list.json"
h list -a -o json >"$OUT/list-default-time.json"

capture() { # release revisions...
	rel=$1
	shift
	h history "$rel" -o json >"$OUT/history-$rel.json"
	for n in "$@"; do
		h status "$rel" --revision "$n" -o json >"$OUT/status-$rel-r$n.json"
		h get all "$rel" --revision "$n" --template "$extras" >"$OUT/extras-$rel-r$n.txt"
		h get values "$rel" --revision "$n" -o json >"$OUT/values-$rel-r$n.json"
		h get values "$rel" --revision "$n" --all -o json >"$OUT/values-all-$rel-r$n.json"
		h get manifest "$rel" --revision "$n" >"$OUT/manifest-$rel-r$n.yaml"
	done
}
capture shop-a 1 2 3
capture web-b 1 2 3
capture broken-c 1
capture stuck-d 1 2
capture tricky-e 1 2
h get hooks web-b --revision 3 >"$OUT/hooks-web-b-r3.yaml"
h get notes web-b --revision 2 >"$OUT/notes-web-b-r2.txt"
h history shop-a --max 1 -o json >"$OUT/history-shop-a-max1.json"

run() { # file argv...
	file=$1
	shift
	set +e
	"$@" >"$OUT/$file" 2>&1
	code=$?
	set -e
	printf 'exit=%s\n' "$code" >>"$OUT/$file"
}
run rollback-dry-run-shop-a-1.txt h rollback shop-a 1 --dry-run
run rollback-dry-run-shop-a-99.txt h rollback shop-a 99 --dry-run
run rollback-dry-run-stuck-d-1.txt h rollback stuck-d 1 --dry-run
# What the approve block runs for a rollback of shop-a to 1: the target
# revision's manifest against the live objects.
h get manifest shop-a --revision 1 >"$tmp/target.yaml"
run kubectl-diff-shop-a-r1.txt env KUBECTL_EXTERNAL_DIFF= "$KUBECTL" --context "$CTX" -n "$NS" diff -f "$tmp/target.yaml"

# Live objects without the release records (their payload is the whole
# release, values included); record names only.
k -n "$NS" get deployments,services,configmaps,secrets -l 'owner!=helm' -o json >"$OUT/objects.json"
k -n "$NS" get secrets -l owner=helm -o name >"$OUT/release-records.txt"

{
	printf 'helm: %s\n' "$("$HELM" version --short)"
	printf 'kubectl: %s\n' "$("$KUBECTL" version --client 2>/dev/null | head -n 1)"
	printf 'server: %s\n' "$(k version 2>/dev/null | grep '^Server Version')"
} >"$OUT/VERSIONS.txt"

# Stable stand-ins, same input -> same output:
# - helm's times (RFC 3339 with fraction, Go time.String()) by rank:
#   2026-01-01 plus <rank> minutes, fraction .123456;
# - list.json's second-precision times as the revision whose history time
#   has that second (unique thanks to w()'s pause);
# - API-server times (objects, kubectl diff) as 2026-01-01T00:00:00Z;
# - uids, resourceVersions and IPv4 addresses by order of appearance;
# - kubectl diff's temp dirs and file times; item-level `status` in
#   objects.json (it depends on how far the rollouts got); the cluster CA.
normalize() {
	awk '
	function rep(c, n,    s) { s = ""; while (n-- > 0) s = s c; return s }
	function base(f) { sub(/.*\//, "", f); return f }
	function kube(f) { return f == "objects.json" || f ~ /^kubectl-diff/ || f == "release-records.txt" }
	function key(ts,    f) {
		f = ""
		if (substr(ts, 20, 1) == ".") { f = substr(ts, 21); sub(/[^0-9].*$/, "", f) }
		while (length(f) < 9) f = f "0"
		return substr(ts, 1, 10) "T" substr(ts, 12, 8) "." f
	}
	function stamp(r) { return sprintf("2026-01-01T%02d:%02d:00", int(r / 60), r % 60) }
	function ranked(ts,    k) {
		k = key(ts)
		if (!(k in rank)) { printf "capture-helm: unranked time %s in %s\n", ts, FILENAME > "/dev/stderr"; exit 1 }
		return stamp(rank[k])
	}
	function collect(line, re,    k, s) {
		while (match(line, re)) {
			k = key(substr(line, RSTART, RLENGTH))
			times[k] = 1
			if (FILENAME ~ /history-[^\/]*\.json$/) {
				s = substr(k, 1, 19)
				if ((s in second) && second[s] != k) {
					printf "capture-helm: two revisions updated within second %s; rerun\n", s > "/dev/stderr"
					exit 1
				}
				second[s] = k
			}
			line = substr(line, RSTART + RLENGTH)
		}
	}
	function repl(kind, m,    s, n) {
		if (kind == "frac") return ranked(m) ".123456Z"
		if (kind == "go") { s = ranked(m); return substr(s, 1, 10) " " substr(s, 12) ".123456 +0000 UTC" }
		if (kind == "sec") {
			if (kube(file)) return "2026-01-01T00:00:00Z"
			if (file == "list.json") {
				s = substr(key(m), 1, 19)
				if (!(s in second)) { printf "capture-helm: no revision updated at %s\n", m > "/dev/stderr"; exit 1 }
				return substr(stamp(rank[second[s]]), 1, 19) "Z"
			}
			return ranked(m) "Z"
		}
		if (kind == "uid") { if (!(m in uids)) uids[m] = sprintf("00000000-0000-4000-8000-%012d", ++nuid); return uids[m] }
		if (kind == "ip") { if (!(m in ips)) ips[m] = "10.96.0." (++nip + 10); return ips[m] }
		if (kind == "rv") {
			n = m; sub(/^[^0-9]*/, "", n); sub(/"$/, "", n)
			if (!(n in rvs)) rvs[n] = ++nrv
			sub(/[0-9]+"$/, rvs[n] "\"", m)
			return m
		}
	}
	function subst(line, re, kind,    out) {
		out = ""
		while (match(line, re)) {
			out = out substr(line, 1, RSTART - 1) repl(kind, substr(line, RSTART, RLENGTH))
			line = substr(line, RSTART + RLENGTH)
		}
		return out line
	}
	BEGIN {
		D = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
		T = "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
		FRAC = D "T" T "\\.[0-9]+Z"
		SEC = D "T" T "Z"
		GO = D " " T "(\\.[0-9]+)? \\+0000 UTC"
		H = "[0-9a-f]"
		UID = rep(H, 8) "-" rep(H, 4) "-" rep(H, 4) "-" rep(H, 4) "-" rep(H, 12)
		IP = "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"
		RV = "resourceVersion\"?: \"[0-9]+\""
	}
	pass == 1 {
		file = base(FILENAME)
		if (kube(file)) next
		collect($0, FRAC); collect($0, GO)
		if (file != "list.json") collect($0, SEC)
		next
	}
	pass == 2 && !sorted {
		n = 0
		for (k in times) all[++n] = k
		for (i = 2; i <= n; i++) { v = all[i]; for (j = i - 1; j > 0 && all[j] > v; j--) all[j + 1] = all[j]; all[j + 1] = v }
		for (i = 1; i <= n; i++) rank[all[i]] = i
		sorted = 1
	}
	pass == 2 {
		if (FNR == 1) { if (out != "") close(out); file = base(FILENAME); out = FILENAME ".norm"; skip = 0 }
		line = $0
		if (skip) { if (line == "            }") skip = 0; next }
		if (file == "objects.json" && line == "            \"status\": {") { print "            \"status\": {}" > out; skip = 1; next }
		if (file == "objects.json" && line ~ /"ca\.crt": "/) sub(/"ca\.crt": ".*"/, "\"ca.crt\": \"REDACTED\"", line)
		if (file ~ /^kubectl-diff/) {
			gsub(/[^ \t]*\/LIVE-[0-9]+\//, "/tmp/LIVE/", line)
			gsub(/[^ \t]*\/MERGED-[0-9]+\//, "/tmp/MERGED/", line)
			if (line ~ /^(---|\+\+\+) / && index(line, "\t") > 0) line = substr(line, 1, index(line, "\t")) "2026-01-01 00:00:00"
		}
		line = subst(line, FRAC, "frac")
		line = subst(line, GO, "go")
		line = subst(line, SEC, "sec")
		line = subst(line, UID, "uid")
		line = subst(line, RV, "rv")
		if (kube(file)) line = subst(line, IP, "ip")
		print line > out
	}
	' pass=1 "$@" pass=2 "$@"
	for f in "$@"; do
		[ -f "$f.norm" ] || continue
		# awk ends every line with a newline; keep files that had none (the
		# extras template output) byte-identical in that respect.
		if [ -n "$(tail -c 1 "$f")" ]; then
			printf '%s' "$(cat "$f.norm")" >"$f"
			rm -f "$f.norm"
		else
			mv "$f.norm" "$f"
		fi
	done
}
normalize "$OUT"/*.json "$OUT"/*.yaml "$OUT"/*.txt
# The template these extras-* files came from; a spec compares it with the
# plugin's (not normalized: it contains Go time layouts).
cp "$tmp/extras.tpl" "$OUT/extras.tpl"

if [ "${KEEP:-0}" != 1 ]; then
	k delete namespace "$NS" --wait=true --timeout=180s >/dev/null
fi
echo "capture-helm: wrote $OUT"
