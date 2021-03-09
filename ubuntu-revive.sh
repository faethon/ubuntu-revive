#!/bin/bash
set -Eeuo pipefail

function cleanup() {
        trap - SIGINT SIGTERM ERR EXIT
        if [ -n "${tmpdir+x}" ]; then
                umount $tmpdir
                rm -rf "$tmpdir"
                log "🚽 Deleted temporary working directory $tmpdir"
        fi
}

trap cleanup SIGINT SIGTERM ERR EXIT
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
[[ ! -x "$(command -v date)" ]] && echo "💥 date command not found." && exit 1
today=$(date +"%d-%m-%Y")

function log() {
        echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"
}

function die() {
        local msg=$1
        local code=${2-1} # Bash parameter expansion - default exit status 1. See https://wiki.bash-hackers.org/syntax/pe#use_a_default_value
        log "$msg"
        exit "$code"
}

usage() {
        cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [command] [-h] [-v] [-n] [-t]

💁 This script will create a backup of data needed to recreate Nuckie.

Available commands:

backup              Create a backup of the current system, installed packages and home directories
restore             Restore users, system config and home directories


Available options:

-h, --help          Print this help and exit
-v, --verbose       Print script debug info
-m, --skip-home     Skip creating a backup of home directories. By default one gzipped tarball
                    of the complete /home directory will be created
-r, --skip-root     Skip creating a backup of root files
-t, --skip-tar      Skip creating a backup of both home directories and root files. This only creates
                    an apt-clone and additional system information.

EOF
        exit
}

# parse parameters
function parse_params() {
        # default values of variables set from params
        nothome=0
        notroot=0
        skiptar=0
        revive_command="unknown"

        while :; do
                case "${1-}" in
                backup) revive_command="backup"  ;;
                restore) revive_command="restore" ;;
                -m | --skip-home) nothome=1 ;;
                -h | --help) usage ;;
                -v | --verbose) set -x ;;
                -m | --skip-home) nothome=1 ;;
                -r | --skip-root) notroot=1 ;;
                -t | --skip-tar) skiptar=1 ;;
                -?*) die "Unknown option: $1" ;;
                *) break ;;
                esac
                shift
        done
        return 0
}

# check if invoked by superuser
function check_superuser() {
    if [ $(id -u) -ne 0 ] ; then 
        die "💥 Not superuser."
    else
        log "👶 Starting up..."
    fi
}

# check if all required packages are installed
function check_requirements() {
    log "🔎 Checking for required utilities..."
    [[ ! -x "$(command -v apt-clone)" ]] && die "💥 apt-clone is not installed."
    [[ ! -x "$(command -v apt-mark)" ]] && die "💥 apt-mark is not installed."
    log "👍 All required utilities are installed."
}


# starting up and main script flow
parse_params "$@"
check_superuser
check_requirements


tmpdir=$(mktemp -d)
distribution=$(lsb_release -ds)

if [[ ! "$tmpdir" || ! -d "$tmpdir" ]]; then
        die "💥 Could not create temporary working directory."
else
        log "📁 Created temporary working directory $tmpdir"
fi


# setup backup directory
BACKUP_TYPE="nfs"
BACKUP_IP="192.168.178.2"
BACKUP_DIR="/volume1/Backup/Nuckie"


# mount remote NFS directory and create backup directory
log "👷 Mounting Backup folder at NAS on $tmpdir..."
if ! mount -t $BACKUP_TYPE -o rw,noatime $BACKUP_IP:$BACKUP_DIR $tmpdir ; then 
    die "💥 Mounting failed."
fi
# create backup directory
if ! mkdir -p $tmpdir/$today ; then 
    die "💥 Failed to create backup directory"
fi
log "👍 Mounting succeeded and backup directory created."


if [ ${revive_command} = "backup" ] ; then 

    # ===========================================================================
    # =        Backup 
    # ===========================================================================

    # directories to backup and exclude
    SYSTEM_DIRS="/etc \
                /var/www "
    HOME_DIRS="/home"
    EXCLUDE_DIRS="--exclude=$tmpdir \
                --exclude=/home/*/.cache \
                --exclude=/var/log \
                --exclude=/var/cache/apt/archives \
                --exclude=/usr/src/linux-headers* \
                --exclude=*.socket \
                --exclude=*.pid"
    

    log "👷 Storing system and package information on $tmpdir/$today..."
    # Store current distro and installed packages
    uname -a > $tmpdir/$today/distribution.desc
    lsb_release -ds >> $tmpdir/$today/distribution.desc

    # save user account info for migration
    ugidlimit=500
    awk -v LIMIT=$ugidlimit -F: '($3>=LIMIT) && ($3!=65534)' /etc/passwd > $tmpdir/$today/passwd.backup
    awk -v LIMIT=$ugidlimit -F: '($3>=LIMIT) && ($3!=65534)' /etc/group > $tmpdir/$today/group.backup
    awk -v LIMIT=$ugidlimit -F: '($3>=LIMIT) && ($3!=65534) {print $1}' /etc/passwd | tee - |egrep -f - /etc/shadow > $tmpdir/$today/shadow.backup

    # make a clone of all installed packages
    if ! apt-clone clone --with-dpkg-repack $tmpdir/$today/nuckie ; then 
        die "💥 Failed to create clone of apt packages"
    fi

    # mark the correct state of the packages (auto/manual)
    apt-mark showauto > $tmpdir/$today/package.states.auto.list
    apt-mark showmanual > $tmpdir/$today/package.states.manual.list
    apt-mark showhold > $tmpdir/$today/package.states.hold.list

    log "👍 Information and clone of apt packages stored."

    # copy this backup.sh so we know what was used to create the backup
    cp $(realpath $0) $tmpdir/$today/


    # Create backups of relevant directories
    # make compressed backup of root directory
    if [ ${notroot} -eq 1 ] || [ ${skiptar} -eq 1 ] ; then
        log "🧩 Skipping backup of system directories"
    else 
        log "👷 Creating backup of selected system directories"
        tar -cpf - \
            --one-file-system \
            $EXCLUDE_DIRS \
            $SYSTEM_DIRS \
            -P | pv -s $(du -sbc \
            $EXCLUDE_DIRS \
            $SYSTEM_DIRS  \
            --one-file-system \
            | tail -1 | awk {'print $1'}) \
            | gzip > $tmpdir/$today//backuproot.tar.gz
    fi

    # make compressed backup of home directory
    if [ ${nothome} -eq 1 ] || [ ${skiptar} -eq 1 ] ; then
        log "🧩 Skipping backup of home directories"
    else 
        log "👷 Creating backup of home directories"
        tar -cpf - \
            --one-file-system \
            $EXCLUDE_DIRS \
            $HOME_DIRS \
            -P | pv -s $(du -sbc \
            $EXCLUDE_DIRS \
            $HOME_DIRS \
            --one-file-system \
            | tail -1 | awk {'print $1'}) \
            | gzip > $tmpdir/$today//backuphome.tar.gz


        # graceful exit
        die "✅ Backup created and stored on NAS." 0
       
    fi
elif [ ${revive_command} = "restore" ] ; then
    # Select restore directory
    # TODO: make this interactive based on available directories
    shopt -s nullglob
    for f in ${tmpdir}/*-*-*; do
        if [ -d $f ] ; then lastbak=$(basename $f); echo ${lastbak} ; fi
    done

    read -rp $'Enter backup directory to restore from: ('${lastbak}')' backup
    backup=${backup:-$lastbak}

    # this only checks the existence of the directory, should check for expected files
    if [ ! -d ${tmpdir}/${backup} ] ; then 
        die "💥 not a valid backup directory"
    fi


    echo "Using backup to restore from: " ${tmpdir}/${backup} 

    # restore users
    # cat passwd.old >> /etc/passwd
    # cat group.old >> /etc/group
    # cat shadow.old >> /etc/shadow
    # /bin/cp gshadow.old /etc/gshadow

    # restore system folders



    log "👷 RESTORE command not yet implemented"
else 
    die "💥 NO VALID command supplied"
fi

