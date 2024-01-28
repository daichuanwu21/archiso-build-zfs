# archiso-build-zfs

A script that builds a customized version of the Arch installation ISO that includes ZFS.

## Why?

Since ZFS isn't included in Linux due to [licensing issues](https://wiki.archlinux.org/title/ZFS), you need to manually build ZFS as a kernel module to use it. If you need access to ZFS within the Arch Linux installation environment, you'll have to go through an involved process to build it which involves:
- Sourcing the old kernel headers somehow
- Cloning the ZFS repository from AUR
- Importing the GPG keys
- Hoping that ZFS works on the kernel shipped by ArchISO that is a bit too new
- etc..

Yeah, that's a little annoying. Now, repeat it for every time you screw up your system and need to fix it from ArchISO. Okay, now I'm angry.

The wiki suggests [remastering the ISO](https://wiki.archlinux.org/title/ZFS#Create_an_Archiso_image_with_ZFS_support) as a solution, but you'd need to figure out how to modify the profile yourself, and you have to remember what you did for future versions of ArchISO. So, after I found [this post by lenhuppe](https://bbs.archlinux.org/viewtopic.php?id=266385) who generously included a script that detailed his approach, I was inspired to make my own version that works around a few more issues I encountered.

## How does it work?

1. The development tools and archiso are installed. Instead of installing archiso directly, it installs install archiso-git from the AUR. This ensures that if there are unreleased fixes for ISO builds on the current rolling release, the build will still succeed.
2. The ZFS packages are built and saved to a local package repository that ArchISO can pull from.
3. The ArchISO's default release engineering profile is copied to the script's working directory.
4. The "linux" kernel package is replaced with "linux-lts" to ensure compatibility with ZFS.
5. Instead of simply removing the "broadcom-wl" driver package (like with lenhuppe's approach), it is replaced with its dkms equivalent.
6. The ZFS packages are inserted into the package list, and the local repository from earlier is added.
7. Boot loader configuration references to the kernel images from the "linux" package are replaced with references to "linux-lts".
8. An SSH public key for remote connections to the environment, is copied into /root within the profile if specified.

The script also handles importing GPG keys needed for package builds and caching the user's password so sudo doesn't prompt again.

## Usage
Just clone this repository, and then run `build-archiso-with-zfs.sh` under **a regular user** with sudo privileges. If you want, you can also tell the script in a variable to include your own SSH public key so you don't need to rely on password authentication after booting the image.

## Acknowledgements
Thanks to lenhuppe on the Arch Linux forum for creating the post that inspired this script. https://bbs.archlinux.org/viewtopic.php?id=266385

Thanks to John1024 on Stack Overflow for creating a pattern that escapes strings for sed to treat them as a fixed match. https://stackoverflow.com/a/27770239
