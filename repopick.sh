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

    find $search_dir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///" -e "s/\//:/" |sort -t : -k 2 | while read line; do
         f=$(echo $line | sed -e "s/:/\//")
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

         [ -d $topdir/.mypatches/pick/$project ] || mkdir -p $topdir/.mypatches/pick/$project
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
                   if [ -d $topdir/.mypatches/extra/$project ] && grep -q "Change-Id: $changid" -r $topdir/.mypatches/extra/$project; then
                       extra_patch=$(grep -H "Change-Id: $changid" -r $topdir/.mypatches/extra/$project | sed -n 1p | cut -d: -f1)
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

         find $searchdir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///"  -e "s/\//:/" |sort -t : -k 2 | while read line; do
             rm -rf .git/rebase-apply
             f=$(echo $line | sed -e "s/:/\//")
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

function pick()
{
    repopick $* || exit -1
}

### invisiblek picks

pick 198544 # SystemUI: Add visualizer feature
pick 198556 # Settings: Add lockscreen visualizer toggle

pick 198545 # base: Disable Lockscreen Media Art [1/3]
pick 198557 # Settings: Disable Lockscreen Media Art [2/3]

pick 198546 # SystemUI: enable NFC tile
pick 198547 # SystemUI: add caffeine qs tile
pick 198548 # SystemUI: Add heads up tile
pick 198549 # QS: add Sync tile
pick 198550 # Added show volume panel tile to QS
pick 198551 # SystemUI: Add adb over network tile
pick 198552 # SystemUI: Readd AmbientDisplayTile.
pick 198553 # SystemUI: add USB Tether tile

pick 198554 # SystemUI: Network Traffic [1/3]
pick 198558 # lineage-sdk: Add Network Traffic [2/3]
pick 198559 # LineageParts: Network Traffic [3/3]

#pick 198622 # Add back increasing ring feature (2/3)
#pick 198624 # Add back increasing ring feature (3/3)

pick 200153 # StatusBar: Add dark theme toggle
pick 200154 # LineageSettings: Add dark theme toggle
pick 200155 # Settings: Add toggle for dark theme

pick 200031 # AudioFX: Apply Lineage SDK rebrand
pick 200032 # audiopolicy: Add AudioSessionInfo API
pick 200044 # AudioFX: Remove cyngn remnants
pick 200045 # AudioFX: rebrand step 1: update paths
pick 200046 # AudioFX: rebrand step 2: update file contents
pick 200047 # Revert "cm: include CMAudioService in builds"
pick 200078 # Revert "cmsdk: Broker out CMAudioService"
pick 200033 # lineage: Reenable AudioFX and remove LineageAudioService

#pick 198956 # envsetup: Update default path for SDCLANG 4.0
#pick 200167 # Add support for building with proprietary compiler
#pick 200168 # Control building shared libs, static libs and executables with SDLLVM LTO
#pick 200169 # Add support for using the secondary SDLLVM toolchain
#pick 200170 # Turn off sdclang for cfi sanitizer
#pick 200171 # build: Require devices to opt-in for SDCLANG
#pick 200172 # binary: Append cc/cxx wrapper to sdclang
#pick 200173 # dumpvar: Dump TARGET_USE_SDCLANG

pick 200308 # init: always allow local.prop overrides
pick 198959 # PackageManager: Add configuration to specify vendor platform signatures
pick 198950 # Enable NSRM (Network Socket Request Manager).
pick 198951 # CamcorderProfiles: Add new camcorder profiles
pick 198952 # HAX: add LPCM to list
pick 198953 # kernel: Handle kernel modules correctly
pick 198954 # build: Make systemimage depend on installed kernel if system is root
pick 198960 # update_verifier: skip verity to determine successful on lineage builds
pick 198955 # init: don't reboot to bootloader on panic
pick 198958 # init: I hate safety net

pick 198962 # Init: Support bootdevice symlink for early mount.
pick 198961 # frameworks/base: Support for third party NFC features and extensions

pick 198949 # kernel: don't build for TARGET_NO_KERNEL targets
pick 198957 # NFC: Adding new vendor specific interface to NFC Service
pick 198050 # nxp: NativeNfcManager: Implement missing inherited abstract methods
pick 198967 # InputMethodManagerService: adjust grip mode for input enable/disable

#pick 198109 # lineagehw: Use color matricies for HWC2 color calibration
#pick 198110 # sdk: Add DisplayUtils for global display matrix setting
#pick 198111 # livedisplay: Use new DisplayTransformManager API to set color overlay

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
pick 199120 # tinycompress: HAXXX: Move libtinycompress_vendor back to Android.mk

# device/lineage/sepolicy
pick 198594 # sepolicy: qcom: Import bluetooth_loader/hci_attach rules
pick 199347 # sepolicy: Set the context for fsck.exfat/ntfs to fsck_exec
pick 199348 # sepolicy: Add domain for mkfs binaries
pick 199349 # sepolicy: label exfat and ntfs mkfs executables
pick 199350 # sepolicy: treat fuseblk as sdcard_external
pick 199351 # sepolicy: fix denials for external storage
pick 199352 # sepolicy: Allow vold to `getattr` on mkfs_exec
pick 199353 # sepolicy: allow vold to mount fuse-based sdcard
pick 199515 # sepolicy: Add policy for sysinit
pick 199516 # sepolicy: allow userinit to set its property
pick 199517 # sepolicy: Permissions for userinit
pick 199518 # sepolicy: Fix sysinit denials
pick 199571 # sepolicy: Move fingerprint 2.0 service out of private sepolicy
pick 199572 # sepolicy: SELinux policy for persistent properties API

# device/qcom/sepolicy
pick 198620 # sepolicy: Let keystore load firmware
pick 198703 # Revert "sepolicy: Allow platform app to find nfc service"
pick 198707 # sepolicy: Include legacy rild policies
pick 198141 # Use set_prop() macro for property sets
pick 198303 # sepolicy: Add sysfs labels for devices using 'soc.0'
pick 199557 # sepolicy: Readd perfd policies
pick 199558 # sepolicy: Allow system_app to connect to time_daemon socket
pick 199559 # sepolicy: Allow dataservice_app to read/write to IPA device
pick 199560 # sepolicy: Allow bluetooth to connect to wcnss_filter socket
pick 199562 # sepolicy: Allow netmgrd to communicate with netd
pick 199562 # sepolicy: Allow netmgrd to communicate with netd
pick 199564 # sepolicy: Allow energyawareness to read sysfs files
pick 199565 # sepolicy: Label pre-O location data and socket file paths
pick 199554 # sepolicy: Add /data/vendor/time label for old oreo blobs
pick 199600 # sepolicy: Allow 'sys_admin' capability for rmt_storage

# system/sepolicy
pick 199664 # sepolicy: Fix up exfat and ntfs support

# hardware/broadcom/libbt
pick 200115 # libbt: Add btlock support
pick 200116 # libbt: Add prepatch support
pick 200117 # libbt: Add support for using two stop bits
pick 200118 # libbt-vendor: add support for samsung bluetooth
pick 200119 # libbt-vendor: Add support for Samsung wisol flavor
pick 200121 # libbt-vendor: Fix Samsung patchfile detection.
pick 200122 # Avoid an annoying bug that only hits BCM chips running at less than 3MBps
pick 200123 # libbt-vendor: add support for Samsung semco
pick 200124 # Broadcom BT: Add support fm/bt via v4l2.
pick 200126 # libbt: Import CID_PATH from samsung_macloader.h
pick 200127 # libbt: Only allow upio_start_stop_timer on 32bit arm

# frameworks/base
pick 199835 # Runtime toggle of navbar
pick 198564 # Long-press power while display is off for torch
pick 199897 # Reimplement hardware keys custom rebinding
pick 199860 # Reimplement device hardware wake keys support
pick 199199 # PhoneWindowManager: add LineageButtons volumekey hook
pick 199200 # Framework: Volume key cursor control
pick 199203 # Forward port 'Swap volume buttons' (1/3)
pick 199865 # PhoneWindowManager: Tap volume buttons to answer call
pick 199906 # PhoneWindowManager: Implement press home to answer call
pick 199982 # SystemUI: add left and right virtual buttons while typing
pick 200112 # Framework: Forward port Long press back to kill app (2/2)
pick 200188 # Allow screen unpinning on devices without navbar
pick 199947 # PowerManager: Re-integrate button brightness

# frameworks/native
pick 199204 # Forward port 'Swap volume buttons' (2/3)

# packages/apps/Settings
pick 200113 # Settings: Add kill app back button toggle

# packages/apps/LineageParts
pick 200069 # LineageParts: Deprecate few button settings
pick 199198 # LineageParts: Bring up buttons settings
pick 199948 # LineageParts: Bring up button backlight settings

# lineage-sdk
pick 199196 # lineage-sdk internal: add LineageButtons
pick 199197 # lineage-sdk: Import device hardware keys configs and constants
pick 199898 # lineage-sdk: Import device keys custom rebinding configs and add helpers
pick 200106 # lineage-sdk: Import ActionUtils class
pick 200114 # lineage-sdk: Add kill app back button configs and strings

### Afaneh92 picks

pick 198902 # Remove include for dtbhtool

:<<__COMMENT__
pick 200533 # klte: Inherit single-SIM radio support from -common

pick 199932 # [DO NOT MERGE] klte-common: import libril from hardware/ril-caf
pick 199933 # [DO NOT MERGE] klte-common: libril: Add Samsung changes
pick 199934 # klte-common: libril: Fix RIL_Call structure
pick 199935 # klte-common: libril: Fix SMS on certain variants
pick 199936 # klte-common: libril: fix network operator search and attach
pick 199937 # klte-common: Update RIL_REQUEST_QUERY_AVAILABLE_NETWORKS response prop
pick 199938 # klte-common: Set system property to fix network attach on search
pick 199939 # klte-common: libril: Support custom number of data registration response strings
pick 199940 # klte-common: Properly parse RIL_REQUEST_DATA_REGISTRATION_STATE response
pick 199941 # klte-common: libril: Fix RIL_UNSOL_NITZ_TIME_RECEIVED Parcel
pick 200495 # klte-common: Fixup RIL_Call structure

pick 199943 # [DO NOT MERGE] klte-common: selinux permissive for O bringup
pick 199944 # [DO NOT MERGE] klte-common: Kill blur overlay
#pick 199945 # [DO NOT MERGE] klte-common: Kill hardware key overlays
pick 199946 # [DO NOT MERGE] klte-common: sepolicy: Rewrite for O
pick 200496 # klte-common: Enable single/dual SIM support with fragments
pick 199942 # klte-common: Enable radio service 1.1
pick 200547 # klte-common: power: Update power hal extension for new qti hal
pick 200631 # klte-common: Drop shared blobs from proprietary files list
pick 200632 # klte-common: Chain extract-files and setup-makefiles to msm8974-common
pick 200643 # klte-common: Move hardware key overlays from fw/b to lineage-sdk

__COMMENT__
pick 200634 # msm8974-common: Setup extractors for shared blobs
pick 200635 # msm8974-common: Use shared blobs from vendor/
pick 200636 # msm8974-common: Ship RenderScript HAL
pick 200637 # msm8974-common: Enable boot and system server dex-preopt
pick 200538 # msm8974-common: Use QTI power hal

