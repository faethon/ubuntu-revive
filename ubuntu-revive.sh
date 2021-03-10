#!/bin/bash
set -Eeuo pipefail

function cleanup() {
    trap - SIGINT SIGTERM ERR EXIT
    if [ -n "${tmpdir+x}" ]; then
        umount $mntdir
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
-u, --user-data     Path to user-data file. Required file
-m, --skip-home     Skip creating a backup of home directories. By default one gzipped tarball
                    of the complete /home directory will be created
-r, --skip-root     Skip creating a backup of root files
-t, --skip-all      Skip creating a backup of both home directories and root files. This only creates
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
        user_data_file=''

        while :; do
                case "${1-}" in
                backup) revive_command="backup"  ;;
                restore) revive_command="restore" ;;
                -m | --skip-home) nothome=1 ;;
                -h | --help) usage ;;
                -u | --user-data)
                        user_data_file="${2-}"
                        shift
                        ;;
                -v | --verbose) set -x ;;
                -m | --skip-home) nothome=1 ;;
                -r | --skip-root) notroot=1 ;;
                -t | --skip-all) skiptar=1 ;;
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
    [[ ! -x "$(command -v 7z)" ]] && die "💥 7z is not installed."
    [[ ! -x "$(command -v sed)" ]] && die "💥 sed is not installed."
    [[ ! -x "$(command -v curl)" ]] && die "💥 curl is not installed."
    [[ ! -x "$(command -v mkisofs)" ]] && die "💥 mkisofs is not installed."

    # for backup we need user-data file
    if [ ${revive_command} = "backup" ] ; then 
        [[ -z "${user_data_file}" ]] && die "💥 user-data file was not specified."
        [[ ! -f "$user_data_file" ]] && die "💥 user-data file could not be found."
    fi
    log "👍 All required utilities are installed."
}


# starting up and main script flow
parse_params "$@"
check_superuser
check_requirements


tmpdir=$(mktemp -d)
mntdir=$tmpdir/mnt
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
mkdir -p $mntdir
log "👷 Mounting Backup folder at NAS on $mntdir..."
if ! mount -t $BACKUP_TYPE -o rw,noatime $BACKUP_IP:$BACKUP_DIR $mntdir ; then 
    die "💥 Mounting failed."
fi
# create backup directory
if ! mkdir -p $mntdir/$today ; then 
    die "💥 Failed to create backup directory"
fi
log "👍 Mounting succeeded and backup directory created."


if [ ${revive_command} = "backup" ] ; then 

    # ===========================================================================
    # =        Backup 
    # ===========================================================================

    # directories to backup and exclude
    SYSTEM_DIRS="/etc/fstab \
                /var/www "
    HOME_DIRS="/home"
    EXCLUDE_DIRS="--exclude=$tmpdir \
                --exclude=/home/*/.cache \
                --exclude=/var/log \
                --exclude=/var/cache/apt/archives \
                --exclude=/usr/src/linux-headers* \
                --exclude=*.socket \
                --exclude=*.pid"
    

    log "👷 Storing system and package information on $mntdir/$today..."
    # Store current distro and installed packages
    uname -a > $mntdir/$today/distribution.desc
    lsb_release -ds >> $mntdir/$today/distribution.desc

    # save user account info for migration
    ugidlimit=500
    awk -v LIMIT=$ugidlimit -F: '($3>=LIMIT) && ($3!=65534)' /etc/passwd > $mntdir/$today/passwd.backup
    awk -v LIMIT=$ugidlimit -F: '($3>=LIMIT) && ($3!=65534)' /etc/group > $mntdir/$today/group.backup
    awk -v LIMIT=$ugidlimit -F: '($3>=LIMIT) && ($3!=65534) {print $1}' /etc/passwd | egrep -f - /etc/shadow > $mntdir/$today/shadow.backup

    # make a clone of all installed packages
    if ! apt-clone clone --with-dpkg-repack $mntdir/$today/packages >/dev/null ; then 
        die "💥 Failed to create clone of apt packages"
    fi

    log "👍 Information and clone of apt packages stored."

    # copy this backup.sh so we know what was used to create the backup
    cp $(realpath $0) $mntdir/$today/


    # Create backups of relevant directories
    # make compressed backup of root directory
    if [ ${notroot} -eq 1 ] || [ ${skiptar} -eq 1 ] ; then
        log "🧩 Skipping backup of system directories"
    else 
        log "👷 Creating backup of selected system directories"
        tar -cpf - \
            --warning=no-file-changed \
            --one-file-system \
            $EXCLUDE_DIRS \
            $SYSTEM_DIRS \
            -P | pv -s $(du -sbc \
            $EXCLUDE_DIRS \
            $SYSTEM_DIRS  \
            --one-file-system \
            | tail -1 | awk {'print $1'}) \
            | gzip > $mntdir/$today//backuproot.tar.gz
    fi

    # make compressed backup of home directory
    if [ ${nothome} -eq 1 ] || [ ${skiptar} -eq 1 ] ; then
        log "🧩 Skipping backup of home directories"
    else 
        log "👷 Creating backup of home directories"
        tar -cpf - \
            --warning=no-file-changed \
            --one-file-system \
            $EXCLUDE_DIRS \
            $HOME_DIRS \
            -P | pv -s $(du -sbc \
            $EXCLUDE_DIRS \
            $HOME_DIRS \
            --one-file-system \
            | tail -1 | awk {'print $1'}) \
            | gzip > $mntdir/$today//backuphome.tar.gz
    fi


    # Now create an automated install image for Ubuntu 20.04
    # This part is mainly copied from:
    # https://github.com/covertsh/ubuntu-autoinstall-generator

    source_iso="$tmpdir/ubuntu-original-$today.iso"
    destination_iso="$mntdir/$today/ubuntu-autoinstall-$today.iso"

    # downloading and extracting current daily ISO
    log "🌎 Downloading current daily ISO image for Ubuntu 20.04 Focal Fossa..."
    curl --progress-bar -NSL "https://cdimage.ubuntu.com/ubuntu-server/focal/daily-live/current/focal-live-server-amd64.iso" -o "$source_iso"
    log "👍 Downloaded and saved to $source_iso"
    log "🔧 Extracting ISO image..."
    7z -y -bsp2 x "$source_iso" -o"$tmpdir/iso/" >/dev/null
    rm -rf "$tmpdir/iso/"'[BOOT]'
    log "👍 Extracted to $tmpdir/iso"

    # adding autoinstall paramaters to extracted iso
    log "🧩 Adding autoinstall parameter to kernel command line..."
    sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/iso/isolinux/txt.cfg"
    sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/iso/boot/grub/grub.cfg"
    sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/iso/boot/grub/loopback.cfg"
    log "👍 Added parameter to UEFI and BIOS kernel command lines."

    # adding user-data and meta-data
    log "🧩 Adding user-data and meta-data files..."
    mkdir -p "$tmpdir/iso/nocloud"

    # write user-data file
    cp "$user_data_file" "$tmpdir/iso/nocloud/user-data"
    # write empty meta-data file
    touch "$tmpdir/iso/nocloud/meta-data"

    sed -i -e 's,---, ds=nocloud;s=/cdrom/nocloud/  ---,g' "$tmpdir/iso/isolinux/txt.cfg"
    sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/nocloud/  ---,g' "$tmpdir/iso/boot/grub/grub.cfg"
    sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/nocloud/  ---,g' "$tmpdir/iso/boot/grub/loopback.cfg"
    log "👍 Added data and configured kernel command line."


    # extract casper/filesystem.squashfs to add ubuntu-revive.sh
    unsquashfs -f -d $tmpdir/unpacked-squashfs $tmpdir/iso/casper/filesystem.squashfs 
    log "👷 Updating ISO to include restore script."
    mkdir $tmpdir/unpacked-squashfs/restore
    cp $(realpath $0) $tmpdir/unpacked-squashfs/restore
    rm -f $tmpdir/iso/casper/filesystem.squashfs
    mksquashfs $tmpdir/unpacked-squashfs $tmpdir/iso/casper/filesystem.squashfs
 

    # update checksums and repackage iso
    log "👷 Updating $tmpdir/iso/md5sum.txt with hashes of modified files..."
    md5=$(md5sum "$tmpdir/iso/boot/grub/grub.cfg" | cut -f1 -d ' ')
    sed -i -e 's,^.*[[:space:]] ./boot/grub/grub.cfg,'"$md5"'  ./boot/grub/grub.cfg,' "$tmpdir/iso/md5sum.txt"
    md5=$(md5sum "$tmpdir/iso/boot/grub/loopback.cfg" | cut -f1 -d ' ')
    sed -i -e 's,^.*[[:space:]] ./boot/grub/loopback.cfg,'"$md5"'  ./boot/grub/loopback.cfg,' "$tmpdir/iso/md5sum.txt"
    log "👍 Updated hashes."

    log "📦 Repackaging extracted files into an ISO image..."
    cd "$tmpdir/iso/"
    mkisofs -quiet -D -r -V "ubuntu-autoinstall-$today" -cache-inodes -J -l -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -o "${destination_iso}" .
    cd "$OLDPWD"
    log "👍 Created autoinstall image into ${destination_iso}"

    # graceful exit
    die "✅ Backup created and stored on NAS." 0

elif [ ${revive_command} = "restore" ] ; then

    # ===========================================================================
    # =        Restore 
    # ===========================================================================


    # Select restore directory
    # TODO: make this interactive based on available directories
    shopt -s nullglob
    for f in ${mntdir}/*-*-*; do
        if [ -d $f ] ; then lastbak=$(basename $f); echo ${lastbak} ; fi
    done

    read -rp $'Enter backup directory to restore from: ('${lastbak}')' backup
    backup=${backup:-$lastbak}

    # this only checks the existence of the directory, should check for expected files
    if [ ! -d ${mntdir}/${backup} ] ; then 
        die "💥 not a valid backup directory"
    fi

    echo "Using backup to restore from: " ${mntdir}/${backup} 

    # Ask for confirmation before starting the restore 
    read -rp $'Are you sure to restore the configuration into the current system? (YES/no): ' confirmation
    confirmation=${confirmation:-no}

    echo $confirmation

    if [ $confirmation = 'YES' ] ; then
        log "👷 Confirmed to restore!"
    else
        die "💥 Bailing out of the restore command."
    fi

    # check files
    if [[  -f ${mntdir}/${backup}/packages.apt-clone.tar.gz \
        && -f ${mntdir}/${backup}/passwd.backup  \
        && -f ${mntdir}/${backup}/group.backup  \
        && -f ${mntdir}/${backup}/shadow.backup  \
        && -f ${mntdir}/${backup}/backuproot.tar.gz \
        && -f ${mntdir}/${backup}/backuphome.tar.gz ]] ; then
        log "👍 Backup files exist."
    else
        die "💥 Backup files missing!"
	fi

    # restore users
    log "🔐 Restoring users..."
    cat ${mntdir}/${backup}/passwd.backup >> /etc/passwd
    cat ${mntdir}/${backup}/group.backup >> /etc/group
    cat ${mntdir}/${backup}/shadow.backup >> /etc/shadow

    # restore apt-clone
    log "🔐 Restoring apt packages from apt-clone..."
    if ! apt-clone restore ${mntdir}/${backup}/packages.apt-clone.tar.gz ; then 
        log "👿 apt-clone restore failed."
    fi

    # restore system files
    log "🔐 Restoring system files..."
    if ! tar -xzf ${mntdir}/${backup}/backuproot.tar.gz -C / ; then 
        log "👿 system file restore failed."
    fi

    # restore home folders
    log "🔐 Restoring home directories..."
    if ! tar -xzf ${mntdir}/${backup}/backuphome.tar.gz -C / ; then 
        log "👿 home directories restore failed."
    fi


    die "✅ Restore completed." 0

else 
    usage

    die "💥 NO VALID command supplied"
fi
