#!/bin/bash
source build/envsetup.sh
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_pick_remote_only=0
op_patches_dir=""
default_remote="github"


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

function patch_local()
{
    cd $(gettop)
    topdir=$(gettop)
    va_patches_dir=$1
    search_dir=".mypatches"

    [ "$va_patches_dir" = "local" ] && search_dir=".mypatches/local"
    [ "$va_patches_dir" = "pick" ] && search_dir=".mypatches/pick"

    find $search_dir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///" -e "s/\//:/" |sort -t : -k 2 | while read line; do
         f=$(echo $line | sed -e "s/:/\//")
         patchfile=$(basename $f)
         if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
             echo "    skipping: $f"
             continue
         fi
         project=$(echo $f |  sed -e "s/^pick\///" -e "s/^local\///"  | sed "s/\/[^\/]*$//")
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo "==== try apply to $project: "
                  #rm -rf .git/rebase-apply
             fi
             ext=${patchfile##*.}
             #rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                       echo "    patching: $f ..."
                       git am -3 -q < $topdir/.mypatches/$f
                       rc=$?
                       if [ $rc -ne 0 ]; then
                             first=0
                             echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it ..."
                             while ! git log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                 [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it ..."
                                 first=1
                                 ch=$(sed q </dev/tty)
                                 if [ "$ch" = "s" ]; then
                                    echo "skip it ..."
                                    git am --skip
                                    break
                                  fi
                             done
                       fi
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

         git format-patch "$commit_id" -o $topdir/.mypatches/pick/$project/ | sed -e "s:.*/:              :"

         patches_count=$(find $topdir/.mypatches/pick/$project -name "*.patch" -o -name "*.diff" | wc -l)
         if [ $patches_count -eq 0 ]; then
              rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/pick/$project
         elif [ -d $topdir/.mypatches/local/$project ]; then
              find $topdir/.mypatches/local/$project -type f -name "*.patch" -o -name "*.diff" | while read patchfile; do
                   patch_file_name=$(basename $patchfile)
                   changeid=$(grep "Change-Id: " $patchfile | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
                   #echo "$project >  $patchfile  ==== Change-Id:$changeid"
                   if [ "$changeid" != "" ]; then
                       if grep -q "Change-Id: $changeid" -r $topdir/.mypatches/pick/$project; then
                           pick_patch=$(grep -H "Change-Id: $changeid" -r $topdir/.mypatches/pick/$project | sed -n 1p | cut -d: -f1)
                           rm -f $patchfile
                           mv $pick_patch $topdir/.mypatches/local/$project/
                       elif [ "${patchfile:5:5}" != "[WIP]" -a "${patchfile:5:6}" != "[SKIP]" ]; then
                           rm -f $patchfile
                       fi
                   fi
              done
         fi
         [ -d $topdir/.mypatches/pick/$project ] && find $topdir/.mypatches/pick/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
         [ -d $topdir/.mypatches/local/$project ] && find $topdir/.mypatches/local/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
    done
    find $topdir/.mypatches -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
    mv $snapshot_file.new $snapshot_file
    cd $topdir
}

function resync_project()
{
    [ $# -lt 1 ] && return -1
    project=$1
    topdir=$(gettop)
    curdir=`pwd`
    cd $topdir
    rm -rf $topdir/$project
    [ -d $topdir/.repo/projects/$project.git/object ] && rm -rf $(dirname $(realpath $topdir/.repo/projects/$project.git/object))
    [ -d $topdir/.repo/projects/$project.git ] && rm -rf $topdir/.repo/projects/$project.git
    repo sync $project
    cd $curdir
}

function restore_snapshot()
{
    topdir=$(gettop)
    cd $topdir
    snapshot_file=$topdir/.mypatches/snapshot.list
    [ -f "$snapshot_file" ] || return -1
    cat $snapshot_file | while read line; do
         project=$(echo $line | cut -d, -f1 | sed -e "s/^ *//g" -e "s/ *$//g")
         basecommit=$(echo $line | cut -d, -f2 | sed -e "s/^ *//g" -e "s/ *$//g")
         remoteurl=$(echo $line | cut -d, -f3 | sed -e "s/^ *//g" -e "s/ *$//g")

         cd $topdir/$project || resync_project $project;cd $topdir/$project

         echo ">>>  restore project: $project ... "
         git stash -q || resync_project $project;cd $topdir/$project
         git clean -xdf
         if git log -n0 $basecommit >/dev/null 2>/dev/null; then
             git checkout -q --detach $basecommit>/dev/null 2>/dev/null
         else
             resync_project $project;cd $topdir/$project
             git fetch $remoteurl $basecommit && git checkout -q FETCH_HEAD >/dev/null 2>/dev/null
         fi 

         searchdir=""
         [ -d $topdir/.mypatches/pick/$project ] && searchdir="$searchdir $topdir/.mypatches/pick/$project"
         [ -d $topdir/.mypatches/local/$project ] && searchdir="$searchdir $topdir/.mypatches/local/$project"
         [ "$searchdir" != "" ] && \
         find $searchdir -type f -name "*.patch" -o -name "*.diff" | sed -e "s:$topdir/.mypatches/::"  -e "s|\/|:|" |sort -t : -k 2 | while read line; do
             rm -rf $topdir/$project/.git/rebase-apply
             f=$(echo $line | sed -e "s/:/\//")
             patchfile=$(basename $f)
             if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
                  echo "         skipping: $f"
                  continue
             fi
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                      echo "         apply patch: $f ..."
                      git am -3 -q < $topdir/.mypatches/$f
                      rc=$?
                      if [ $rc -ne 0 ]; then
                             first=0
                             echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it ..."
                             while ! git log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                 [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it ..."
                                 first=1
                                 ch=$(sed q </dev/tty)
                                 if [ "$ch" = "s" ]; then
                                    echo "skip it ..."
                                    git am --skip
                                    break
                                  fi
                             done
                      fi
                  else
                      echo "         skipping: $f ...(applied always)"
                  fi
              fi
         done

    done
    cd $topdir
}

##################################
function fix_repopick_output()
{
    [ $# -lt 1 -o ! -f "$1" ] && return -1
    logfile=$1
    if ! grep -q "Applying change number" $logfile; then
       return 1
    fi
    bLineNo=$(grep -n "Applying change number" $logfile | cut -d: -f1 )
    if [ $bLineNo -gt 1 ]; then
        eval sed -n "'$bLineNo,\$p'" $logfile > $logfile.fix
        eval sed -n "'1,$(expr $bLineNo - 1)p'" $logfile >> $logfile.fix
        mv $logfile.fix $logfile
    fi
}

function kpick()
{
    topdir=$(gettop)
    logfile=/tmp/__repopick_tmp.log
    errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")

    rm -f $errfile
    echo ""
    changeNumber=$(echo  $* | sed -e "s/-f //g")
    echo ">>> Picking change $changeNumber ..."
    LANG=en_US repopick -c 50 $* >$logfile 2>$errfile
    rc=$?
    fix_repopick_output $logfile
    cat $logfile | sed -e "/ERROR: git command failed/d"
    local tries=0
    local breakout=0
    while [ $rc -ne 0 -a -f $errfile ] ; do
          #cat  $errfile
          if [ $tries -ge 30 ]; then
                echo "    >> pick faild !!!!!"
                breakout=-1
                break
           fi

          grep -q -E "nothing to commit|allow-empty" $errfile && breakout=1 && break

          if grep -q -E "error EOF occurred|httplib\.BadStatusLine" $errfile; then
              echo "  >> pick was interrupted, retry ("$(expr $tries + 1)")..."
              #cat $logfile | sed -e "/ERROR: git command failed/d"
              #cat $errfile
              echo ""
              sleep 2
              [ $tries -gt 3 ] && https_proxy=""
              LANG=en_US https_proxy="$https_proxy" repopick -c 50 $* >$logfile 2>$errfile
              rc=$?
              if [ $rc -ne 0 ]; then
                  #cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              else
                  fix_repopick_output $logfile
                  cat $logfile
                  breakout=0
                  break
              fi
          fi
          if grep -q "conflicts" $errfile; then
              cat $errfile
              echo  "  >> pick changes conflict, please resolv it, then press ENTER to continue, or press 's' skip it ..."
              ch=$(sed q </dev/tty)
              if [ "$ch" = "s" ]; then
                    curdir=$(pwd)
                    echo "skip it ..."
                    project=$(cat $logfile | grep "Project path:" | cut -d: -f2 | sed -e "s/ //g")
                    cd $topdir/$project
                    git cherry-pick --abort
                    cd $curdir
                    break
              fi
              echo ""
              LANG=en_US repopick -c 50 $* >$logfile 2>$errfile
              rc=$?
              if [ $rc -eq 0 ]; then
                  echo "  conflicts resolved,continue ..."
                  breakout=0
                  break
              else
                  cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              fi
          fi
          [ -f $errfile ] && cat $errfile
          echo "  >>**** repopick failed !"
          breakout=-1
          break
    done
    if [ $breakout -lt 0 ]; then
        [ -f $errfile ] && cat $errfile
        rm -f $errfile
        exit $breakouit
    fi
}

########## main ###################

for op in $*; do
    if [ "$op" = "-pl" -o "$op" = "--patch_local" ]; then
         op_patch_local=1
    elif [ "$op" = "--reset" -o "$op" = "-r" ]; then
         op_reset_projects=1
    elif [ "$op" = "--snap" -o "$op" = "-s" ]; then
         op_project_snapshot=1
    elif [ "$op" = "--restore" -o "$op" = "--restore-snap" ]; then
         op_restore_snapshot=1
    elif [ "$op" = "--remote-only" -o "$op" = "-ro" ]; then
         op_pick_remote_only=1
    elif [ "$op" = "-rp" -o "$op" = "-pr" ]; then
        op_reset_projects=1
    else
         kpick $op
    fi
    if [ $op_patch_local -eq 1 ] && [ "$op" = "pick" -o "$op" = "local" ]; then
        op_patches_dir="$op"
    fi
done
get_defaul_remote

if [ $# -ge 1 ]; then
   [ $op_project_snapshot -eq 1 ] && projects_snapshot
   [ $op_reset_projects -eq 1 ] && projects_reset
   [ $op_patch_local -eq 1 ] && patch_local $op_patches_dir
   [ $op_restore_snapshot -eq 1 ] && restore_snapshot
   [ $op_pick_remote_only -eq 0 ] && exit 0
fi

###############################################################
# android

# bionic
kpick 204463 # Disable realpath logspam

# device/lineage/sepolicy
kpick 201720 # sepolicy: add rules for updater and update_engine
kpick 203558 # sepolicy: Add policy for vendor.lineage.power HAL
kpick 204286 # sepolicy: Fixing camera app not launching

# device/qcom/common
#kpick 201274 # power: Update power hal extension for new qti hal

# device/qcom/sepolicy
kpick 199559 # sepolicy: Allow dataservice_app to read/write to IPA device
kpick 203500 # qca1530: use create_socket_perms_no_ioctl to avoid neverallows
kpick 203501 # qca1530: fix neverallow on adbd
kpick 204281 # legacy: Allow qcom power HAL to interact with perfd

# frameworks/av
kpick 198113 # camera/media: Support for legacy camera HALv1
kpick 198116 # CameraService: Fix deadlock in binder death cleanup.
kpick 198951 # CamcorderProfiles: Add new camcorder profiles
kpick 201731 # libstagefright: use 64-bit usage for native_window_set_usage
kpick 203520 # media: fix infinite wait at source for HAL1 based recording
kpick 203521 # libstagefright: Free buffers on observer died
kpick 203522 # stagefright: ACodec: Resolve empty vendor parameters usage
kpick 203523 # Camera: fix use after disconnect error
kpick 200035 # Camera: CameraHardwareInterface changes to support Extended FD
kpick 204520 # camera: Only link and use vendor.qti.hardware.camera.device on qcom devices

# frameworks/base
kpick 202423 # Screenshot: append app name to filename
kpick 202542 # audio: add support for extended formats
kpick 203053 # perf: Add plumbing for PerformanceManager
kpick 203054 # perf: Adapt for HIDL Lineage power hal
kpick 203785 # SystemUI: use vector drawables for navbar icons
kpick 203786 # SystemUI: Add a reversed version of OPA layout
kpick 203787 # opalayout: Actually implement setDarkIntensity
kpick 203788 # opapayout: Update for r23 smaller navbar
kpick 203789 # opalayout/home: Fix icons and darkintensity
kpick 203790 # OpaLayout: misc code fixes
kpick 204356 # framework: port IME selector notification toggle (2/2)
kpick 204464 # Don't warn about preferred density
kpick 204465 # Don't log about /proc/uid_time_in_state not existing
kpick 204804 # Implement expanded desktop feature
#kpick 204813 # NetworkManagement : Add ability to restrict app data/wifi
kpick 204821 # SystemUI: Forward-port notification counters
kpick 204901 # LiveDisplayTile: Avoid NPE during boot up phase
kpick 204902 # NfcTile: Avoid NPE during boot up phase

# frameworks/native
kpick 203294 # surfaceflinger: set a prop when initialization is complete

# hardware/interfaces
kpick 200040 # Camed HAL extension: Added support in HIDL for Extended FD.
kpick 204515 # camera: Only link and use vendor.qti.hardware.camera.device on qcom devices
kpick 204588 # Revert "Fix powerhint for NULL parameter"

# hardware/lineage/interfaces
kpick 201226 # gps.default.so: fix crash on access to unset AGpsRilCallbacks::request_refloc
kpick 203061 # lineage/interfaces: power: Add binderized service

# hardware/qcom/audio-caf/msm8974
kpick 204892 # audio: revert "remove 5.1 channel mask if SSR is not supported"
kpick 204893 # policy_hal: Enable Direct PCM for 24 bit PCM playback
kpick 204894 # hal: Fix alignement of buffer sent to DSP for multichannel clips
kpick 204895 # audio: Enable 24 bit packed direct pcm support.

# hardware/qcom/power
kpick 203055 # power: Prepare for power profile support
kpick 203066 # power: Add known perf hint IDs
kpick 203067 # power: msm8996: Add support for power profile and cpu boost

# lineage-sdk
kpick 203030 # lineage-sdk: Add overlay support for disabling hardware features
kpick 203011 # lineage-sdk: Reenable performance profiles

# packages/apps/LineageParts
kpick 203010 # LineageParts: enable perf profiles
kpick 204822 # LineageParts: Reenable expanded desktop settings
kpick 204823 # LineageParts: Reenable status bar notification counters

# packages/apps/Settings
kpick 203009 # Settings: battery: Add LineageParts perf profiles
kpick 204361 # settings: port IME selector notification toggle (1/2)
kpick 204820 # Settings: display: Add expanded desktop preference

# packages/apps/SetupWizard
kpick 204734 # SUW: Update for LineageOS platform & sdk
kpick 204839 # SUW: Update Intent for Wifi connect
kpick 205068 # SUW: Integrate with GMS flow
kpick 205152 # SUW: Don't export our WizardManager
kpick 205039 # SUW: Remove unused permissions
kpick 205040 # SUW: rebrand step 1: update paths
kpick 205041 # SUW: rebrand step 2: update file contents
kpick 205199 # SUW: Fix crash on fingerprint capability check
kpick 205200 # SUW: Fix keydisabler setting on non-gms case

# system/core
kpick 202493 # init: add detection of charging mode
kpick 202494 # init: define BOARD_CHARGING_CMDLINE parameters
kpick 202495 # init: Bring back support for arbitrary chargermode cmdlines
kpick 204461 # Disable sphal namespace logspam

# system/sepolicy
kpick 198106 # Add rules required for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 198107 # Adapt add_service uses for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 201721 # sepolicy: allow update_engine to bypass neverallows for backuptool
kpick 203847 # sepolicy: Allow init to modify system_blk_device

#vendor/lineage
kpick 200408 # Update our privapp whitelist
kpick 201336 # soong_config: Add TARGET_HAS_LEGACY_CAMERA_HAL1 variable
kpick 201551 # extract_utils: Use vdexExtractor and oatdump for deodexing
kpick 201722 # vendor: add custom backuptools and postinstall script for A/B OTAs
kpick 201975 # repopick: Give feedback if topic does not exist
kpick 204012 # Allow building out of tree kernel modules
kpick 204075 # lineageremote: try private remote before giving up
#kpick 204208 # backuptool: introduce addon.d script versioning    (*****It will cause open gapps failed*****)
kpick 204521 # soong: Add BOARD_USES_QCOM_HARDWARE

##################################

[ $op_pick_remote_only -eq 0 ] && patch_local local

