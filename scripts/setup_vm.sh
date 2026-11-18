#!/usr/bin/env bash
#
# setup_vm.sh - set up a single-node HPC test environment on Ubuntu 24.04.
#
# Installs and configures:
#   Miniforge (conda + mamba), Apptainer, Lmod, MUNGE,
#   Slurm (slurmctld + slurmd), slurmdbd and MariaDB.
#
# Safe to run more than once: each step checks the current state first,
# config files are only replaced when their content changes (the old file
# is kept as <name>.bak.<timestamp>), and services are only restarted when
# their config changed.
#
# Run as your normal user (not root). The script calls sudo where needed.
#   bash scripts/setup_vm.sh

set -euo pipefail

# ---------------------------------------------------------------- settings
MINIFORGE_VERSION="26.9.4-2"
MINIFORGE_DIR="$HOME/miniforge3"

CLUSTER_NAME="vmcluster"
PARTITION_NAME="debug"
SLURM_ACCOUNT="hpcproject"

DB_NAME="slurm_acct_db"
DB_USER="slurm"

NODE_NAME="$(hostname -s)"
NODE_ADDR="127.0.0.1"   # the hostname only resolves to IPv6 link-local in Lima

# ---------------------------------------------------------------- helpers
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# write_file DEST MODE OWNER:GROUP  < content
# Installs content from stdin to DEST only if it differs.
# Sets CHANGED=1 if the file was written, CHANGED=0 if it was already correct.
write_file() {
    local dest=$1 mode=$2 owner=$3 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if sudo test -f "$dest" && sudo cmp -s "$tmp" "$dest"; then
        CHANGED=0
    else
        if sudo test -f "$dest"; then
            sudo cp -p "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)"
        fi
        sudo install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$tmp" "$dest"
        echo "    wrote $dest"
        CHANGED=1
    fi
    rm -f "$tmp"
}

# start_service NAME RESTART(0|1): enable at boot, then restart or start.
start_service() {
    sudo systemctl enable --quiet "$1"
    if [[ "$2" == 1 ]]; then
        sudo systemctl restart "$1"
    else
        sudo systemctl start "$1"
    fi
}

# ---------------------------------------------------------------- 0. checks
[[ $EUID -ne 0 ]] || die "Run as your normal user, not root. The script uses sudo itself."
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || die "Expected Ubuntu 24.04, found $PRETTY_NAME"
ARCH=$(uname -m)                       # aarch64 (Apple Silicon) or x86_64
log "Host $NODE_NAME, $PRETTY_NAME, $ARCH"
sudo -v                                # ask for the sudo password once, up front

# ---------------------------------------------------------------- 1. packages
log "1. System packages"
if ! grep -rqs "apptainer/ppa" /etc/apt/sources.list.d/; then
    # Apptainer is not in Ubuntu's own repositories; this PPA is the
    # upstream project's official Ubuntu package source.
    sudo add-apt-repository -y ppa:apptainer/ppa
fi
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl openssl \
    munge \
    mariadb-server \
    slurm-wlm slurmdbd \
    lmod \
    apptainer

id slurm >/dev/null 2>&1 || die "The Slurm packages did not create the 'slurm' user"

# ---------------------------------------------------------------- 2. MUNGE
log "2. MUNGE (authentication between Slurm daemons)"
if ! sudo test -s /etc/munge/munge.key; then
    sudo mungekey --create --keyfile=/etc/munge/munge.key
fi
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key
start_service munge 0

# ---------------------------------------------------------------- 3. MariaDB
log "3. MariaDB (database that stores job accounting)"
write_file /etc/mysql/mariadb.conf.d/90-slurm.cnf 0644 root:root <<'EOF'
# Settings recommended by the Slurm accounting docs, sized for a small VM.
[mysqld]
innodb_buffer_pool_size=512M
innodb_log_file_size=64M
innodb_lock_wait_timeout=900
max_allowed_packet=16M
EOF
start_service mariadb "$CHANGED"

# Reuse the existing database password if slurmdbd.conf already has one,
# so a second run does not break the working setup.
DB_PASS=""
if sudo test -f /etc/slurm/slurmdbd.conf; then
    DB_PASS=$(sudo sed -n 's/^StoragePass=//p' /etc/slurm/slurmdbd.conf)
fi
[[ -n "$DB_PASS" ]] || DB_PASS=$(openssl rand -hex 16)

# The password goes in on stdin, so it never shows up in the process list.
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# ---------------------------------------------------------------- 4. Slurm config
log "4. Slurm configuration"
sudo install -d -m 0755 -o slurm -g slurm /var/spool/slurmctld /var/log/slurm
sudo install -d -m 0755 -o root  -g root  /var/spool/slurmd /etc/slurm

# Ask slurmd what hardware it sees, so the node definition matches reality.
HW_LINE=$(sudo slurmd -C | head -n1)
CPUS=$(grep -o 'CPUs=[0-9]*' <<<"$HW_LINE" | cut -d= -f2)
REAL_MEM=$(grep -o 'RealMemory=[0-9]*' <<<"$HW_LINE" | cut -d= -f2)
[[ -n "$CPUS" && -n "$REAL_MEM" ]] || die "Could not parse 'slurmd -C' output: $HW_LINE"
DEF_MEM_PER_CPU=$(( REAL_MEM / CPUS ))
NODE_LINE=$(sed "s/^NodeName=[^ ]*/NodeName=${NODE_NAME} NodeAddr=${NODE_ADDR}/" <<<"$HW_LINE")

write_file /etc/slurm/slurmdbd.conf 0600 slurm:slurm <<EOF
# slurmdbd.conf - Slurm database daemon (managed by scripts/setup_vm.sh)
AuthType=auth/munge
DbdHost=localhost
DbdPort=6819
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
StorageType=accounting_storage/mysql
StorageHost=localhost
StoragePort=3306
StorageUser=${DB_USER}
StoragePass=${DB_PASS}
StorageLoc=${DB_NAME}
EOF
DBD_CHANGED=$CHANGED

write_file /etc/slurm/slurm.conf 0644 root:root <<EOF
# slurm.conf - single-node Slurm in a Linux VM (managed by scripts/setup_vm.sh)
# This is a test setup, not a production cluster.
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${NODE_NAME}(${NODE_ADDR})
AuthType=auth/munge
SlurmUser=slurm
SlurmctldPort=6817
SlurmdPort=6818
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
MpiDefault=none
ReturnToService=2

# Process tracking without cgroups keeps this VM setup simple.
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none

# Scheduling: hand out individual cores and memory, so jobs can share the node.
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
DefMemPerCPU=${DEF_MEM_PER_CPU}

# Accounting: slurmdbd stores job records in MariaDB, read with sacct.
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
AccountingStoragePort=6819
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=30
JobCompType=jobcomp/none

# Node and partition
${NODE_LINE} State=UNKNOWN
PartitionName=${PARTITION_NAME} Nodes=ALL Default=YES MaxTime=INFINITE State=UP
EOF
SLURM_CHANGED=$CHANGED

# ---------------------------------------------------------------- 5. slurmdbd
log "5. slurmdbd"
start_service slurmdbd "$DBD_CHANGED"
for _ in $(seq 1 30); do
    sudo sacctmgr -n list cluster >/dev/null 2>&1 && break
    sleep 1
done
sudo sacctmgr -n list cluster >/dev/null 2>&1 \
    || die "slurmdbd is not answering. Check: sudo tail -n 50 /var/log/slurm/slurmdbd.log"

# Register the cluster, an account and your user (skipped if they exist).
existing=$(sudo sacctmgr -nP list cluster format=cluster)
grep -qx "$CLUSTER_NAME" <<<"$existing" || sudo sacctmgr -i add cluster "$CLUSTER_NAME"

existing=$(sudo sacctmgr -nP list account format=account)
grep -qx "$SLURM_ACCOUNT" <<<"$existing" \
    || sudo sacctmgr -i add account "$SLURM_ACCOUNT" Description="HPC packaging project" Organization=personal

existing=$(sudo sacctmgr -nP list user format=user)
grep -qx "$USER" <<<"$existing" || sudo sacctmgr -i add user "$USER" DefaultAccount="$SLURM_ACCOUNT"

# ---------------------------------------------------------------- 6. slurmctld + slurmd
log "6. slurmctld and slurmd"
start_service slurmctld "$SLURM_CHANGED"
start_service slurmd "$SLURM_CHANGED"
for _ in $(seq 1 30); do
    state=$(sinfo -h -n "$NODE_NAME" -o %T 2>/dev/null || true)
    [[ "$state" == idle* || "$state" == mixed* || "$state" == allocated* ]] && break
    sleep 1
done
echo "    node $NODE_NAME state: ${state:-unknown}"

# ---------------------------------------------------------------- 7. Miniforge
log "7. Miniforge (conda + mamba) in $MINIFORGE_DIR"
if [[ -x "$MINIFORGE_DIR/bin/conda" ]]; then
    echo "    already installed, skipping"
else
    installer="Miniforge3-${MINIFORGE_VERSION}-Linux-${ARCH}.sh"
    url="https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}"
    dl=$(mktemp -d)
    curl -fsSL -o "$dl/$installer"        "$url/$installer"
    curl -fsSL -o "$dl/$installer.sha256" "$url/$installer.sha256"
    (cd "$dl" && sha256sum -c "$installer.sha256")
    bash "$dl/$installer" -b -p "$MINIFORGE_DIR"
    rm -rf "$dl"
fi
"$MINIFORGE_DIR/bin/conda" init bash >/dev/null   # adds conda to ~/.bashrc once

# ---------------------------------------------------------------- 8. summary
log "Done. Installed versions:"
echo "    $("$MINIFORGE_DIR/bin/conda" --version)"
echo "    mamba $("$MINIFORGE_DIR/bin/mamba" --version | head -n1)"
echo "    $(apptainer --version)"
echo "    $(sinfo --version)"
echo "    Lmod $(dpkg-query -W -f='${Version}' lmod)"
echo
echo "Open a new shell (or run: exec bash -l) so 'conda' and 'module' are on your PATH."
