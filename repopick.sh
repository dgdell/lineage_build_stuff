#!/bin/bash
source build/envsetup.sh
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_patches_dir=""
default_remote="github"

########## main ###################

for op in $*; do
    [ "$op" = "-pl" -o "$op" = "--patch_local" ] && op_patch_local=1
    [ "$op" = "--reset" -o "$op" = "-r" ] && op_reset_projects=1
    [ "$op" = "--snap" -o "$op" = "-s" ] && op_project_snapshot=1
    [ "$op" = "--restore" -o "$op" = "--restore-snap" ] && op_restore_snapshot=1
    if [ "$op" = "-rp" -o "$op" = "-pr" ]; then
        op_reset_projects=1
    fi
    if [ $op_patch_local -eq 1 ] && [ "$op" = "pick" -o "$op" = "extra" ]; then
        op_patches_dir="$op"
    fi
done

##### apply patch saved first ########
function get_defaul_remote()
{
      manifest=$(gettop)/.repo/manifest.xml
      lineno=$(grep -n "<default revision=" $manifest | cut -d: -f1)
      for ((n=$lineno;n < lineno + 6; n++)) do
          if sed -n ${n}p $manifest | grep -q " remote="; then
              remote=$(sed -n ${n}p $manifest | sed -e "s/ remote=\"\([^\"]*\)\".*/\1/")
              if [ "$remote" != "" ]; then
                  default_remote=$remote
                  break
              fi
           fi
      done
}
get_defaul_remote

function patch_local()
{
    cd $(gettop)
    topdir=$(gettop)
    va_patches_dir=$1
    search_dir=".mypatches"

    [ "$va_patches_dir" = "extra" ] && search_dir=".mypatches/extra"
    [ "$va_patches_dir" = "pick" ] && search_dir=".mypatches/pick"

    find $search_dir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///" |sort -n | while read f; do
         patchfile=$(basename $f)
         project=$(echo $f |  sed -e "s/^pick\///" -e "s/^extra\///"  | sed "s/\/[^\/]*$//")
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo "==== try apply to $project: "
                  rm -rf .git/rebase-apply
             fi
             ext=${patchfile##*.}
             rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                       echo "    patching: $f ..."
                       git am -3 -q < $topdir/.mypatches/$f
                       [ $? -ne 0 ] && exit -1
                  else
                       echo "    skipping: $f ...(applied always)"
                  fi
             fi
         fi
    done
    cd $topdir
}

function projects_reset()
{
    cd $(gettop)
    topdir=$(gettop)
    default_branch=$(cat .repo/manifest.xml | grep "default revision" | cut -d= -f2 | sed -e "s/\"//g" -e "s/refs\/heads\///")

    find .mypatches -type d | sed -e "s/\.mypatches\///" |sort -n | while read project; do
         [ "$f" = ".mypatches" ] && continue
         if ! grep -q "^$project\$" $topdir/.repo/project.list; then
              continue
         fi
         cd $topdir/$project
         echo ""
         echo "==== reset $project to $basebranch "
         basebranch=$(git branch -a | grep '\->' | grep "$default_branch" | sed -e "s/.*\-> //")
         basecommit=$(git log --pretty=short -1 $basebranch | sed -n 1p | cut -d' ' -f2)
         git reset --hard $basecommit
    done
    cd $topdir
}

function projects_snapshot()
{
    cd $(gettop)
    topdir=$(gettop)
    snapshot_file=$topdir/.mypatches/snapshot.list
    rm -f $snapshot_file.new
    cat $topdir/.repo/project.list | while read project; do
         cd $topdir/$project
         echo ">>>  project: $project ... "

         commit_id=""
         url=""

         git log --pretty=oneline --max-count=250 > /tmp/gitlog.txt
         while read line; do
             commit_id=$(echo $line | cut -d' ' -f1)
             rbranch=$(git branch --all --contain $commit_id | grep "remotes" | sed -e "s/^ *remotes\///")
             [ "$rbranch" = "" ] && continue
             remote=$(echo $rbranch | cut -d/ -f1)
             branch=$(echo $rbranch | cut -d/ -f2)
             if [ "$remote" = "m" ]; then
                remotetmp=/tmp/projects_snapshot_$(basename $project).list
                git remote show > $remotetmp
                local count=$(cat $remotetmp | wc -l)
                if grep -qw $default_remote $remotetmp; then
                     remote=$default_remote
                else
                     remote=$(sed -n 1p $remotetmp)
                fi
                rm -f $remotetmp
             fi
             url=$(git remote get-url $remote)
             if [ "$remote" != "" ]; then
                  break
             fi
         done < /tmp/gitlog.txt
         rm -f /tmp/gitlog.txt

         echo "$project, $commit_id, $url" >> $snapshot_file.new

         [ -d $topdir/.mypatches/$project ] || mkdir -p $topdir/.mypatches/$project
         rm -rf $topdir/.mypatches/pick/$project/*.patch
         rm -rf $topdir/.mypatches/pick/$project/*.diff

         git format-patch "$commit_id" -o $(gettop)/.mypatches/pick/$project/
         patches_count=$(find $topdir/.mypatches/pick/$project -name "*.patch" -o -name "*.diff" | wc -l)
         if [ $patches_count -eq 0 ]; then
              rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/pick/$project
         else
              find $topdir/.mypatches/pick/$project -type f -name "*.patch" -o -name "*.diff" | while read patchfile; do
                   patch_file_name=$(basename $patchfile)
                   changeid=$(grep "Change-Id: " $f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
                   if grep -q "Change-Id: $changid" $topdir/.mypatches/extra/$project; then
                       extra_patch=$(grep -H "Change-Id: $changid" $topdir/.mypatches/extra/$project | sed -n 1p | cut -d: -f1)
                       rm -f $extra_patch
                       mv $patchfile $topdir/.mypatches/extra/$project/$patch_file_name
                   fi
              done
         fi
    done
    mv $snapshot_file.new $snapshot_file
    cd $topdir
}

function restore_snapshot()
{
    cd $(gettop)
    topdir=$(gettop)
    snapshot_file=$topdir/.mypatches/snapshot.list
    [ -f "$snapshot_file" ] || return -1
    cat $snapshot_file | while read line; do
         project=$(echo $line | cut -d, -f1 | sed -e "s/^ *//g" -e "s/ *$//g")
         basecommit=$(echo $line | cut -d, -f2 | sed -e "s/^ *//g" -e "s/ *$//g")
         remoteurl=$(echo $line | cut -d, -f3 | sed -e "s/^ *//g" -e "s/ *$//g")

         cd $topdir/$project


         echo ">>>  restore project: $project ... "
         git stash; git clean -xdf
         if git log -n0 $basecommit 2>/dev/null; then
             git -q checkout --detach $basecommit
         else
             git fetch $remoteurl $basecommit && git checkout -q FETCH_HEAD
         fi 

         searchdir=""
         [ -d .mypatches/pick/$project ] && searchdir="$searchdir .mypatches/pick/$project"
         [ -d .mypatches/extra/$project ] && searchdir="$searchdir .mypatches/extra/$project"

         find $searchdir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///" |sort -n | while read f; do
             rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                      echo "          apply patch: $f ..."
                      git am -3 -q < $topdir/.mypatches/$f
                      [ $? -ne 0 ] && exit -1
                  else
                      echo "          skip patch: $f ...(applied always)"
                  fi
              fi
         done

    done
    cd $topdir
}

if [ $# -ge 1 ]; then
   [ $op_project_snapshot -eq 1 ] && projects_snapshot
   [ $op_reset_projects -eq 1 ] && projects_reset
   [ $op_patch_local -eq 1 ] && patch_local $op_patches_dir
   [ $op_restore_snapshot -eq 1 ] && restore_snapshot
   exit 0
fi

######################################

### invisiblek picks

repopick 198544 # SystemUI: Add visualizer feature
repopick 198556 # Settings: Add lockscreen visualizer toggle

repopick 198545 # base: Disable Lockscreen Media Art [1/3]
repopick 198557 # Settings: Disable Lockscreen Media Art [2/3]

repopick 198546 # SystemUI: enable NFC tile
repopick 198547 # SystemUI: add caffeine qs tile
repopick 198548 # SystemUI: Add heads up tile
repopick 198549 # QS: add Sync tile
repopick 198550 # Added show volume panel tile to QS
repopick 198551 # SystemUI: Add adb over network tile
repopick 198552 # SystemUI: Readd AmbientDisplayTile.
repopick 198553 # SystemUI: add USB Tether tile

repopick 198554 # SystemUI: Network Traffic [1/3]
repopick 198558 # lineage-sdk: Add Network Traffic [2/3]
repopick 198559 # LineageParts: Network Traffic [3/3]

#repopick 198622 # Add back increasing ring feature (2/3)
#repopick 198624 # Add back increasing ring feature (3/3)

repopick 200153 # StatusBar: Add dark theme toggle
repopick 200154 # LineageSettings: Add dark theme toggle
repopick 200155 # Settings: Add toggle for dark theme

repopick 200031 # AudioFX: Apply Lineage SDK rebrand
repopick 200032 # audiopolicy: Add AudioSessionInfo API
repopick 200044 # AudioFX: Remove cyngn remnants
repopick 200045 # AudioFX: rebrand step 1: update paths
repopick 200046 # AudioFX: rebrand step 2: update file contents
repopick 200047 # Revert "cm: include CMAudioService in builds"
repopick 200078 # Revert "cmsdk: Broker out CMAudioService"
repopick 200033 # lineage: Reenable AudioFX and remove LineageAudioService

#repopick 198956 # envsetup: Update default path for SDCLANG 4.0
#repopick 200167 # Add support for building with proprietary compiler
#repopick 200168 # Control building shared libs, static libs and executables with SDLLVM LTO
#repopick 200169 # Add support for using the secondary SDLLVM toolchain
#repopick 200170 # Turn off sdclang for cfi sanitizer
#repopick 200171 # build: Require devices to opt-in for SDCLANG
#repopick 200172 # binary: Append cc/cxx wrapper to sdclang
#repopick 200173 # dumpvar: Dump TARGET_USE_SDCLANG

repopick 200308 # init: always allow local.prop overrides
repopick 198959 # PackageManager: Add configuration to specify vendor platform signatures
repopick 198950 # Enable NSRM (Network Socket Request Manager).
repopick 198951 # CamcorderProfiles: Add new camcorder profiles
repopick 198952 # HAX: add LPCM to list
repopick 198953 # kernel: Handle kernel modules correctly
repopick 198954 # build: Make systemimage depend on installed kernel if system is root
repopick 198960 # update_verifier: skip verity to determine successful on lineage builds
repopick 198955 # init: don't reboot to bootloader on panic
repopick 198958 # init: I hate safety net

repopick 198962 # Init: Support bootdevice symlink for early mount.
repopick 198961 # frameworks/base: Support for third party NFC features and extensions

repopick 198949 # kernel: don't build for TARGET_NO_KERNEL targets
repopick 198957 # NFC: Adding new vendor specific interface to NFC Service
repopick 198050 # nxp: NativeNfcManager: Implement missing inherited abstract methods
repopick 198967 # InputMethodManagerService: adjust grip mode for input enable/disable

#repopick 198109 # lineagehw: Use color matricies for HWC2 color calibration
#repopick 198110 # sdk: Add DisplayUtils for global display matrix setting
#repopick 198111 # livedisplay: Use new DisplayTransformManager API to set color overlay

###  haggertk picks
:<<__COMMENT__
CAF_HALS="audio display media"
for hal in $CAF_HALS; do
  d=`pwd`
  cd hardware/qcom/${hal}-caf/msm8974 || exit 1
  git remote remove bgcngm > /dev/null 2>&1
  git remote add bgcngm https://github.com/bgcngm/android_hardware_qcom_${hal}.git || exit 1
  git fetch bgcngm staging/lineage-15.1-caf-8974-rebase-LA.BF.1.1.3_rb1.15  || exit 1
  git checkout bgcngm/staging/lineage-15.1-caf-8974-rebase-LA.BF.1.1.3_rb1.15 || exit 1
  cd $d
done
__COMMENT__

# external/tinycompress
repopick 199120 # tinycompress: HAXXX: Move libtinycompress_vendor back to Android.mk

# device/lineage/sepolicy
repopick 198594 # sepolicy: qcom: Import bluetooth_loader/hci_attach rules
repopick 199347 # sepolicy: Set the context for fsck.exfat/ntfs to fsck_exec
repopick 199348 # sepolicy: Add domain for mkfs binaries
repopick 199349 # sepolicy: label exfat and ntfs mkfs executables
repopick 199350 # sepolicy: treat fuseblk as sdcard_external
repopick 199351 # sepolicy: fix denials for external storage
repopick 199352 # sepolicy: Allow vold to `getattr` on mkfs_exec
repopick 199353 # sepolicy: allow vold to mount fuse-based sdcard
repopick 199515 # sepolicy: Add policy for sysinit
repopick 199516 # sepolicy: allow userinit to set its property
repopick 199517 # sepolicy: Permissions for userinit
repopick 199518 # sepolicy: Fix sysinit denials
repopick 199571 # sepolicy: Move fingerprint 2.0 service out of private sepolicy
repopick 199572 # sepolicy: SELinux policy for persistent properties API

# device/qcom/sepolicy
repopick 198620 # sepolicy: Let keystore load firmware
repopick 198703 # Revert "sepolicy: Allow platform app to find nfc service"
repopick 198707 # sepolicy: Include legacy rild policies
repopick 198141 # Use set_prop() macro for property sets
repopick 198303 # sepolicy: Add sysfs labels for devices using 'soc.0'
repopick 199557 # sepolicy: Readd perfd policies
repopick 199558 # sepolicy: Allow system_app to connect to time_daemon socket
repopick 199559 # sepolicy: Allow dataservice_app to read/write to IPA device
repopick 199560 # sepolicy: Allow bluetooth to connect to wcnss_filter socket
repopick 199562 # sepolicy: Allow netmgrd to communicate with netd
repopick 199562 # sepolicy: Allow netmgrd to communicate with netd
repopick 199564 # sepolicy: Allow energyawareness to read sysfs files
repopick 199565 # sepolicy: Label pre-O location data and socket file paths
repopick 199554 # sepolicy: Add /data/vendor/time label for old oreo blobs
repopick 199600 # sepolicy: Allow 'sys_admin' capability for rmt_storage

# system/sepolicy
repopick 199664 # sepolicy: Fix up exfat and ntfs support

# hardware/broadcom/libbt
repopick 200115 # libbt: Add btlock support
repopick 200116 # libbt: Add prepatch support
repopick 200117 # libbt: Add support for using two stop bits
repopick 200118 # libbt-vendor: add support for samsung bluetooth
repopick 200119 # libbt-vendor: Add support for Samsung wisol flavor
repopick 200121 # libbt-vendor: Fix Samsung patchfile detection.
repopick 200122 # Avoid an annoying bug that only hits BCM chips running at less than 3MBps
repopick 200123 # libbt-vendor: add support for Samsung semco
repopick 200124 # Broadcom BT: Add support fm/bt via v4l2.
repopick 200126 # libbt: Import CID_PATH from samsung_macloader.h
repopick 200127 # libbt: Only allow upio_start_stop_timer on 32bit arm

# frameworks/base
repopick 199835 # Runtime toggle of navbar
repopick 198564 # Long-press power while display is off for torch
repopick 199897 # Reimplement hardware keys custom rebinding
repopick 199860 # Reimplement device hardware wake keys support
repopick 199199 # PhoneWindowManager: add LineageButtons volumekey hook
repopick 199200 # Framework: Volume key cursor control
repopick 199203 # Forward port 'Swap volume buttons' (1/3)
repopick 199865 # PhoneWindowManager: Tap volume buttons to answer call
repopick 199906 # PhoneWindowManager: Implement press home to answer call
repopick 199982 # SystemUI: add left and right virtual buttons while typing
repopick 200112 # Framework: Forward port Long press back to kill app (2/2)
repopick 200188 # Allow screen unpinning on devices without navbar
repopick 199947 # PowerManager: Re-integrate button brightness

# frameworks/native
repopick 199204 # Forward port 'Swap volume buttons' (2/3)

# packages/apps/Settings
repopick 200113 # Settings: Add kill app back button toggle

# packages/apps/LineageParts
repopick 200069 # LineageParts: Deprecate few button settings
repopick 199198 # LineageParts: Bring up buttons settings
repopick 199948 # LineageParts: Bring up button backlight settings

# lineage-sdk
repopick 199898 # lineage-sdk: Import device keys custom rebinding configs and add helpers
repopick 199196 # lineage-sdk internal: add LineageButtons
repopick 199197 # lineage-sdk: Import device hardware keys configs and constants
repopick 200106 # lineage-sdk: Import ActionUtils class
repopick 200114 # lineage-sdk: Add kill app back button configs and strings

### Afaneh92 picks

repopick 198902 # Remove include for dtbhtool

:<<__COMMENT__
repopick 200533 # klte: Inherit single-SIM radio support from -common

repopick 199932 # [DO NOT MERGE] klte-common: import libril from hardware/ril-caf
repopick 199933 # [DO NOT MERGE] klte-common: libril: Add Samsung changes
repopick 199934 # klte-common: libril: Fix RIL_Call structure
repopick 199935 # klte-common: libril: Fix SMS on certain variants
repopick 199936 # klte-common: libril: fix network operator search and attach
repopick 199937 # klte-common: Update RIL_REQUEST_QUERY_AVAILABLE_NETWORKS response prop
repopick 199938 # klte-common: Set system property to fix network attach on search
repopick 199939 # klte-common: libril: Support custom number of data registration response strings
repopick 199940 # klte-common: Properly parse RIL_REQUEST_DATA_REGISTRATION_STATE response
repopick 199941 # klte-common: libril: Fix RIL_UNSOL_NITZ_TIME_RECEIVED Parcel
repopick 200495 # klte-common: Fixup RIL_Call structure

repopick 199943 # [DO NOT MERGE] klte-common: selinux permissive for O bringup
repopick 199944 # [DO NOT MERGE] klte-common: Kill blur overlay
#repopick 199945 # [DO NOT MERGE] klte-common: Kill hardware key overlays
repopick 199946 # [DO NOT MERGE] klte-common: sepolicy: Rewrite for O
repopick 200496 # klte-common: Enable single/dual SIM support with fragments
repopick 199942 # klte-common: Enable radio service 1.1
repopick 200547 # klte-common: power: Update power hal extension for new qti hal
repopick 200631 # klte-common: Drop shared blobs from proprietary files list
repopick 200632 # klte-common: Chain extract-files and setup-makefiles to msm8974-common
repopick 200643 # klte-common: Move hardware key overlays from fw/b to lineage-sdk

__COMMENT__
repopick 200634 # msm8974-common: Setup extractors for shared blobs
repopick 200635 # msm8974-common: Use shared blobs from vendor/
repopick 200636 # msm8974-common: Ship RenderScript HAL
repopick 200637 # msm8974-common: Enable boot and system server dex-preopt
repopick 200538 # msm8974-common: Use QTI power hal
