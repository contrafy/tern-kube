#!/bin/sh
# A disposable Linux host (Debian 13 container with sshd, tests/remote/
# Dockerfile) for tern-kube's remote tests. It joins the docker network
# `kind`, so its kubectl reaches the disposable cluster tern-kube-dev, and is
# registered as a Tern remote host of the sandbox in TK_TERN_SANDBOX (same
# /tmp rule as scripts/dev-tern.sh; that sandbox's window then opens it).
#
#   up [--shell fish|bash|zsh]  build the image, start a fresh container
#                     (login shell of user tk; default fish), register it
#                     with `tern remote setup`, print the host name
#   attach            register the running container with TK_TERN_SANDBOX
#                     again (a new sandbox, e.g. scripts/e2e.sh's)
#   install [DIR]     copy a plugin snapshot (plugin.toml, plugin/, shell/ of
#                     DIR, default the repo) to the host and `tern plugin
#                     link` it there
#   run               run stdin with `sh -s` on the host as tk (never in the
#                     login shell's syntax)
#   suites            run tests/shell/{guard,drift,aliases,login} on the host
#   status            container, sshd, `tern remote doctor`, remote Tern
#                     version, serve process and plugins; exit 1 unless usable
#   down [--purge]    remove the container and drop the host from the
#                     sandbox's hosts and known_hosts; --purge also removes
#                     the cached Tern build (volume) and the images
#   env               TK_REMOTE_NAME, TK_REMOTE_SSH, TK_REMOTE_PATH and
#                     TK_REMOTE_SHELL as shell assignments
#
# ssh never reads or writes ~/.ssh: TK_REMOTE_DIR (default /tmp/tk-remote)
# holds the key pair, ssh_config, known_hosts and bin/ssh, a wrapper that
# runs ssh with that config; local `tern` calls get it first on PATH, the
# sandbox environment and no SSH_AUTH_SOCK. Remote `tern` calls (`plugin
# link`, `list`, `--version`) run only inside the container this script
# made. Needs internet: Tern downloads its Linux build on the host, and the
# window reaches the host through the iroh relay.

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
dir=${TK_REMOTE_DIR:-/tmp/tk-remote}
port=${TK_REMOTE_PORT:-2222}
container=${TK_REMOTE_CONTAINER:-tern-kube-remote}
volume=$container-tern
tern_bin=${TERN_BIN:-tern}
label=dev.tern-kube.remote-host
user=tk
name=$user@localhost:$port

die() {
	echo "remote-host: $*" >&2
	exit 1
}

case $dir in
/tmp/?* | /private/tmp/?*) ;;
*)
	echo "remote-host: refusing state dir outside /tmp: $dir" >&2
	exit 2
	;;
esac

ssh_run() { # ARGS...: the isolated ssh to the container's user
	"$dir/bin/ssh" -p "$port" -T "$user@localhost" "$@"
}

# Remote commands are scripts on stdin of `sh -s`: the login shell (fish,
# say) only parses those two words.
rsh() {
	ssh_run sh -s
}

need_sandbox() {
	[ -n "${TK_TERN_SANDBOX:-}" ] || die "TK_TERN_SANDBOX is not set (the sandbox whose window opens the host)"
	sandbox_env=$(sh "$repo/scripts/dev-tern.sh" env | grep -E '^(TERN_CONFIG_DIR|TERN_DAEMON_SOCKET|STENCIL_LOG_DIR)=') ||
		exit 2
	hosts_file=$TK_TERN_SANDBOX/cfg/hosts
}

# The sandbox's tern with the isolated ssh first on PATH.
tern_sb() {
	# shellcheck disable=SC2086
	env -u SSH_AUTH_SOCK PATH="$dir/bin:$PATH" STENCIL_LOG=warn $sandbox_env "$tern_bin" "$@"
}

container_label() { # KEY: a label of the container ("" when absent)
	docker inspect -f "{{index .Config.Labels \"$1\"}}" "$container" 2>/dev/null || true
}

ours() {
	[ "$(container_label "$label")" = "$dir" ]
}

running() {
	[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ]
}

need_up() {
	if ! running || ! ours; then
		die "container $container is not running (remote-host.sh up)"
	fi
}

# pack PATHS...: a gzip tarball of repo-relative PATHS of $src, as base64
# lines for a heredoc (no macOS xattrs: GNU tar warns about each one).
pack() {
	(cd "$src" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf - "$@") | base64
}

write_ssh() {
	mkdir -p "$dir/bin"
	[ -f "$dir/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C tern-kube-remote -f "$dir/id_ed25519"
	cat >"$dir/ssh_config" <<EOF
Host *
  IdentityFile $dir/id_ed25519
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $dir/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking accept-new
  BatchMode yes
  ConnectTimeout 10
  ControlMaster no
  ControlPath none
  LogLevel ERROR
EOF
	# The log shows which ssh Tern ran (this wrapper, not ~/.ssh's).
	cat >"$dir/bin/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$dir/ssh.log'
exec /usr/bin/ssh -F '$dir/ssh_config' "\$@"
EOF
	chmod 0755 "$dir/bin/ssh"
}

# The endpoint-id spelling of the host in the sandbox's hosts file.
host_id() {
	[ -f "$hosts_file" ] || return 0
	awk -F '\t' -v n="$name" '$2 == n { print $1; exit }' "$hosts_file"
}

# Drop the host from the sandbox: hosts line and Tern's host key pin.
forget_host() {
	[ -f "$hosts_file" ] || return 0
	id=$(host_id)
	awk -F '\t' -v n="$name" '$1 != n && $2 != n' "$hosts_file" >"$hosts_file.new"
	mv "$hosts_file.new" "$hosts_file"
	kh=$TK_TERN_SANDBOX/cfg/known_hosts
	if [ -n "$id" ] && [ -f "$kh" ]; then
		awk -v id="${id#*@}" 'index($0, id) == 0' "$kh" >"$kh.new"
		mv "$kh.new" "$kh"
	fi
}

wait_sshd() {
	i=0
	until ssh_run true </dev/null 2>/dev/null; do
		i=$((i + 1))
		[ $i -ge 40 ] && die "sshd in $container does not answer on 127.0.0.1:$port"
		sleep 0.5
	done
}

attach() {
	need_up
	forget_host
	# Tern's setup logs in with the device key of the sandbox, else the key
	# in ssh_config, and lets its device key in.
	tern_sb remote setup "$name" 2>&1 | tee "$dir/setup.log"
	[ -n "$(host_id)" ] || die "tern remote setup did not add $name to $hosts_file (see $dir/setup.log)"
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case $cmd in
up)
	shell=fish
	while [ $# -gt 0 ]; do
		case $1 in
		--shell)
			shell=${2:-}
			[ $# -gt 1 ] && shift
			;;
		*) die "up [--shell fish|bash|zsh]" ;;
		esac
		shift
	done
	case $shell in
	fish | bash | zsh) ;;
	*) die "--shell must be fish, bash or zsh, not '$shell'" ;;
	esac
	need_sandbox
	command -v docker >/dev/null 2>&1 || die "docker is required"
	docker network inspect kind >/dev/null 2>&1 || die "no docker network 'kind' (scripts/cluster.sh create)"
	mkdir -p "$dir"
	"$repo/.tools/bin/kind" get kubeconfig --internal --name tern-kube-dev >"$dir/kubeconfig" ||
		die "no kind cluster tern-kube-dev (scripts/cluster.sh create)"
	grep -qx 'current-context: kind-tern-kube-dev' "$dir/kubeconfig" ||
		die "refusing: the kind kubeconfig is not context kind-tern-kube-dev"
	curl -sS -m 10 -o /dev/null https://iroh.stencil.so 2>/dev/null ||
		echo "remote-host: warning: the iroh relay iroh.stencil.so does not answer; the window may not reach the host" >&2
	write_ssh
	if docker inspect "$container" >/dev/null 2>&1; then
		ours || die "a container named $container exists and was not made by this script for $dir; not touching it"
		docker rm -f "$container" >/dev/null
	fi
	image=tern-kube-remote:$shell
	docker build -q --label "$label=1" --build-arg "SHELL_NAME=$shell" -t "$image" "$repo/tests/remote" >/dev/null
	docker volume create --label "$label=1" "$volume" >/dev/null
	docker run -d --name "$container" --hostname tk-remote --network kind \
		--label "$label=$dir" --label "$label.shell=$shell" \
		-p "127.0.0.1:$port:22" -v "$volume:/home/$user/.local/share/tern" "$image" >/dev/null
	docker exec -i "$container" sh -c "cat >/home/$user/.ssh/authorized_keys && chown $user:$user /home/$user/.ssh/authorized_keys && chmod 600 /home/$user/.ssh/authorized_keys" <"$dir/id_ed25519.pub"
	docker exec -i "$container" sh -c "cat >/home/$user/.kube/config && chown -R $user:$user /home/$user/.kube && chmod 600 /home/$user/.kube/config" <"$dir/kubeconfig"
	# The volume keeps the Tern build of an earlier container; with its link
	# back in place, setup finds Tern installed and skips the download.
	docker exec -u "$user" "$container" sh -c "[ -x \$HOME/.local/share/tern/build/tern ] && ln -sfn \$HOME/.local/share/tern/build/tern \$HOME/.local/bin/tern || true"
	# A fresh container has fresh host keys.
	[ -f "$dir/known_hosts" ] && ssh-keygen -q -R "[localhost]:$port" -f "$dir/known_hosts" >/dev/null 2>&1
	rm -f "$dir/known_hosts.old"
	wait_sshd
	attach
	echo "$name"
	;;
attach)
	need_sandbox
	attach
	echo "$name"
	;;
install)
	src=$(CDPATH='' cd -- "${1:-$repo}" && pwd)
	[ -f "$src/plugin.toml" ] && [ -d "$src/plugin" ] && [ -d "$src/shell" ] ||
		die "$src has no plugin.toml, plugin/ and shell/"
	need_up
	{
		cat <<'EOF'
set -eu
t=$HOME/.local/bin/tern
[ -x "$t" ] || { echo "remote-host: no Tern on the host yet (remote-host.sh up)" >&2; exit 1; }
pkg=$HOME/tern-kube-pkg
rm -rf "$pkg.new"
mkdir -p "$pkg.new"
base64 -d <<'TK_PKG_EOF' | tar -xzf - -C "$pkg.new"
EOF
		pack plugin.toml plugin shell
		cat <<'EOF'
TK_PKG_EOF
rm -rf "$pkg"
mv "$pkg.new" "$pkg"
"$t" plugin link "$pkg"
EOF
	} | rsh
	;;
run)
	case ${1:--} in
	-) ;;
	*) die "run: the script comes on stdin (remote-host.sh run < script)" ;;
	esac
	need_up
	rsh
	;;
suites)
	need_up
	{
		cat <<'EOF'
set -u
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
base64 -d <<'TK_SRC_EOF' | tar -xzf - -C "$w"
EOF
		src=$repo
		pack .luaurc Makefile plugin.toml bin plugin scripts shell tests/shell tests/lib tests/fixtures/drift tests/fixtures/real/mutate-preview
		cat <<'EOF'
TK_SRC_EOF
cd "$w"
rc=0
for s in guard drift aliases login; do
	[ -f "tests/shell/$s/run.sh" ] || { echo "suite $s: not in this checkout"; continue; }
	echo "suite $s"
	LUAU=/usr/local/bin/luau sh "tests/shell/$s/run.sh" || rc=1
done
exit $rc
EOF
	} | rsh
	;;
status)
	need_sandbox
	rc=0
	if running && ours; then
		echo "container: $container running ($(container_label "$label.shell") login shell, 127.0.0.1:$port)"
	else
		echo "container: $container not running"
		exit 1
	fi
	if ssh_run true </dev/null 2>/dev/null; then
		echo "sshd: ok ($name)"
	else
		echo "sshd: no answer on 127.0.0.1:$port"
		exit 1
	fi
	rsh <<'EOF' || rc=1
t=$HOME/.local/bin/tern
echo "host: $(uname -sm), login shell $(getent passwd "$(id -un)" | cut -d: -f7)"
[ -x "$t" ] || { echo "tern: not installed"; exit 1; }
echo "tern: $("$t" --version)"
if pgrep -f 'tern remote serve' >/dev/null; then echo "serve: running"; else echo "serve: STOPPED (remote-host.sh up recreates the host)"; exit 1; fi
if pgrep -f 'tern daemon' >/dev/null; then echo "daemon: running"; else echo "daemon: not started (a window attaches it)"; fi
echo "plugins:"
"$t" plugin list 2>&1 | sed 's/^/  /'
EOF
	id=$(host_id)
	if [ -z "$id" ]; then
		echo "sandbox: $name is not a host of $TK_TERN_SANDBOX (remote-host.sh attach)"
		exit 1
	fi
	if tern_sb remote doctor "$id" >"$dir/doctor.log" 2>&1; then
		echo "doctor: ok ($id)"
	else
		echo "doctor: FAILED ($id):"
		sed 's/^/  /' "$dir/doctor.log"
		rc=1
	fi
	exit $rc
	;;
down)
	purge=0
	case ${1:-} in
	--purge) purge=1 ;;
	'') ;;
	*) die "down [--purge]" ;;
	esac
	if docker inspect "$container" >/dev/null 2>&1; then
		ours || die "container $container was not made by this script for $dir; not touching it"
		docker rm -f "$container" >/dev/null
		echo "removed container $container"
	fi
	if [ -n "${TK_TERN_SANDBOX:-}" ]; then
		need_sandbox
		forget_host
	fi
	[ -f "$dir/known_hosts" ] && ssh-keygen -q -R "[localhost]:$port" -f "$dir/known_hosts" >/dev/null 2>&1
	rm -f "$dir/known_hosts.old"
	if [ $purge = 1 ]; then
		docker volume rm "$volume" >/dev/null 2>&1 && echo "removed volume $volume"
		for s in fish bash zsh; do
			docker image rm "tern-kube-remote:$s" >/dev/null 2>&1 && echo "removed image tern-kube-remote:$s"
		done
		rm -rf "$dir"
	fi
	true
	;;
env)
	shell=$(container_label "$label.shell")
	# Single-quoted for eval; none of the values can hold a quote.
	printf "TK_REMOTE_NAME='%s'\nTK_REMOTE_SSH='%s'\nTK_REMOTE_PATH='%s'\nTK_REMOTE_SHELL='%s'\n" \
		"$name" "$dir/bin/ssh -p $port $user@localhost" "$dir/bin" "${shell:-}"
	;;
*)
	sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
	[ -z "$cmd" ] && exit 0
	exit 2
	;;
esac
