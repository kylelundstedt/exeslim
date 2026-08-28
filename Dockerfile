# exeslim — a minimal exe.dev base image for deployment targets.
#
# exeuntu is deliberately a batteries-included agent workstation: it runs
# `unminimize`, reinstalls every package to restore man pages, then pulls in
# locales-all, ubuntu-server/standard/dev-tools, build-essential, Chrome + the
# GTK stack, ffmpeg, imagemagick, mitmproxy, docker, Go, uv, and the Claude /
# Codex / pi agents. That lands at ~3.4 GB before your app. Correct for a box
# where an agent might need anything; pure overhead for one static binary.
#
# This image drops all of that but keeps every piece of exe.dev *platform*
# wiring, correlated line-by-line against exeuntu's Dockerfile.
#
# NOT for interactive/agent VMs — no compiler, no python, no docker, no git.
# Use exeuntu for those.

FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

RUN apt-get update \
	# Pull security/bugfix updates for packages already in the base layer.
	# Without this we ship whatever was current when Canonical last rebuilt
	# ubuntu:24.04, which can be months behind — and since the packages we
	# install by name are only a handful, everything else would stay stale
	# no matter how often the weekly job reruns. Same reasoning as exeuntu.
	&& DEBIAN_FRONTEND=noninteractive apt-get -y \
		-o Dpkg::Options::=--force-confold \
		-o Dpkg::Options::=--force-confdef \
		dist-upgrade \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		systemd systemd-sysv dbus dbus-user-session \
		ca-certificates curl \
		# iproute2 for `ss`. ~1 MB, and it is the difference between seeing
		# and guessing when a unit is active but the proxy returns nothing —
		# 0.0.0.0:8000 (proxy can reach it) vs 127.0.0.1:8000 (it cannot).
		iproute2 \
		sudo tzdata locales \
		# jq for iv-tailnet-join below (~1 MB). curl is already here.
		jq \
	# en_US + en_GB only; exeuntu installs locales-all, which is ~200 MB.
	# en_US.UTF-8 is the default as the least surprising for anyone else who
	# lands on the box. See the ENV LANG note below for how to override.
	&& locale-gen en_US.UTF-8 en_GB.UTF-8 \
	&& update-locale LANG=en_US.UTF-8 \
	# The base image ships policy-rc.d to stop services starting during build.
	# We run systemd at runtime, so it must go or apt-installed services will
	# silently fail to start on the VM.
	&& rm -f /usr/sbin/policy-rc.d \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# --- systemd, tuned for exe.dev's container-as-VM environment -----------------
# Units that hang, fail noisily, or fight the platform. Masking is safe for
# units that aren't installed, so this list can stay close to exeuntu's.
# NB: ssh.service/ssh.socket are masked because exe.dev supplies its own sshd
# from /exe.dev/bin — a distro sshd would contend for :22.
RUN systemctl mask -- \
		getty.target \
		console-getty.service \
		keyboard-setup.service \
		ssh.service \
		ssh.socket \
		systemd-resolved.service \
		systemd-remount-fs.service \
		systemd-sysusers.service \
		systemd-update-done.service \
		systemd-update-utmp.service \
		systemd-journal-catalog-update.service \
		systemd-random-seed.service \
		systemd-modules-load.service \
		modprobe@.service \
		systemd-udevd.service \
		systemd-udevd-control.socket \
		systemd-udevd-kernel.socket \
		systemd-udev-trigger.service \
		systemd-udev-settle.service \
		systemd-hwdb-update.service \
		systemd-ask-password-console.path \
		systemd-ask-password-wall.path \
		ldconfig.service \
		man-db.timer \
		dpkg-db-backup.timer \
		e2scrub_all.timer \
		apt-daily.timer \
		apt-daily-upgrade.timer \
		unattended-upgrades.service \
		iscsid.socket \
		dm-event.socket \
		ubuntu-fan.service \
		-.mount \
		etc-resolv.conf.mount \
		etc-hosts.mount \
		etc-hostname.mount \
	# systemd-logind is disabled but NOT masked — per exeuntu, it is involved
	# in populating the XDG runtime dir sockets.
	# Braces keep `|| true` bound to the disable alone, so a failed mask above
	# still aborts the build.
	&& { systemctl disable systemd-logind.service || true; } \
	&& { systemctl disable systemd-machine-id-commit.service systemd-firstboot.service systemd-sysctl.service || true; } \
	&& mkdir -p /etc/systemd/system.conf.d \
	&& printf '[Manager]\nLogLevel=info\nLogTarget=console\nSystemCallArchitectures=native\nDefaultOOMPolicy=continue\n' \
		>/etc/systemd/system.conf.d/container-overrides.conf \
	# Keep journals across reboots — `journalctl -u <svc>` is the only real
	# debugging surface on a box with no toolchain.
	&& mkdir -p /etc/systemd/journald.conf.d \
	&& printf '[Journal]\nStorage=persistent\n' \
		>/etc/systemd/journald.conf.d/persistent.conf \
	&& systemctl set-default multi-user.target

# CRITICAL: without this, systemd-growfs@-.service never runs and the root
# filesystem stays at its original size when the disk is grown — so
# `new --disk=50GB` or `resize` silently gives you an unexpanded fs.
RUN echo '/dev/vda / ext4 defaults,x-systemd.growfs 0 1' >/etc/fstab

# Stop systemd wiping /tmp at boot; it races non-systemd users that run at boot.
COPY tmpfiles-tmp.conf /etc/tmpfiles.d/tmp.conf

# Makes `new --setup-script` work. Without this unit the flag is accepted and
# then silently does nothing.
COPY exe-setup.service /etc/systemd/system/exe-setup.service
RUN chmod 644 /etc/systemd/system/exe-setup.service \
	&& systemctl enable exe-setup.service

# --- in-place OS patching -----------------------------------------------------
# apt-daily.timer and unattended-upgrades are masked above (they fight the
# platform), so WITHOUT this a VM on this base is never patched at all: its
# userspace is frozen at the image build date for as long as the VM lives.
#
# On dev VMs provision-iv.sh installs exactly these two units, which is why the
# gap was invisible -- every VM anyone looked at had them. Deployment-lane VMs
# never run that script, by design, and nothing replaced it. rss-feed was found
# 2026-08-23 live and internet-facing (public_proxy: true) on a 2026-07-28 image
# with no timer, no tailnet and no toolchain -- unpatched for 26 days and
# outside every fleet check, because fleet-patch-status filters on tag:mcp-agent
# and agentsview-coverage excludes it explicitly. Both exclusions are correct on
# their own; together they left nothing watching.
#
# Shipping the units in the IMAGE rather than a provisioning script is the point:
# the deployment lane has no git, no python and no agent, so anything that has to
# be installed onto it later is something a human has to remember. This needs
# nothing but apt, which is present.
#
# provision-iv.sh writes byte-identical units on dev VMs and enables the same
# timer name, so a dev VM inheriting these from the base is a no-op rather than a
# conflict.
#
# No automatic reboot. The kernel belongs to the host on a container-as-VM, so
# kernel packages are not the point; userspace CVEs are, and those take effect on
# the next process start.
COPY iv-apt-upgrade.service /etc/systemd/system/iv-apt-upgrade.service
COPY iv-apt-upgrade.timer /etc/systemd/system/iv-apt-upgrade.timer
RUN chmod 644 /etc/systemd/system/iv-apt-upgrade.service \
		/etc/systemd/system/iv-apt-upgrade.timer \
	&& systemctl enable iv-apt-upgrade.timer

# --- tailnet ------------------------------------------------------------------
# The prod lane has no provisioner -- no git, no python, no agent -- so a VM here
# is reachable only over the exe.dev edge, which requires the ACCOUNT OWNER's SSH
# key. No fleet VM has one (deliberately: the control-plane escalation probe
# asserts it), so nothing on the fleet can inspect a prod VM at all. That is how
# rss-feed sat 26 days unpatched with every check green -- the checks that would
# have caught it could not reach it.
#
# Installing the client here does NOT join the tailnet. iv-tailnet-join is gated
# on the `api-tailscale` integration being attached, a decision made off-VM in
# the control plane -- the same consent signal provision-iv.sh uses on dev VMs.
# Unattached, the unit exits 0 having done nothing.
#
# Explicitly NOT the v2.0.0 auto-join that was removed: that joined every VM
# unconditionally from baked-in image code. The gate is the whole difference.
#
# ~30 MB on a ~268 MB image. Priced against an internet-facing box that nothing
# can verify, that is worth it.
RUN curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg" \
		-o /usr/share/keyrings/tailscale-archive-keyring.gpg \
	&& printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main\n' \
		>/etc/apt/sources.list.d/tailscale.list \
	&& apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tailscale \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/* \
	&& systemctl enable tailscaled

COPY iv-tailnet-join.sh /usr/local/bin/iv-tailnet-join
COPY iv-tailnet-join.service /etc/systemd/system/iv-tailnet-join.service
RUN chmod 755 /usr/local/bin/iv-tailnet-join \
	&& chmod 644 /etc/systemd/system/iv-tailnet-join.service \
	&& systemctl enable iv-tailnet-join.service

# --- exedev user -------------------------------------------------------------
# Rename the stock ubuntu user (uid 1000) rather than delete/recreate, so uid,
# gid, home and subuid/subgid ranges all line up with exeuntu.
RUN usermod -l exedev -c "exe.dev user" ubuntu \
	&& groupmod -n exedev ubuntu \
	&& mv /home/ubuntu /home/exedev \
	&& usermod -d /home/exedev exedev \
	&& usermod -aG sudo exedev \
	&& sed -i 's/^ubuntu:/exedev:/' /etc/subuid /etc/subgid \
	&& printf 'exedev ALL=(ALL) NOPASSWD:ALL\nDefaults:exedev verifypw=any\n' >/etc/sudoers.d/exedev \
	&& chmod 0440 /etc/sudoers.d/exedev \
	# Linger populates /run/user/1000 so systemd --user works.
	&& mkdir -p /var/lib/systemd/linger \
	&& touch /var/lib/systemd/linger/exedev

# PATH goes at the TOP of .bashrc, not the end, and that placement is the whole
# point of this stanza.
#
# `ssh vm 'cmd'` is a non-interactive shell. It does not read .profile at all --
# only bash's special case for a network connection, which reads .bashrc. And
# Ubuntu's skel .bashrc opens with
#
#     case $- in *i*) ;; *) return;; esac
#
# so anything APPENDED to it is dead code for exactly the callers that matter:
# `ssh vm 'cmd'`, scp-then-run deploys, CI, and any agent driving the box
# non-interactively. Appending was the original form here, and it hid for months
# because the older base shipped zsh, whose .zshenv is read on EVERY invocation.
# When the shell became bash the guard started swallowing the export, and
# `ssh vm 'render-md-site ...'` failed with "/usr/bin/env: 'python3': No such
# file or directory" on a VM where python3 was installed and on an interactive
# PATH -- the confusing shape of the bug is why the comment is this long.
#
# Prepending puts it before the guard, so it applies to interactive and
# non-interactive shells alike. .profile keeps its own copy for login shells
# that never source .bashrc (`ssh vm` with no command, some su/cron paths).
RUN printf 'export PATH="$HOME/.local/bin:$PATH"\nexport XDG_RUNTIME_DIR="/run/user/$(id -u)"\n' \
		| cat - /home/exedev/.bashrc >/tmp/bashrc.new \
	&& mv /tmp/bashrc.new /home/exedev/.bashrc \
	&& printf 'export PATH="$HOME/.local/bin:$PATH"\nexport XDG_RUNTIME_DIR="/run/user/$(id -u)"\n' \
		>>/home/exedev/.profile \
	&& rm -rf /etc/update-motd.d/* /etc/motd \
	&& touch /home/exedev/.hushlogin \
	&& chown exedev:exedev /home/exedev/.hushlogin /home/exedev/.bashrc /home/exedev/.profile

# Agent context. No agent ships in this image, but one may be installed later
# (`exe.dev/install-shelley`, or a hand-installed Claude/Codex/pi), and these
# files cost ~1 KB. Canonical copy lives at the XDG path Shelley reads, with
# the other agents symlinked to it — same layout as exeuntu.
COPY AGENTS.md /home/exedev/.config/shelley/AGENTS.md
RUN mkdir -p /home/exedev/.claude /home/exedev/.codex /home/exedev/.pi \
	&& ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.claude/CLAUDE.md \
	&& ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.codex/AGENTS.md \
	&& ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.pi/AGENTS.md \
	&& chown -R exedev:exedev \
		/home/exedev/.config /home/exedev/.claude /home/exedev/.codex /home/exedev/.pi

# exe.dev supplies its own sshd/sftp-server/sh from /exe.dev/bin, so no
# openssh-server here. Verified against a stock ubuntu:24.04 VM.
#
# The file MUST be named `init`: exe.dev's exetini decides this is an init
# from the basename and execs it rather than forking it.
COPY init /usr/local/bin/init
RUN chmod +x /usr/local/bin/init

# Sets the default proxy port. Without an EXPOSE, exe.dev defaults to :80
# (verified on a stock ubuntu:24.04 VM); exeuntu exposes 8000 and 9999, the
# latter being Shelley's. We have no Shelley, so 8000 alone.
EXPOSE 8000

# Default locale for systemd services and non-SSH contexts. Three ways to
# override, in increasing order of precedence:
#
#   1. per VM, at creation:  ssh exe.dev new --env LANG=en_GB.UTF-8 ...
#   2. on the box:           sudo update-locale LANG=en_GB.UTF-8
#   3. per SSH session:      macOS ssh_config forwards LANG via SendEnv, so an
#                            interactive login already inherits the client's.
#
# Only en_US.UTF-8 and en_GB.UTF-8 are generated (exeuntu ships locales-all at
# ~200 MB). Connecting with any other LANG gives setlocale warnings — add it to
# locale-gen above if you need one.
ENV LANG=en_US.UTF-8

LABEL "exe.dev/login-user"="exedev"
# Add this if you want Shelley (and `new --prompt`) on VMs from this image:
# LABEL "exe.dev/install-shelley"="true"

# --- OCI metadata -------------------------------------------------------------
# Declared here, at the end, on purpose: an ARG invalidates the build cache from
# the point it is *used*, so keeping it below the apt layers means a new BUILD_ID
# does not trigger a full rebuild.
#
# `org.opencontainers.image.version` in particular must be set: ubuntu:24.04 ships
# that label as "24.04" and it is inherited, so without an override every scanner
# and `docker inspect` reports this image's version as Ubuntu's.
ARG BUILD_ID=dev
LABEL org.opencontainers.image.title="exeslim" \
	org.opencontainers.image.description="Minimal exe.dev base image for deployment targets: systemd and full platform wiring, without the agent workstation toolchain." \
	org.opencontainers.image.source="https://github.com/ryanlewis/exeslim" \
	org.opencontainers.image.url="https://github.com/ryanlewis/exeslim" \
	org.opencontainers.image.licenses="MIT" \
	org.opencontainers.image.base.name="docker.io/library/ubuntu:24.04" \
	org.opencontainers.image.version="${BUILD_ID}"

WORKDIR /home/exedev
CMD ["/usr/local/bin/init"]
