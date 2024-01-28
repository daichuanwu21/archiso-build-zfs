#!/bin/bash

# ATTRIBUTION:
# Inspired by lenhuppe's "custom_archiso_with_lts_and_zfs" script from https://bbs.archlinux.org/viewtopic.php?id=266385
# Regex pattern for escaping sed inputs by John1024 from https://stackoverflow.com/a/27770239

# Last tested: 23/01/2024

#
# Config
#

## Kernel to replace the default kernel in archiso with
NEW_KERNEL=linux-lts

## Affects build directory naming and ISO label
ARCHISO_NAME="zfs"

## A list of packages to add to the image
# Kernel headers were added so that dkms modules can be built successfully
PACKAGES_TO_ADD=(
"${NEW_KERNEL}-headers"
dkms
zfs-dkms
zfs-utils
)

## A dictionary of package pairings that are to be replaced within the image, where the keys represents the package to be replaced, and the value represents the package's replacment
# Replace kernel with one of our choice, and the broadcom driver with the dkms variant to prevent it from pulling the old kernel again
declare -A PACKAGE_REPLACEMENTS=( ["linux"]="${NEW_KERNEL}" ["broadcom-wl"]="broadcom-wl-dkms")

## If specified, the ISO will be made to allow connections to root via this key on boot. Standard OpenSSH format, e.g. $(cat ~/.ssh/id_ed25519.pub). Can be left empty.
SSH_PUBKEY=""

#
# Preamble
#

set -e

## Coloured ANSI escape codes
RED="\033[0;31m"
GREEN="\033[0;32m"
BOLD_RED="\033[1;31m"
BOLD_WHITE="\033[1;37m"
ANSI_RESET="\033[0m" # Not a colour, but resets text effects

## Preserve 'actual' working directory for easy returns to it
ACTUAL_PWD=$(pwd)

## Error handling
trap 'err_catch $? $LINENO' ERR
function err_catch {
  echo -e "${BOLD_RED}Error code ${1} occurred on line ${2}"
}

## Error handling for 'uncaught' errors, for example calling an unknown command within a function
trap 'exit_catch $?' EXIT
function exit_catch {
  if [[ "${1}" != "0" ]]; then
    echo -e "${BOLD_RED}Non-zero exit code of ${1}${ANSI_RESET}"
  fi
}

## Fancier logging
# Usage: log_err "error to log]"
# e.g. log_err "ZFS Package Build" "Goodbye World!" will output [ZFS Package Build] Goodbye World! but with the "Goodbye World!" in red
function log_err {
  echo -e "${BOLD_WHITE}[${1}] ${RED}${2}${ANSI_RESET}"
}

# Usage: log "[stage]" "[stuff to log]"
# e.g. log "ZFS Package Build" "Hello World!" will output [ZFS Package Build] Hello World!
function log {
  echo -e "${BOLD_WHITE}[${1}] ${GREEN}${2}${ANSI_RESET}"
}

# Usage: log_func "[stuff to log]"
# Intended to be called from within functions, and the stage name will be substituted with the caller's name.
function log_func {
  log "${FUNCNAME[1]}" "$1"
}

# Same as log_func_err, but for log_err
function log_func_err {
  log_err "${FUNCNAME[1]}" "$1"
}

#
# Functions
#

#
# Check that we're not running as root
#
function check_user {
  if [[ "$(id -u)" == "0" ]]; then
    log_func_err "Run this script as a **user** with sudo privileges instead."
    return $(false)
  fi

  log_func "User is not root"
}

#
# Get the user's password and save it into the variable $PASSW
#
function get_user_password {
  IFS="" read -r -s -t 60 -p "Enter password for $(whoami) (will not be echoed): " PASSW && READ_EXIT=$? || READ_EXIT=$? ; echo ""
  if [[ $READ_EXIT != 0 ]]; then
    [[ $READ_EXIT == 142 ]] &&
      log_func_err "Timeout reached for password entry" ||
      log_func_err "Unknown exit code $READ_EXIT occurred when trying to read password"

    return $READ_EXIT
  fi

  unset READ_EXIT
}

#
# Check that the user has given the correct password and has sudo privileges
#
function check_sudo {
  timeout 5 echo "${PASSW}" | sudo -S -l && SUDO_EXIT=$? || SUDO_EXIT=$?

  # This is not a perfect check, the user could have sudo privilege for some commands, but not for all commands, which you cannot detect just by checking the exit code.
  # Furthermore, the sudo command may be caching credentials, which would defeat the validity check for the password.
  if [[ $SUDO_EXIT != 0 ]]; then
    [[ $SUDO_EXIT == 124 ]] &&
      log_func_err "Timeout reached for sudo, you likely supplied the wrong password." ||
      log_func_err "Non-zero exit code found for sudo, either you supplied the wrong password or don't have sudo privileges."

    return $SUDO_EXIT
  fi

  log_func "Nice, password for $(whoami) is likely correct, and you likely have sudo privileges."
  unset SUDO_EXIT
}

#
# Does what the name suggests, renews the credentials cache for sudo. Never called directly from the mainline, always called before an operation that may need sudo is performed, e.g. makepkg -s
#
function renew_sudo {
  echo "${PASSW}" | sudo -S -v
}

#
# Install some packages that are going to be needed anyways
#
function install_devel {
  log_func "Ensuring basic development tools, openssh and dkms are installed..."
  renew_sudo
  sudo pacman -S --needed base-devel git gnupg openssh dkms
}

#
# Ensure the git version of archiso is installed, this helps with any package changes that broke archiso builds in between the monthly installation image release windows
#
function install_archiso_git {
  # This check isn't perfect either, what if the installed version of archiso-git is outdated?
  pacman -Q archiso-git && PACMAN_EXIT=$? || PACMAN_EXIT=$?
  if [[ $PACMAN_EXIT == 0 ]]; then
    log_func "archiso-git is already installed, skipping..."
    return $(true)
  else
    log_func "archiso-git is not installed"
  fi

  pacman -Q archiso && PACMAN_EXIT=$? || PACMAN_EXIT=$?
  if [[ $PACMAN_EXIT == 0 ]]; then
    log_func "archiso is installed, removing..."
    renew_sudo
    sudo pacman -R --noconfirm archiso
  fi

  unset PACMAN_EXIT

  # Check if the archiso-git directory exists AND contains installable packages
  if [[ -d archiso-git && "$(ls -1 archiso-git/*.pkg.* | wc -l)" != 0 ]]; then
    log_func "Existing archiso-git build directory found, installing from here..."
    cd archiso-git/
    log_func "Installing existing archiso-git build..."
    renew_sudo
    sudo pacman -U --noconfirm archiso-git-*.pkg.*
    cd ../

    return $(true)
  fi

  log_func "Importing the archiso maintainers' signing keys..."
  gpg --keyserver hkps://keyserver.ubuntu.com --recv 991F6E3F0765CF6295888586139B09DA5BF0D338 BB8E6F1B81CF0BB301D74D1CBF425A01E68B38EF

  log_func "Cloning the archiso-git AUR repository..."
  git clone https://aur.archlinux.org/archiso-git.git

  log_func "Building archiso-git..."
  cd archiso-git/
  renew_sudo
  makepkg -s

  log_func "Installing archiso-git..."
  renew_sudo
  sudo pacman -U --noconfirm archiso-git-*.pkg.*
  cd ../
}

#
# Build the zfs-utils and zfs-dkms packages, and then save them inside a local repository for the archiso to install from
#
function build_zfs_packages {
  REPO_DIR="${PWD}/zfs-build"
  REPO_NAME="local-zfs-repo"
  REPO_FILE="${REPO_DIR}/${REPO_NAME}.db.tar"
  # Check if the build directory exists AND contains the local repository already
  if [[ -d "${REPO_DIR}" && -f "${REPO_FILE}" ]]; then
    log_func "Existing ZFS packages found, skipping..."

    return $(true)
  fi

  mkdir "${REPO_DIR}"
  cd "${REPO_DIR}"

  log_func "Building ZFS packages..."

  log_func "Importing the OpenZFS maintainers' signing keys..."
  gpg --keyserver hkps://keyserver.ubuntu.com --recv 4F3BA9AB6D1F8D683DC2DFB56AD860EED4598027 C33DF142657ED1F7C328A2960AB9E991C6AF658B 29D5610EAE2941E355A2FE8AB97467AAC77B9667

  log_func "Building package zfs-dkms..."
  git clone 'https://aur.archlinux.org/zfs-dkms.git'
  cd zfs-dkms
  renew_sudo
  makepkg -s
  cp zfs-dkms-*.pkg* "${REPO_DIR}"
  cd "${REPO_DIR}"

  log_func "Building package zfs-utils..."
  git clone 'https://aur.archlinux.org/zfs-utils.git'
  cp "${REPO_DIR}/zfs-dkms"/zfs-*.tar.* "${REPO_DIR}/zfs-utils" # Copy source bundles and signatures to the zfs-utils build directory to avoid needing to download it again
  cd zfs-utils
  renew_sudo
  makepkg -s
  cp zfs-utils-*.pkg* "${REPO_DIR}"
  cd "${REPO_DIR}"

  rm -rf zfs-dkms
  rm -rf zfs-utils

  repo-add "${REPO_FILE}" "${REPO_DIR}"/zfs-*.pkg.*
  cd "${ACTUAL_PWD}"

  log_func "ZFS packages stored in local repository at ${REPO_FILE}"
}

#
# Setup working directory for building the ISO; if the directory already exists, delete it. Base our custom profile on the releng profile which is used for the monthly installation image releases.
#
function setup_working_directory {
  ARCHISO_DIR="${PWD}/archiso-${ARCHISO_NAME}"
  PROFILE_DIR="${ARCHISO_DIR}/releng-${ARCHISO_NAME}"

  log_func "Archiso build will take place at: ${ARCHISO_DIR}"

  if [[ -d "${ARCHISO_DIR}" ]]; then
    log_func "Existing archiso build directory found, deleting..."
    renew_sudo
    sudo rm -rf "${ARCHISO_DIR}"
  fi

  mkdir "${ARCHISO_DIR}"
  cp -r /usr/share/archiso/configs/releng/ "${PROFILE_DIR}"
}

#
# Add the local ZFS repository we created earlier
#
function add_local_zfs_repo {
  cat <<EOF >> "${PROFILE_DIR}/pacman.conf"

[${REPO_NAME}]
SigLevel = Optional TrustAll
Server = file://${REPO_DIR}

EOF

  log_func "Added local ZFS repository to archiso"
}

#
# Modify the package list to suit our needs
#
function modify_package_list {
  for package_old in "${!PACKAGE_REPLACEMENTS[@]}"; do
    package_new=${PACKAGE_REPLACEMENTS[$package_old]}
    sed -i "s/^${package_old}$/${package_new}/" "${PROFILE_DIR}/packages.x86_64"
    log_func "Replaced package ${package_old} with ${package_new}"
  done

  for package in "${PACKAGES_TO_ADD[@]}"; do
    echo "${package}" >> "${PROFILE_DIR}/packages.x86_64"
    log_func "Added package ${package}"
  done

  # The original package list is sorted, so why not sort it on our side as well
  cat "${PROFILE_DIR}/packages.x86_64" | env LC_ALL=C sort > "${PROFILE_DIR}/packages.x86_64.sorted"
  mv "${PROFILE_DIR}/packages.x86_64.sorted" "${PROFILE_DIR}/packages.x86_64"
}

#
# Replaces kernel image references within the file located at $1 with the appropriate one for our kernel of choice using sed. Never directly called from the mainline, must be called from another function as it logs under the name of the caller function.
#
function patch_old_kimg_references {
  if [[ ! -w "${1}" ]]; then
    log_func_err "File to patch not found at ${1} or is not writable!"

    return $(false)
  fi

  sed -i "s/vmlinuz-linux/vmlinuz-${NEW_KERNEL}/" "${1}"
  sed -i "s/initramfs-linux.img/initramfs-${NEW_KERNEL}.img/" "${1}"

  log "${FUNCNAME[1]}" "Patched old kernel image references at ${1}"
}

#
# Patch the mkinitpcio preset to produce images for our kernel of choice instead
#
function patch_mkinitcpio_preset {
  cd "${PROFILE_DIR}/airootfs/etc/mkinitcpio.d"
  mv linux.preset "${NEW_KERNEL}.preset"
  patch_old_kimg_references "${PROFILE_DIR}/airootfs/etc/mkinitcpio.d/${NEW_KERNEL}.preset"
  sed -i "s/package on archiso/package on archiso, modified to work with the '${NEW_KERNEL}' package/" "${NEW_KERNEL}.preset"
  cd "${ACTUAL_PWD}"

  log_func "Patched mkinitcpio preset to produce images for ${NEW_KERNEL}"
}

function patch_syslinux_config {
  patch_old_kimg_references "${PROFILE_DIR}/syslinux/archiso_sys-linux.cfg"
  patch_old_kimg_references "${PROFILE_DIR}/syslinux/archiso_pxe-linux.cfg"

  log_func "Patched syslinux configuration to boot ${NEW_KERNEL}"
}

function patch_systemdboot_config {
  patch_old_kimg_references "${PROFILE_DIR}/efiboot/loader/entries/01-archiso-x86_64-linux.conf"
  patch_old_kimg_references "${PROFILE_DIR}/efiboot/loader/entries/02-archiso-x86_64-speech-linux.conf"

  log_func "Patched systemd-boot configuration to boot ${NEW_KERNEL}"
}

function patch_grub_config {
  patch_old_kimg_references "${PROFILE_DIR}/grub/grub.cfg"
  patch_old_kimg_references "${PROFILE_DIR}/grub/loopback.cfg"

  log_func "Patched GRUB configuration to boot ${NEW_KERNEL}"
}

#
# Patch profiledef.sh to build the ISO under a different label so that it's easier to differentiate between ZFS and non-ZFS ISOs. And, also add a line to the MOTD.
#
function change_branding {
  echo -e "\n${BOLD_WHITE}This is not an official Arch Linux installation image, it has been modified to include OpenZFS.${ANSI_RESET}" >> "${PROFILE_DIR}/airootfs/etc/motd"

  DEF_FILE="${PROFILE_DIR}/profiledef.sh"
  sed -i "s/iso_name=\"archlinux\"/iso_name=\"archlinux-${ARCHISO_NAME}\"/" "${DEF_FILE}"
  sed -i "s/iso_label=\"ARCH_/iso_label=\"ARCH_${ARCHISO_NAME^^}_/" "${DEF_FILE}"

  log_func "Branding updated to include ZFS"
}

#
# This function escapes $1 and outputs it such that sed could treat it as a fixed match during substitution. This function is never called directly from the mainline.
#
function sed_escape_string {
  if [[ -z "${1}" ]]; then
    log_func_err "No string given to escape"
    return $(false)
  fi

  # Regex was created by John1024, from https://stackoverflow.com/a/27770239
  echo "$(echo "${1}" | sed 's:[]\[^$.*/]:\\&:g')"
}

#
# profiledef.sh defines a dictionary that includes file and directory paths along with their permissions in the final image. This function inserts the SSH public key for root into the image and finds the permissions list section of profiledef.sh, and inserts appropriate permissions/files and directory pairings into the dictionary. Also, it adds the public key to the MOTD to warn the user on boot.
#
function add_ssh_pubkey {
  if [[ -z "${SSH_PUBKEY}" ]]; then
    log_func "No SSH public key defined, skipping..."

    return $(true)
  fi

  mkdir -p "${PROFILE_DIR}/airootfs/root/.ssh"
  echo "${SSH_PUBKEY}" > "${PROFILE_DIR}/airootfs/root/.ssh/authorized_keys"
  log_func "Public key added to authorized_keys under root: '${SSH_PUBKEY}'"

  # Find the line at which the /root directory has its permissions defined, this allows us to insert permission lines right after it, and within the dictionary section of profiledef.sh
  local PERMS_LINENO=$(grep -Fn '["/root"]="0:0:750"' "${DEF_FILE}" | cut -d ":" -f 1)
  if [[ -z "${PERMS_LINENO}" || $PERMS_LINENO == 0 ]]; then
    log_func_err "Failed to patch ${DEF_FILE} to include custom permissions, cannot find where permissions list begins; did the format of profiledef.sh change?"

    return $(false)
  fi
  local PERM_LINE_1=$(sed_escape_string '["/root/.ssh"]="0:0:0700"')
  sed -i "$(( PERMS_LINENO + 1 ))i \ \ ${PERM_LINE_1}" "${DEF_FILE}"
  local PERM_LINE_2=$(sed_escape_string '["/root/.ssh/authorized_keys"]="0:0:0600"')
  sed -i "$(( PERMS_LINENO + 2 ))i \ \ ${PERM_LINE_2}" "${DEF_FILE}"
  log_func "Patched ${DEF_FILE} to include permissions for /root/.ssh files"

  echo -e "\n${BOLD_WHITE}This image allows SSH connections to the root user with the following public key:${ANSI_RESET}\n$(ssh-keygen -l -f "${PROFILE_DIR}/airootfs/root/.ssh/authorized_keys")" >> "${PROFILE_DIR}/airootfs/etc/motd"
  log_func "Added SSH key fingerprint to motd"
}

#
# Run build and then remove the build directory for archiso
#
function build_and_cleanup {
  renew_sudo
  sudo mkarchiso -v -w "${ARCHISO_DIR}/work" -o "${ARCHISO_DIR}/out" "${PROFILE_DIR}"

  renew_sudo
  sudo mv "${ARCHISO_DIR}/out"/*.iso "${ACTUAL_PWD}"

  renew_sudo
  sudo rm -rf ${ARCHISO_DIR}

  renew_sudo
  sudo chown "$(id -u $(whoami)):$(id -g $(whoami))" "${ACTUAL_PWD}"/*.iso

  log_func "Build complete! The image is located at: ${ACTUAL_PWD}"
}

#
# Mainline
#

# Chores to make sure user doens't have to enter password for sudo multiple times
check_user
get_user_password
check_sudo

# Install build tools
install_devel
install_archiso_git

build_zfs_packages

# Patch archiso profile to suit our needs
setup_working_directory
add_local_zfs_repo
modify_package_list
patch_mkinitcpio_preset
patch_syslinux_config
patch_systemdboot_config
patch_grub_config
change_branding
add_ssh_pubkey

# Finally, do the build
build_and_cleanup
