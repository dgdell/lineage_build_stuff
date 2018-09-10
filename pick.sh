#!/bin/bash
source build/envsetup.sh
topdir=$(gettop)
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_pick_remote_only=0
op_snap_project=""
op_patches_dir=""
op_base_pick=0
default_remote="github"
script_file=$0
conflict_resolved=0
checkcount=200

[ "$script_file" != "bash" ] && script_file=$(realpath $0)

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

    if [ -d "$topdir/.mypatches/$va_patches_dir" ]; then
        search_dir=".mypatches/$va_patches_dir"
    elif [ -d "$topdir/.mypatches/pick/$va_patches_dir" -o -d "$topdir/.mypatches/local/$va_patches_dir" ]; then
        search_dir=".mypatches/local/$va_patches_dir .mypatches/pick/$va_patches_dir"
    fi

    find $search_dir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///" -e "s/\//:/" |sort -t : -k 2 | while read line; do
         f=$(echo $line | sed -e "s/:/\//")
         patchfile=$(basename $f)
         project=$(echo $f |  sed -e "s/^pick\///" -e "s/^local\///"  | sed "s/\/[^\/]*$//")
         if [ ! -d "$topdir/$project" ]; then
            if [ -d "$topdir/$(dirname $project)" ]; then
               project=$(dirname $project)
            else
                continue
            fi 
         fi
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo "==== try apply to $project: "
                  #rm -rf .git/rebase-apply
             fi
             if echo $f | grep -qE "\[WIP\]|\[SKIP\]"; then
                 echo "    skipping: $f"
                 continue
             fi

             ext=${patchfile##*.}
             #rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                       echo "    patching: $f ..."
                       git am -3 -q   --keep-cr --committer-date-is-author-date < $topdir/.mypatches/$f
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
         [ "$1" != "" -a "$project" != "$(echo $1 | sed -e 's/\/$//')" ] && continue
         cd $topdir/$project
         echo ">>>  project: $project ... "

         commit_id=""
         url=""

         git log --pretty="format:%H|%s|%D" --max-count=250 > /tmp/gitlog.txt
         echo >>/tmp/gitlog.txt
         while read line; do
             commit_id=$(echo $line | cut -d"|" -f1)
             branches=$(echo $line | cut -d"|" -f3)
             [ "$branches" = "" -o "$commit_id" = "" ] && continue
             if echo $branches | grep -q -e "[[:space:]]*m\/"; then
                 remotetmp=/tmp/projects_snapshot_$(basename $project).list
                 git remote show > $remotetmp
                 local count=$(cat $remotetmp | wc -l)
                 if grep -qw $default_remote $remotetmp; then
                      remote=$default_remote
                 else
                      remote=$(sed -n 1p $remotetmp)
                 fi
                 rm -f $remotetmp

                 if [ "$remote" != "" ]; then
                      url=$(git remote get-url $remote)
                      break
                 fi
             fi
         done < /tmp/gitlog.txt
         rm -f /tmp/gitlog.txt

         [ "$1" != "" -a "$project" != "$1" ] || \
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
                           pick_patch_name=$(basename $pick_patch)
                           if echo $patch_file_name | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]" ; then
                               [ "${patch_file_name:5:5}" = "[WIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:5}-${pick_patch_name:5}
                               [ "${patch_file_name:5:6}" = "[SKIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:6}-${pick_patch_name:5}
                               [ "${patch_file_name:5:8}" = "[ALWAYS]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:8}-${pick_patch_name:5}
                           elif echo $(dirname $patchfile) | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]" ; then
                               rm -f $patchfile
                               mv $pick_patch $(dirname $patchfile)/
                           else
                               rm -f $patchfile
                               mv $pick_patch $topdir/.mypatches/local/$project/
                           fi
                       elif ! echo $patchfile | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]"; then
                           rm -f $patchfile
                       fi
                   fi
              done
         fi
         [ -d $topdir/.mypatches/pick/$project ] && find $topdir/.mypatches/pick/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
         [ -d $topdir/.mypatches/local/$project ] && find $topdir/.mypatches/local/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
    done
    find $topdir/.mypatches -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null

    [ "$1" != "" -a "$project" != "$1" ] || \
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

         tmp_skip_dirs=/tmp/skip_dirs_$(echo $project | sed -e "s:/:_:g")
         cd $topdir/$project || resync_project $project;cd $topdir/$project

         echo ">>>  restore project: $project ... "
         git stash -q || resync_project $project;cd $topdir/$project
         LANG=en_US git clean -xdf | sed -e "s/Skipping repository //g" | sed -e "s:/$::"> ${tmp_skip_dirs}
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
             fdir=$(dirname $f | sed -e "s:$project/::" | sed -e "s:^[^/]*/::g" |sed -e "s:\[.*::g" | sed -e "s:/$::")
             grep -q -E "^$fdir$" ${tmp_skip_dirs} && continue
             patchfile=$(basename $f)
             if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
                  echo "         skipping: $f"
                  continue
             fi
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                      echo "         apply patch: $f ..."
                      git am -3 -q  --keep-cr --committer-date-is-author-date < $topdir/.mypatches/$f
                      rc=$?
                      if [ $rc -ne 0 ]; then
                             first=0
                             resolved=0
                             if grep -q "using previous resolution" $errfile; then
                                 grep "using previous resolution" $errfile | sed -e "s/Resolved '\(.*\)' using previous resolution.*/\1/" | xargs git add -f
                                 if git am --continue; then
                                      resolved=1
                                 fi
                             fi
                             if [ $resolved -eq 0 ]; then
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
                      fi
                  else
                      echo "         skipping: $f ...(applied always)"
                  fi
              fi
         done
         rm -f ${tmp_skip_dirs}
    done
    cd $topdir
}

function rrCache()
{
    [ $# -eq 0 ] && return -1
    if [ "$1" = "-backup" -o "$1" = "backup" ]; then
         [ -f $topdir/.mypatches/rr-cache/rr-cache.list ] && \
         find $topdir/.mypatches/rr-cache/ -mindepth 1 -maxdepth 1 -type d | xargs rm -rf  &&\
         cat $topdir/.mypatches/rr-cache/rr-cache.list | while read line; do
             project=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f2)
             rrid=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f1)
             if [ -d $topdir/$project/.git/rr-cache/$rrid ]; then
                  rm -rf  $topdir/.mypatches/rr-cache/$project/$rrid
                  rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/rr-cache/$project >/dev/null 2>/dev/null
                  if  [ -d $topdir/$project/.git/rr-cache/$rrid ] && find $topdir/$project/.git/rr-cache/$rrid -name "postimage*" > /dev/null 2>/dev/null; then
                      [ -d $topdir/.mypatches/rr-cache/$project/$rrid ] || mkdir -p $topdir/.mypatches/rr-cache/$project/$rrid
                      cp -r $topdir/$project/.git/rr-cache/$rrid $topdir/.mypatches/rr-cache/$project/
                  fi
             fi
         done
    elif [ "$1" = "-restore" -o "$1" = "restore" ]; then
         [ -f  $topdir/.mypatches/rr-cache/rr-cache.list ] && \
         cat $topdir/.mypatches/rr-cache/rr-cache.list | while read line; do
             project=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f2)
             rrid=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f1)
             if [ -d $topdir/.mypatches/rr-cache/$project/$rrid ] && [ ! -z "$(ls -A $topdir/.mypatches/rr-cache/$project/$rrid)" ]; then
                   rm -rf $topdir/$project/.git/rr-cache/$rrid
                   [ -d $topdir/$project/.git/rr-cache/$rrid ] || mkdir -p $topdir/$project/.git/rr-cache/$rrid
                   cp -r $topdir/.mypatches/rr-cache/$project/$rrid/* $topdir/$project/.git/rr-cache/$rrid/
             fi
         done
    fi
}

##################################
function fix_repopick_output()
{
    [ $# -lt 1 -o ! -f "$1" ] && return -1
    logfile=$1
    count=$(grep -c "Applying change number" $logfile)
    if [ $count -ne 1 ]; then
       return 1
    fi
    bLineNo=$(grep -n "Applying change number" $logfile | cut -d: -f1 )
    if [ $bLineNo -gt 1 ]; then
        eval sed -n "'$bLineNo,\$p'" $logfile > $logfile.fix
        eval sed -n "'1,$(expr $bLineNo - 1)p'" $logfile >> $logfile.fix
        mv $logfile.fix $logfile
    fi
}

function get_active_rrcache()
{
    [ $# -lt 2 ] && return -1
    local project=$1
    [ -d $topdir/$project ] || return -1

    local md5file=$2
    local rr_cache_list="rr-cache.tmp"
    [ -f "$md5file" ] || return -1
    rrtmp=/tmp/$(echo $project | sed -e "s:/:_:g")_rr.tmp
    while read line; do
        #key=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f1)
        fil=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f2)
        #typ=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f3)
        key=$(md5sum $topdir/$project/$fil | sed -e "s/ .*//g")
        [ -d $topdir/$project/.git/rr-cache ] && \
        find $topdir/$project/.git/rr-cache/ -mindepth 2 -maxdepth 2 -type f -name "postimage*" > $rrtmp
        [ -f "$rrtmp" ] && while read rrf; do
            md5num=$(md5sum $rrf|cut -d' ' -f1)
            #echo "$key ?= $md5num   ----->  $rrf"
            if [ "$key" = "$md5num" ]; then
               rrid=$(basename $(dirname $rrf))
               [ -d $topdir/.mypatches/rr-cache ] || mkdir -p $topdir/.mypatches/rr-cache
               [ "$script_file" == "bash" -a ! -f $topdir/.mypatches/rr-cache/rr_cache_list ] && rr_cache_list="rr-cache.list"
                
               [ -f $topdir/.mypatches/rr-cache/$rr_cache_list ] || touch $topdir/.mypatches/rr-cache/$rr_cache_list
               if ! grep -q "$rrid $project" $topdir/.mypatches/rr-cache/$rr_cache_list; then
                    echo "$rrid $project" >> $topdir/.mypatches/rr-cache/$rr_cache_list
               fi
            fi
        done < $rrtmp
        rm -rf $rrtmp
    done < $md5file
    rm -rf $md5file
}

function kpick()
{
    topdir=$(gettop)
    conflict_resolved=0
    op_force_pick=0
    logfile=$topdir/.pick_tmp.log
    errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")

    rm -f $errfile $logfile
    echo ""
    local changeNumber=""
    local op_is_m_parent=0
    local op_is_topic=0
    local topic=""
    local m_parent=1
    local nops=""
    for op in $*; do
        if [ $op_is_m_parent -eq 1 ]; then
             [[ $op =~ ^[0-9]+$ ]] && [ $op -lt 10 ] && m_parent=$op
             op_is_m_parent=0
             continue
        elif [ $op_is_topic -eq 1 ]; then
             topic=$op
             op_is_topic=0
        fi
        [ "$op" = "-m" ] && op_is_m_parent=1 && continue
        [ -z "$changeNumber" ] && [[ $op =~ ^[0-9]+$ ]] && [ $op -gt 1000 ] && changeNumber=$op
        [ "$op" = "-f" ] && op_force_pick=1
        [ "$op" = "-t" ] && op_is_topic=1
        nops="$nops $op"
    done
    if  [ "$changeNumber" = "" ]; then
         if [ "$topic" != "" ]; then
               echo ">>> Picking topic [$topic] ..."
         else
               echo ">>> Picking $nops ..."
         fi
         repopick $nops || exit -1
         return 0
    fi
    echo ">>> Picking change $changeNumber ..."
    LANG=en_US repopick -c $checkcount $nops >$logfile 2>$errfile
    rc=$?
    local subject=$(grep -Ri -- '--> Subject:' $logfile | sed 's/--> Subject:[[:space:]]*//g')
    if [ "${subject:0:1}" = '"' ]; then
          subject=$(echo $subject | sed 's/^"//' | sed 's/"$//' | sed "s/\"/\\\\\"/g" | sed "s/'/\\\\\'/g" | sed "s/\&/\\\&/g")
    else
          subject=$(echo $subject | sed "s/\"/\\\\\"/g" | sed "s/'/\\\\\'/g" | sed "s/\&/\\\&/g")
    fi
    #echo " ---subject=$subject"
    fix_repopick_output $logfile
    cat $logfile | sed -e "/ERROR: git command failed/d" | sed "/Force-picking a closed change/d"
    project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
    [ -d $topdir/$project ] || project=""
    local tries=0
    local breakout=0
    local pick_mode="reopick"
    while [ $rc -ne 0 -a -f $errfile ];  do
          [ $tries -ge 1 ] && echo ".... try "$(expr $tries + 1)"..."
          #cat  $errfile
          if [ $tries -ge 30 ]; then
                echo "    >> pick faild !!!!!"
                breakout=-1
                break
          fi

          if grep -q "is a merge but no -m option was given" $errfile; then
              pick_mode="fetch"
              project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
              ref=$(cat $logfile | grep "\['git"  | cut -d, -f2 | sed -e "s: u'\(.*\)']:\1:")
              url=$(cat $errfile | grep "^From " | sed -e "s/From //" | sed -e "s/git:/https:/")
              cd $topdir/$project
              #echo "git fetch $url $ref && git cherry-pick -m $m_parent FETCH_HEAD"
              if git fetch $url $ref; then
                     rchid=$(git log FETCH_HEAD -n 1 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g")
                     recent_changeid_tmp=/tmp/$(echo $project | sed -e "s:/:_:g")_recent_ids.txt
                     git log -n 50 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g" > $recent_changeid_tmp
                     if grep -q $rchid $recent_changeid_tmp; then
                         echo "Change is  cherry-picked always! skipping it..."
                     else
                         LANG=en_US git cherry-pick -m $m_parent FETCH_HEAD >$logfile 2>$errfile
                     fi
              fi
              rc=$?
              cd $topdir
              if [ $rc -eq 0 ]; then
                   rm -f $errfile
                   [ -z $recent_changeid_tmp ] ||  rm -f $recent_changeid_tmp
                   breakout=0
                   break
              fi
          fi

          grep -q -E "nothing to commit|allow-empty" $errfile && breakout=1 && break


          if grep -q -E "error EOF occurred|httplib\.BadStatusLine|urllib2\.URLError|Connection refused" $errfile; then
              #echo "  >> pick was interrupted, retry ("$(expr $tries + 1)")..."
              #cat $logfile | sed -e "/ERROR: git command failed/d"
              #cat $errfile
              echo ""
              sleep 2
              [ $tries -ge 2 ] && https_proxy=""
              LANG=en_US https_proxy="$https_proxy" repopick -c $checkcount $nops >$logfile 2>$errfile
              rc=$?
              if [ $rc -ne 0 ]; then
                  #cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              else
                  fix_repopick_output $logfile
                  cat $logfile
                  breakout=0
                  rm -f $errfile
                  break
              fi
          fi

          if grep -q "conflicts" $errfile; then
              echo "!!!!!!!!!!!!!"
              cat $errfile
              [ -z $project ] && project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
              md5file=/tmp/$(echo $project | sed -e "s:/:_:g")_rrmd5.txt
              rm -rf $md5file
              if [ "$project" != "" -a -d $topdir/$project ]; then
                    touch $md5file
                    if grep -q "using previous resolution" $errfile; then
                       echo "------------"
                       cd $topdir/$project
                       grep "using previous resolution" $errfile | sed -e "s|Resolved '\(.*\)' using previous resolution.*|\1|" \
                           | xargs md5sum | sed -e "s/\(.*\)/\1 postimage/" >>$md5file
                       grep "using previous resolution" $errfile | sed -e "s|Resolved '\(.*\)' using previous resolution.*|\1|" \
                           | xargs git add -f
                       if git commit --no-edit; then
                          breakout=0
                          conflict_resolved=1
                          get_active_rrcache $project $md5file
                          cd $topdir
                          break
                       fi
                       cd $topdir
                       echo "------------"
                    fi
                    if grep -q "Recorded preimage for" $errfile; then
                       cd $topdir/$project
                       grep "Recorded preimage for" $errfile | cut -d\' -f2 | xargs md5sum | sed -e "s/\(.*\)/\1 preimage/" >>$md5file
                       cd $topdir
                    fi
              fi
              echo  "  >> pick changes conflict, please resolv it, then press ENTER to continue, or press 's' skip it ..."
              ch=$(sed q </dev/tty)
              if [ "$ch" = "s" ]; then
                    echo "skip it ..."
                    cd $topdir/$project
                    git cherry-pick --abort >/dev/null 2>/dev/null
                    cd $topdir
                    break
              fi
              if [ "$pick_mode" = "fetch" ]; then
                    cd $topdir/$project
                    rchid=$(git log FETCH_HEAD -n 1 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g")
                    recent_changeid_tmp=/tmp/$(echo $project | sed -e "s:/:_:g")_recent_ids.txt
                    git log -n 50 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g" > $recent_changeid_tmp
                    grep -q $rchid $recent_changeid_tmp || \
                       LANG=en_US git cherry-pick -m $m_parent FETCH_HEAD >$logfile 2>$errfile
                    rc=$?
                    cd $topdir
              else
                    cd $topdir
                    LANG=en_US repopick -c $checkcount $nops >$logfile 2>$errfile
                    rc=$?
              fi
              if [ $rc -eq 0 ]; then
                  echo "  conflicts resolved,continue ..."
                  breakout=0
                  conflict_resolved=1
                  get_active_rrcache $project $md5file
                  break
              else
                  cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              fi
          fi
          if grep -q "could not determine the project path for" $errfile; then
              echo "Not determine the project, skipping it ..."
              breakout=0
              break
          fi
          [ -f $errfile ] && cat $errfile
          echo "  >>**** repopick failed !"
          breakout=-1
          break
    done

    [ -z $recent_changeid_tmp ] ||  rm -f $recent_changeid_tmp

    if [ $breakout -lt 0 ]; then
        [ -f $errfile ] && cat $errfile
        if [ $0 = "bash" ]; then
           return $breakout
        else
           exit $breakout
        fi
    elif [ -f $logfile ]; then
        [ "$project" = "" ] && project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
        ref=$(grep "\['git fetch" $logfile | cut -d, -f2 | cut -d\' -f2)
        if [ "$project" = "android" ]; then
             cd $topdir/android
             git format-patch HEAD^ --stdout > /tmp/change_$changeNumber.patch
             local changeid=$(grep "Change-Id:" /tmp/change_$changeNumber.patch | cut -d' ' -f 2)
             cd $topdir/.repo/manifests
             git log -n 50 | grep "Change-Id:"  | cut -d: -f2 | sed -e "s/ //g" > /tmp/manifest_changeids.txt
             if ! grep -q "$changeid" /tmp/manifest_changeids.txt;  then
                 if ! git am -3 < /tmp/change_$changeNumber.patch >/dev/null 2>/tmp/change_$changeNumber.err; then
                      echo  "  >> git am conflict, please resolv it, then press ENTER to continue ..."
                      sed q </dev/tty
                 fi
             fi
             rm -f /tmp/change_$changeNumber.patch /tmp/change_$changeNumber.err /tmp/manifest_changeids.txt
             cd $topdir
        fi
 
        if [ -f $logfile -a "$script_file" != "bash" -a ! -z $changeNumber ]; then
            if grep -q -E "Change status is MERGED.|nothing to commit" $logfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q -E "Change status is ABANDONED." $logfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q -E "Change $changeNumber not found, skipping" $logfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q "could not determine the project path for" $errfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif [ "$changeNumber" != "" -a "$subject" != "" ]; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  "sed -e \"s|^[[:space:]]*kpick $changeNumber[[:space:]]*.*|kpick $changeNumber \# $subject|g\" -i $script_file.tmp"
            fi
         fi
    fi
    rm -f $errfile $logfile
}

function privpick() {
  git -C $1 fetch github $2
  git -C $1 cherry-pick FETCH_HEAD
}

function apply_force_changes(){
    [ -z $topdir ] && topdir=$(gettop)
    [ -d "$topdir/.mypatches/local/vendor/lineage"  ] || return 0
    find $topdir/.mypatches/local/vendor/lineage/ -type f -name "*-\[ALWAYS\]-*.patch" -o -name "*-\[ALWAYS\]-*.diff" \
      | while read f; do
         cd $topdir/vendor/lineage;
         if ! git am -3 -q   --keep-cr --committer-date-is-author-date < $f; then
            exit -1
         fi
    done
}
########## main ###################

get_defaul_remote

for op in $*; do
    if [ "$op" = "-pl" -o "$op" = "--patch_local" ]; then
         op_patch_local=1
    elif [ "$op" = "--reset" -o "$op" = "-r" ]; then
         op_reset_projects=1
    elif [ "$op" = "--snap" -o "$op" = "-s" ] && [ ! -f $topdir/.pick_base ]; then
         op_project_snapshot=1
    elif [ "$op" = "--restore" -o "$op" = "--restore-snap" ]; then
         op_restore_snapshot=1
    elif [ "$op" = "--remote-only" -o "$op" = "-ro" ]; then
         op_pick_remote_only=1
    elif [ "$op" = "-rp" -o "$op" = "-pr" ]; then
         op_reset_projects=1
    elif [ "$op" = "--backup-rr-cache" ]; then
         rrCache -backup
         exit $?
    elif [ "$op" = "--restore-rr-cache" ]; then
         rrCache -restore
         exit $?
    elif [ $op_patch_local -eq 1 ]; then
            op_patches_dir="$op"
    elif [ $op_project_snapshot -eq 1 -a  -d "$(gettop)/$op" ]; then
         op_snap_project=$op
    elif [ "$op" = "-nop" ]; then
          return 0
    elif [ "$op" = "-base" ]; then
         op_base_pick=1
    else
         echo "kpick $op"
         kpick $op
    fi
done

if [ $# -ge 1 ]; then
   if [ $op_project_snapshot -eq 1 ]; then
         projects_snapshot $op_snap_project
         exit $?
   fi
   if [ $op_reset_projects -eq 1 ]; then
         projects_reset
         exit $?
   fi
   if [ $op_patch_local -eq 1 ]; then
         patch_local $op_patches_dir
         exit $?
   fi
   if [ $op_restore_snapshot -eq 1 ]; then
         restore_snapshot
         exit $?
   fi
   [ $op_pick_remote_only -eq 1 ] && exit 0
fi

###############################################################
# patch repopick first
topdir=$(gettop)
rm -rf $topdir/.pick_base

rrCache restore # restore rr-cache


###################################
#---------base pick --------------#
if [ $op_base_pick -eq 1 ]; then
   cd $topdir/.repo/manifests; git reset --hard $(git log -20 --all --decorate | grep commit | grep "m/lineage-" | cut -d' ' -f 2);
   cd $topdir
   repo sync 
   apply_force_changes

   kpick 209019 # toybox: Use ISO C/clang compatible __typeof__ in minof/maxof macros

   echo 
   echo "Apply I hate the safty net..."
   privpick system/core refs/changes/19/206119/2 # init: I hate safety net
   touch $topdir/.pick_base
   exit 0
fi
#---------------------------------#
###################################

if [ $0 != "bash" -a ! -f $0.tmp ]; then    # continue pick or not
repo sync vendor/lineage >/dev/null
apply_force_changes

# android

repo sync android  >/dev/null
cd .repo/manifests
git reset >/dev/null
git stash >/dev/null
git rebase --abort >/dev/null 2>/dev/null
git fetch --all >/dev/null

default_branch=$(grep "^[[:space:]]*<default revision=" $topdir/.repo/manifests/default.xml | sed -e 's:[^"]*"\(.*\)":\1:' | sed -e "s:refs/heads/::g")
git reset --hard $(git branch -a | grep "remotes/m/$default_branch" | cut -d'>' -f 2 | sed -e "s/ //g") >/dev/null
cd $topdir

kpick 223893 # manifest: Re-enable bash, nano and other cmdline tools
kpick 225832 # lineage: Enable qcom sepolicy
kpick 227745 # lineage: Enable FM apps
kpick 225583 # manifest: Enable lineage styles overlays
kpick 227747 # lineage: Enable weather apps
#kpick 227748 # lineage: Enable qcom thermal/vr HALs
kpick 226755 # lineage: Enable cryptfs_hw
#kpick 227749 # lineage: Enable exfat/fuse/ntfs-3g repositories

android_head=$(cd android;git log -n 1 | sed -n 1p | cut -d' ' -f2;cd $topdir)

repo sync --force-sync
cd android;git reset --hard $android_head >/dev/null;cd $topdir

apply_force_changes

fi       # continue pick or not

# bionic
kpick 223063 # Restore android_alarm.h kernel uapi header
kpick 223067 # libc fortify: Ignore open() O_TMPFILE mode bits warning
kpick 223943 # bionic: meh
kpick 225463 # bionic: Let popen and system fall back to /sbin/sh
kpick 225464 # bionic: Sort and cache hosts file data for fast lookup
kpick 225465 # libc: Mark libstdc++ as vendor available
kpick 226183 # Implement per-process target SDK version override.

# boot/recovery
kpick 225588 # recovery: updater: Fix SymlinkFn args
kpick 226282 # Revert "f2fs: support f2fs by setting unmovable bit for package file"
kpick 226283 # f2fs: support f2fs by setting unmovable bit for package file
kpick 226284 # uncrypt: fix f2fs ioctl argument for pin_file

# build/make
kpick 222733 # core: Disable vendor restrictions
kpick 222742 # build: Use project pathmap for recovery
kpick 222760 # Add LOCAL_AIDL_FLAGS
#kpick 226919 # Depend on the ramdisk/root files for BOARD_BUILD_SYSTEM_ROOT_IMAGE
#kpick 226537 # releasetools: Rename the ramdisk_dir in prop dict to root_dir.
#kpick 227213 # releasetools: Fix an issue in image size computation.
#kpick 226920 # Support a first stage ramdisk via TARGET_RAMDISK_OUT
#kpick 226939 # releasetools: Fix the path to the OTA keys in recovery image.

# build/soong
kpick 222648 # Allow providing flex and bison binaries
kpick 224613 # soong: Add LOCAL_AIDL_FLAGS handling
kpick 224827 # soong: Add java sources overlay support
kpick 226593 # soong: Add function to return targer specific header path
#kpick 226918 # Add /ramdisk to installclean

# dalvik
kpick 225475 # dexdeps: Add option for --include-lineage-classes.
kpick 225476 # dexdeps: Ignore static initializers on analysis.

# device/lineage/sepolicy
#kpick 225945 # sepolicy: Update to match new qcom sepolicy

# device/qcom/sepolicy
kpick 224767 # sepol: Remove duplicated hal_vehicle attribute
kpick 224768 # sepol: hostapd is now hal_wifi_hostapd

# device/samsung/kltechnduo

# device/samsung/klte-common
kpick 227732 # klte-common: Make the external camera provider ignore internal cameras
kpick 225192 # klte-common: Align ril.h to samsung_msm8974-common P libril changes
kpick 224917 # DO NOT MERGE: klte-common: Requisite bring-up BS change

# device/samsung/msm8974-common
kpick 226070 # msm8974-common: Allow additional gralloc 1.0 buffer usage bits
kpick 227730 # msm8974-common: Disable USB host mode
kpick 227731 # msm8974-common: Use Lineage overlays too
kpick 225466 # msm8974-common: libril: Remove LOCAL_CLANG
kpick 225467 # msm8974-common: libril: Fix Const-Correctness for RIL_RadioFunctions
kpick 225468 # msm8974-common: libril: Remove unused code
kpick 225469 # msm8974-common: libril: Fix double freeing of memory in SAP service and add null-checks.
kpick 225470 # msm8974-common: libril: Store the system time when NITZ is received.
kpick 225471 # msm8974-common: libril: Add DISABLE_RILD_OEM_HOOK.
kpick 225472 # msm8974-common: libril: Change rild initial sequence to guarantee non-null function pointer before rild register its hidl service
kpick 225473 # msm8974-common: libril: Add SIM_ABSENT error
kpick 225759 # msm8974-common: libril: Replace strncpy with strlcpy.
kpick 225760 # msm8974-common: libril: FR51015: Tuning of Binder buffer for rild.
kpick 224916 # DO NOT MERGE: msm8974-common: sepolicy: Just make it build

# device/samsung/qcom-common

# kernel/samsung/msm8974

# external/bash
kpick 224023 # bash: don't spam errors on warnings

# external/f2fs-tools
kpick 225223 # Merge remote-tracking branch 'aosp/master' into lineage-16.0
kpick 225224 # Android.mk: update strings to reflect v1.11.0 release

# external/htop
kpick 225161 # htop: disable warnings that cause errors

# external/libncurse
kpick 224022 # libncurses: don't spam warnings as errors

# external/nano
kpick 224030 # nano: don't spam warnings as errors

# external/openssh
kpick 224032 # openssh: Update for pie boringssl
kpick 224033 # openssh: don't spam warnings as errors

# external/p7zip
kpick 224028 # p7zip: Cleanup if statement braces, whitespace lines, and ifs without paranthesis)
kpick 224029 # p7zip: don't spam warnings as errors

# external/perfetto
kpick 223413 # perfetto_cmd: Resolve missing O_CREAT mode

# external/pigz
kpick 224025 # pigz: don't spam warnings as errors

# external/rsync
kpick 224024 # rsync: don't spam warnings as errors

# external/tinycompress
kpick 225762 # tinycompress: enable libtinycompress_vendor
kpick 225763 # tinycompress: Use sanitized headers generated from kernel source
kpick 223008 # tinycompress: tinycompress fixes

# external/toybox

# external/unrar
kpick 224027 # unrar: don't spam warnings as errors

# external/vim
kpick 224031 # vim: don't spam warnings as errors

# external/zip
kpick 224026 # zip: don't spam warnings as errors

# external/zlib
kpick 225237 # zlib: Fix build under Android 6.0 and higher
kpick 225238 # minizip: Clean up the code
kpick 225239 # zlib: crc optimization for arm64

# frameworks/av
kpick 225530 # camera: Workaround for GCC-compiled HAL3 drivers
kpick 225531 # soundtrigger: fill in default extras from dsp
kpick 225532 # Camera: CameraHardwareInterface changes to support Extended FD
kpick 225533 # camera: Only link and use vendor.qti.hardware.camera.device if specified
kpick 225534 # libstagefright: encoder must exist when source starting
kpick 225535 # Camera: Add extensions to CameraClient
kpick 225536 # Camera: Add support for preview frame fd
kpick 225537 # libstagefright: Add more sample rates for FLAC
kpick 225539 # Camera:CameraService: Added lock on mHIDLMemPoolId in QDataCallback..
kpick 225540 # Camera: CameraHardwareInterface: Releasing mHIDLMemoryMapLock in QdataCallback
kpick 225746 # Camera: Handle duplicate camera Id due to openLegacy support
kpick 226592 # camera/parameters: Take device specific headers into account
kpick 227430 # Revert "libcameraservice: Disable external provider for legacy HAL1"
kpick 227433 # Explicitly initialise base class in copy constructor

# frameworks/base
kpick 224266 # SystemUI: Add Lineage statusbar item holder
kpick 224267 # SystemUI: Network Traffic [1/3]
kpick 224446 # SystemUI: Make tablets great again
kpick 224513 # SystemUI: Disable config_keyguardUserSwitcher on sw600dp
kpick 224844 # lockscreen: Add option for showing unlock screen directly
kpick 225582 # [TEMP]: Revert "OMS: harden permission checks"
kpick 225983 # Runtime toggle of navbar
kpick 225606 # Forward port 'Swap volume buttons' (1/3)
kpick 225650 # Configurable 0, 90, 180 and 270 degree rotation
kpick 225685 # frameworks: Power menu customizations
kpick 225680 # SystemUI: Allow overlaying max notification icons
kpick 225682 # Framework: Volume key cursor control
kpick 225683 # PhoneWindowManager: add LineageButtons volumekey hook
kpick 225684 # Long-press power while display is off for torch
kpick 225691 # SystemUI: Don't vibrate on touchscreen camera gesture
kpick 225692 # framework: move device key handler logic, fix gesture camera launch
kpick 225693 # SystemUI: add left and right virtual buttons while typing
kpick 225702 # Camera: allow camera to use power key as shutter
kpick 225721 # Reimplement hardware keys custom rebinding
kpick 225722 # Reimplement device hardware wake keys support
kpick 225726 # PhoneWindowManager: Tap volume buttons to answer call
kpick 225727 # PhoneWindowManager: Implement press home to answer call
kpick 225728 # Camera button support
kpick 225729 # Framework: Forward port Long press back to kill app (2/2)
kpick 225734 # Allow screen unpinning on devices without navbar
kpick 225754 # SystemUI: Berry styles
kpick 225799 # SystemUI: fix toggling lockscreen rotation [1/3]
kpick 225859 # storage: Do not notify for volumes on non-removable disks
kpick 226068 # Fix mounting of non-FAT formatted SD cards (1/2)
kpick 226236 # SystemUI: add navbar button layout inversion tuning
kpick 226249 # fw/b: Allow customisation of navbar app switch long press action
kpick 226276 # power: Re-introduce custom charging sounds
kpick 226343 # CameraServiceProxy: Loosen UID check
kpick 226354 # Camera: Add feature extensions
kpick 226358 # settings: Allow accessing LineageSettings via settings command
kpick 226398 # frameworks: base: Port password retention feature
kpick 226399 # Use fdeCheckPassword error code to indicate pw failure
kpick 226400 # LockSettingsService: Support for separate clear key api
kpick 226401 # AppOps: track op persistence by name instead of id
kpick 226587 # Camera: Expose Aux camera to apps present in the whitelist
kpick 226588 # camera: Check if aux camera whitelist is set before restricting cameras
kpick 226600 # PhoneWindowManager: Check if proposed rotation is in range
kpick 226615 # NavigationBarView: Avoid NPE before mPanelView is created
kpick 227108 # SystemUI: Fix several issues in the ADB over Network tile
kpick 227290 # PowerProfile: allow overriding default power profile
kpick 227291 # [DNM] Revert "Handle public volumes and otherwise invalid UUIDs."
kpick 227820 # PhoneWindowManager: Allow torch and track skip during ambient display
kpick 227821 # GlobalScreenshot: Fix screenshot not saved when appending appname with some languages
kpick 227839 # storage: Set all sdcards to visible
kpick 227896 # SystemUI: Add Profiles tile

# frameworks/native
kpick 224443 # libbinder: Don't log call trace when waiting for vendor service on non-eng builds
kpick 224530 # Triple the available egl function pointers available to a process for certain Nvidia devices.
kpick 225542 # sensorservice: Register orientation sensor if HAL doesn't provide it
kpick 225543 # sensorservice: customize sensor fusion mag filter via prop
kpick 225544 # input: Adjust priority
kpick 225545 # Forward port 'Swap volume buttons' (2/3)
kpick 225546 # AppOpsManager: Update with the new ops
kpick 225827 # libui: Allow extension of valid gralloc 1.0 buffer usage bits

# frameworks/opt/telephony
kpick 223774 # telephony: Squashed support for simactivation feature

# hardware/boardcom/libbt
kpick 225146 # libbt: Only allow upio_start_stop_timer on 32bit arm
kpick 225147 # libbt: Add btlock support
kpick 225148 # libbt: Add prepatch support
kpick 225149 # libbt: Add support for using two stop bits
kpick 225155 # Broadcom BT: Add support fm/bt via v4l2.
kpick 225816 # libbt-vendor: add support for samsung bluetooth
kpick 226447 # libbt: Make sure that we don't load pre-patch when looking for patch

# hardware/boardcomm/wlan

# hardware/interfaces
kpick 224064 # Revert "Bluetooth: Remove random MAC addresses"
kpick 225506 # Camed HAL extension: Added support in HIDL for Extended FD.
kpick 225507 # camera: Only link and use vendor.qti.hardware.camera.device if specified
kpick 226402 # keymasterV4_0: Tags support for FBE wrapped key.

# hardware/libhardware
kpick 223097 # hardware/libhw: Add display_defs.h to declare custom enums/flags
 
# hardware/libhardware_legacy

# hardware/lineage/interfaces
kpick 223374 # interfaces: Add 2.0 livedisplay interfaces
kpick 223410 # interfaces: Add touch HIDL interface definitions
kpick 223411 # interfaces: Add id HAL definition

# hardware/lineage/lineagehw

# hardware/nxp/nfc
kpick 223192 # nfc: Restore pn548 support to 1.1 HAL
kpick 223193 # nxp: Rename HAL to @1.1-service-nxp
kpick 223194 # nxp: Begin restoring pn547

# hardware/qcom/audio-caf/msm8974
kpick 223436 # Add -Wno-error to compile with global -Werror.

# hardware/qcom/bt-caf
kpick 226647 # libbt-qcom: Allow building without proprietary bits
kpick 226648 # libbt: Fix case where SoC type is not set
kpick 226649 # Bluetooth: load btaddr from NV if QCOM_BT_USE_BTNV is set
kpick 226650 # libbt-qcom: Allow reading BT address from property
kpick 226651 # Add vendor-specific message types for FM.
kpick 226652 # Remove hardcoded LOCAL_MODULE_PATHS from vendor components. (bt)
kpick 226653 # BT: Moving chipset version parameters' initialization out of ALOG
kpick 226654 # Apply the Cherokee's mechanism of stopping hci_filter to ROME
kpick 226655 # Add missing headers to libbt-vendor
kpick 226656 # Load bluetooth firmwares from /vendor
kpick 226658 # Don't build libbt-hidlclient for OSS builds
kpick 227449 # HIDL interface still uses ro.boot.btmacaddr, so stick to that
kpick 227450 # CAF forgot to add vendor prefix to a bluetooth.status prop


# hardware/qcom/display
kpick 223340 # Revert "msm8974: deprecate msm8974"
kpick 223341 # display: Always assume kernel source is present
kpick 223342 # display: add TARGET_PROVIDES_LIBLIGHT
kpick 223343 # msm8974: Move QCOM HALs to vendor partition
kpick 223344 # msm8974: hwcomposer: Fix regression in hwc_sync
kpick 223345 # msm8974: libgralloc: Fix adding offset to the mapped base address
kpick 223346 # msm8974: libexternal should depend on libmedia
kpick 224958 # msm8960/8974: Include string.h where it is necessary
kpick 226419 # msm8960/74/94: Move GRALLOC_USAGE_PRIVATE_UNCACHED

# hardware/qcom/display-caf/msm8974
kpick 223435 # Add -Wno-error to compile with global -Werror.
kpick 226422 # gralloc: Move GRALLOC_USAGE_PRIVATE_UNCACHED
kpick 226481 # display: remove compile time warnings
kpick 226482 # display: Enable clang for all display modules

# hardware/qcom/display-caf/msm8998

# hardware/qcom/fm
kpick 226683 # Partially revert "FM: QSSI changes"
kpick 226684 # Drop BOARD_HAVE_QCOM_FM flag
kpick 226685 # jni: fix calibration data path for legacy fm_qsoc_patches
kpick 226686 # libfm_jni: Skip loading FM firmware if requested
kpick 226687 # libfm_jni: Do not come here unless QCOM_HARDWARE is in use
kpick 226688 # libfm_jni: Add support for internal antenna hardware
kpick 226689 # libfm_jni: Improve and fix FM jni logs
kpick 226690 # libfm_jni: Confine the firmware-load skipping to the actual loading
kpick 226691 # jni: Skip loading FM firmware if requested
kpick 226692 # jni: Confine the firmware-load skipping to the actual loading
kpick 226693 # Allow library to be used by apps directly
kpick 226694 # Break bootclasspath dependency
kpick 226695 # fmapp2: new launcher icon by LeopardSurd
kpick 226696 # FMRadio : Re-vamp UI
kpick 226697 # Fm : Restore seek arrows
kpick 226698 # Fm : Make default country an overlay
kpick 226699 # FmRadio : Re-add RDS fields to UI
kpick 226700 # Scanned frequencies are saved in ascending ordering
kpick 226701 # FMRadio : Call unregister in onPause
kpick 226702 # FMRadio : Switch file extension to aac
kpick 226703 # FM: Add property to force use internal antenna
kpick 226704 # FM: Cleanup resources
kpick 226705 # FMRadio: add Indonesia
kpick 226706 # New Material icon
kpick 226707 # FM: fixup strings
kpick 226708 # FM2: materialize
kpick 226709 # FM: retune last frequency when resume after call
kpick 226710 # FM: always use overlay default country
kpick 226711 # FM: Store tag num/value in sequence
kpick 226712 # FM: reenable radio text visibility after station info updated
kpick 226713 # FMRadio : Launch station list automatically after scan
kpick 226714 # FM: respect hw.fm.internal_antenna
kpick 226715 # FM: fix mRadioTextScroller usage in transmitter activity
kpick 226716 # Fix status text to reflect when FM is enabled.
kpick 226717 # FM: The collect channel disappear when quit FM
kpick 226718 # FMRadio : Ensure scan state is kept in sync
kpick 226719 # FMRadio : Keep track of scanned frequencies in service
kpick 226720 # FMRadio : Select band based on country
kpick 226721 # FMRadio : cleaned up band selection code
kpick 226722 # FMRadio : improved band selection
kpick 226723 # FMRadio : Localization of band types
kpick 226724 # FMRadio : Fix settings UI bugs
kpick 226725 # FMRadio : Fix headphone icon
kpick 226726 # Fm : Update India bands
kpick 226727 # fmapp2: String improvements
kpick 226728 # fmapp2: Allow value for the default fm recording duration to be overlayed.
kpick 226729 # Convert regional band arrays to string references
kpick 226730 # Revert "Disable libfm_jni"
kpick 226731 # Use BOARD_HAVE_QCOM_FM flag
kpick 226732 # FM: Use some sane colors
kpick 226733 # FM: Fix helium hal build
kpick 226734 # FM: Fix KHz->kHz
kpick 226735 # FM2: Convert FM transmitter notifications to use NotificationChannel
kpick 226736 # FM2: Revamp notifications
kpick 226737 # libfm_jni: Fix strchr implicit char* typecast in ConfFileParser
kpick 226738 # libfm_jni: Add jni core headers dependency
kpick 226739 # Do not link to android.hidl.base@1.0
kpick 226740 # FM: adaptive icon
kpick 226741 # fm: Resolve required dependency qcom.fmradio.xml linkage
kpick 226742 # libfm_jni: Remove unused variables
kpick 226743 # libfm_jni: Resolve fread assignment to condition cast
kpick 223685 # libfm_jni: Resolve FM_DEVICE_PATH R/O open flag
kpick 226744 # libfm_jni: Ignore unused parameters from APIs
kpick 226745 # fm_hci/helium: Exclude from OSS builds
kpick 223678 # libfm_jni: use proper nativehelper headers
kpick 223683 # jni: Remove unused variables
kpick 223684 # jni: Resolve equality comparisons with extraneous parentheses
kpick 226862 # jni: Resolve FM_DEVICE_PATH R/O open flag
kpick 223686 # jni: Ignore unused parameters from APIs
kpick 223687 # jni: Resolve V4L2_CID_AUDIO_MUTE redefinitions
kpick 223692 # jni: Resolve -Wwritable-strings warnings in helium FW library variables
kpick 223688 # fmapp2: Set LOCAL_PRIVATE_PLATFORM_APIS
kpick 224246 # jni: Resolve unused and uninitialized variable errors
kpick 224386 # libfm_jni: Resolve unused and uninitialized variable errors

# hardware/qcom/gps
kpick 223351 # Revert "msm8974: deprecate msm8974"
kpick 223352 # Revert "msm8974: remove from top level makefile"
kpick 223353 # msm8974: Add missing liblog dependency
kpick 223354 # msm8974: Default apn ip type to ipv4
kpick 223355 # msm8974: Cleanup obsolete LOCAL_PRELINK_MODULE
kpick 223356 # msm8974: Move device dependent modules to /vendor
kpick 223357 # msm8974: Fix duplicate gps.conf for hammerhead
kpick 223358 # msm8974: Fix logging level and remove nmea log
kpick 223359 # msm8974: Don't rely on transitively included headers
kpick 223360 # msm8974: Return the correct length of nmea sentence
kpick 225034 # msm8974: Add -Wno-error to compile with global -Werror.

# hardware/qcom/media
kpick 224289 # Add -Wno-error to compile with global -Werror.
kpick 222695 # media: Add missing links
kpick 224305 # media: Use kernel headers
kpick 224955 # Revert "msm8974: remove from top level makefile"
kpick 224956 # mm-video: venc: Correct a typo in variable name
kpick 224957 # media: vdec: Include nativebase headers

# hardware/qcom/media-caf/msm8974
kpick 223441 # Add -Wno-error to compile with global -Werror.
kpick 227823 # mm-video-v4l2: Protect buffer access and increase input buffer size

# hardware/qcom/power
#kpick 223892 # power: Add power hint to set profile

# hardware/qcom/wlan-caf
kpick 226638 # wcnss_qmi: Generate a fixed random mac address if the NV doesn't provide one
kpick 226639 # wcnss_service: Deal with mdm-detect too
kpick 226640 # wifi-hal: Only try LOWI once
kpick 226641 # wifi-hal: stop the UMAC logspam
kpick 226642 # Wifi: Quiet some excessive debug output
kpick 226643 # wcnss_service: Read serial number from custom property
kpick 226645 # Make wcnss_service build with the VNDK.

# hardware/ril-caf
kpick 227612 # Merge 767770dcffb7a6553d25740d2975b6e201f592be on remote branch
kpick 227613 # Merge a1dd1f0aaf0a52f479d307557cd1f594c7c45d8f on remote branch
kpick 227614 # Disable IOemHook implemenation in rild.
kpick 227615 # Snap for 4955954 from 08781f88bb6159d3ebb0d48b569204295129460a to p-keystone-qcom-release
kpick 227616 # Merge 845f6b7eb0fe4a1a1883129dd341c7bf6fb469cd on remote branch
kpick 227617 # Merge tag 'LA.UM.7.4.r1-03000-8x98.0' into lineage-16.0-caf

# hardware/samsung
kpick 225628 # Sending empty strings instead of NULL for some RIL requests
kpick 225629 # libril: Remove LOCAL_CLANG
kpick 225630 # libril: Fix Const-Correctness for RIL_RadioFunctions
kpick 225631 # libril: Remove unused code
kpick 225632 # libril: Fix double freeing of memory in SAP service and add null-checks.
kpick 225633 # libril: Store the system time when NITZ is received.
kpick 225634 # libril: Add DISABLE_RILD_OEM_HOOK.
kpick 225635 # libril: Change rild initial sequence to guarantee non-null function pointer before rild register its hidl service
kpick 226075 # libril: remove unused variables/functions
kpick 226076 # libsecril-client-sap: remove unused variables
kpick 226077 # libsecril-client: remove unused variables/functions
kpick 226080 # libril: Replace strncpy with strlcpy.
kpick 227453 # power: remove getFeature functionality
kpick 227454 # power: Add Lineage power hints


# kernel/samsung/msm8974

# lineage-sdk
#kpick 223137 # lineage-sdk: Comment out LineageAudioService
kpick 225581 # lineage-sdk: Make styles init at system services ready
kpick 225687 # PowerMenuConstants: Add user logout as new global action
kpick 226087 # lineage-sdk: Default config_deviceHardware{Wake}Keys to 64
kpick 226141 # LineageSettingsProvider: Cleanup after LINEAGE_SETUP_WIZARD_COMPLETED deprecation

# packages/apps/AudioFX

# packages/apps/Calender

# packages/apps/Camera2
kpick 224752 # Use mCameraAgentNg for getting camera info when available
kpick 225255 # Camera2: Target API 27
kpick 225256 # Don't attempt to convert degree to orientation enum twice
kpick 225257 # Camera2: Only autofocus before a snap if we are actually in "auto" mode.
kpick 225258 # Camera2: Remove settings preferences only once
kpick 225259 # Camera2: Stop using GPS when going to background
kpick 225260 # Camera: Powerkey shutter (2/2)
kpick 225261 # Camera2: Add option to set max screen brightness
kpick 225262 # Camera2: Remove google help preference
kpick 225263 # Camera2: Fix Undo button behaviour
kpick 225264 # Fix crash if Exif-Tag buffer-length and component-count are both 0
kpick 225265 # Add Storage preference (1/2)

# packages/apps/CarrierConfig
kpick 225266 # CarrierConfig: Add selected configs for national roaming
kpick 225267 # CarrierConfig: Load ERI configuration for U.S. Cellular
kpick 225268 # Disable OTA for U.S. Cellular since there is no need for it
kpick 225269 # CarrierConfig: HoT and tele.ring (232 07) may roam on T-Mobile (232 03)

# packages/apps/Contacts
kpick 225272 # Contacts: Enable support for device contact.
kpick 225273 # Place MyInfo shortcut on drawer
kpick 225274 # Place EmergencyInfo shortcut on drawer
kpick 225275 # Contacts: update splash screen to match the new icon
kpick 225276 # Allow calling contacts via specific phone accounts.

# packages/apps/DeskClock
kpick 225281 # DeskClock: Add back flip and shake actions
kpick 225280 # Make new menu entry to link to cLock widget settings.
kpick 225284 # Provide upgrade path for cm-14.1 -> lineage-15.1

# packages/apps/Dialer
kpick 224712 # Dialer: disable anti-falsing for call answer screen
kpick 226094 # Revert "Remove dialer sounds and vibrations settings fragments and redirect to the system sound settings fragment instead."
kpick 226095 # Add back in-call vibration features
kpick 226096 # Allow using private framework API.
kpick 226097 # Re-add dialer lookup.
kpick 226098 # Dialer: comply with EU's GDPR
kpick 226099 # Generalize the in-call vibration settings category
kpick 226100 # Add setting to enable Do Not Disturb during calls
kpick 226101 # Re-add call recording.
kpick 226102 # Allow per-call account selection.
kpick 226103 # Re-add call statistics.
kpick 226395 # Dialer: handle database upgrade from cm-14.1

# packages/apps/DocumentsUI
kpick 225289 # DocumentsUI: support night mode

# packages/apps/Email
kpick 225292 # Email: handle databases from cm-14.1
kpick 225294 # Allow account deletion.
kpick 225295 # email: support for auto-sync multiple IMAP folders
kpick 225296 # email: Add an ActionBar to the mail app's PreferenceActivity
kpick 225297 # email: support per-folder notifications
kpick 225298 # Rewrite MailboxSettings loading logic.
kpick 225299 # email: fix eas autodiscover
kpick 225300 # Implement IMAP push using IMAP IDLE.
kpick 225301 # Request battery optimization exemption if IMAP IDLE is used.
kpick 225302 # Fix crash when attempting to view EML files.
kpick 225303 # Allow download of compressed attachments.
kpick 225304 # email: fix empty body update
kpick 225305 # Improve notification coalescence algorithm.
kpick 225306 # Email: Fix the ActivityNotFoundException when click "Update now"
kpick 225307 # Email: Clean duplicated WRITE_CONTACTS permission
kpick 225308 # email: return default folder name for subfolders
kpick 225309 # email: junk icon
kpick 225310 # Search in folder specified via URI parameter, if possible.
kpick 225311 # Remove max aspect ratio.

# packages/apps/ExactCalculator

# packages/apps/FlipFlap

# packages/apps/Gallery2

# packages/apps/LineageParts
kpick 226141 # LineageSettingsProvider: Cleanup after LINEAGE_SETUP_WIZARD_COMPLETED deprecation
kpick 226145 # LineageParts: Reenable buttons related settings
kpick 226390 # PowerMenuActions: Make to sure to enable setting lockdown setting
kpick 226392 # LineageParts: Set proper default value for charging sounds
kpick 226863 # LineageParts: Drop  setting

# packages/apps/LockClock

# packages/apps/Message
kpick 225317 # Messaging: Implement option for swipe right to delete.
kpick 225318 # Messaging: change Avatar fontFamily to sans-serif-medium
kpick 225319 # MessageQueue: Process pending messages per subscription
kpick 225321 # Messaging: Toggable keyboard emoticons access
kpick 225323 # Fix menu item highlight color.
kpick 225324 # Messaging App is crashing when storage memory is full
kpick 225325 # Messaging: bring back accent color
kpick 225326 # Messaging: Implement saved video attachments in MMS
kpick 225327 # Play an audible notification on receiving a class zero message.
kpick 225328 # Added support for video and audio mms attachments
kpick 225329 # Fixed storage permission issue for attachments
kpick 225330 # Messaging app crashes after a few MMS
kpick 225331 # Use app settings for conversation settings if no custom set
kpick 225332 # Messaging: fix bad recycle on sending two mms in a row
kpick 225333 # MediaPicker: Check for NPE
kpick 225337 # Messaging: Don't crash on unsupported shared content type

# packages/apps/Nfc
kpick 223700 # NFC: Adding new vendor specific interface to NFC Service

# packages/apps/Profiles

# packages/apps/Recorder

# packages/apps/Settings
kpick 224615 # deviceInfo: Fix imei dialog fc when only 1 sim is inserted
kpick 225570 # Settings: Add LineageParts charging sound settings preference
kpick 224973 # Settings: gesture: Add LineageParts touchscreen gesture settings
kpick 224974 # Settings: Allow devices to provide remote gesture preferences
kpick 225686 # Settings: Add advanced restart switch
kpick 225730 # Settings: Add kill app back button toggle
kpick 225755 # Settings: Hide AOSP theme-related controllers
kpick 225756 # Settings: fix dark style issues
kpick 225800 # Settings: Add rotation settings
kpick 225858 # storage: Do not allow eject for volumes on non-removable disks
kpick 226142 # Settings: Add developer setting for root access
kpick 226148 # Settings: "Security & location" -> "Security & privacy"
kpick 226150 # Settings: add Trust interface hook
kpick 226151 # Settings: show Trust brading in confirm_lock_password UI
kpick 226154 # fingerprint: Allow devices to configure sensor location
kpick 226391 # Settings: Hide lockdown in lockscreen settings
kpick 227120 # Settings: Check interfaces before enabling ADB over network
kpick 227795 # Settings: Hide unsupported USB modes automatically
kpick 227834 # FingerprintEnrollFindSensor: Don't overlay front for side sensors

# packages/apps/SetupWizard

# packages/apps/Stk

# packages/apps/Terminal
kpick 226269 # TerminalKeys: Disable debug
kpick 226270 # Allow terminal app to show in LeanBack (1/2)
kpick 226271 # Terminal: Fix keyboard Ctrl- and ALT-key input.
kpick 226272 # Add settings for fullscreen, orientation, font size, color
kpick 226273 # Allow access to external storage
kpick 226274 # Term: materialize
kpick 226275 # Terminal: volume keys as up/down


# packages/apps/Trebuchet
kpick 223666 # Settings: Hide Notification Dots on low RAM devices

# packages/apps/UnifiedEmail
kpick 225343 # unified email: prefer account display name to sender name
kpick 225344 # email: fix back button
kpick 225345 # unified-email: check notification support prior to create notification objects
kpick 225346 # unified-email: respect swipe user setting
kpick 225347 # email: linkify urls in plain text emails
kpick 225348 # email: do not close the input attachment buffer in Conversion#parseBodyFields
kpick 225349 # email: linkify phone numbers
kpick 225350 # Remove obsolete theme.
kpick 225351 # Don't assume that a string isn't empty
kpick 225352 # Add an ActionBar to the mail app's PreferenceActivity.
kpick 225353 # email: allow move/copy operations to more system folders
kpick 225354 # unifiedemail: junk icon
kpick 225355 # Remove mail signatures from notification text.
kpick 225356 # MimeUtility: ensure streams are always closed
kpick 225357 # Fix cut off notification sounds.
kpick 225358 # Pass selected folder to message search.
kpick 225359 # Properly close body InputStreams.
kpick 225360 # Make navigation drawer extend over status bar.
kpick 225361 # Disable animations for translucent activities.
kpick 225362 # Don't re-show search bar on query click.

# packages/apps/Updater

# packages/apps/WallpaperPicker
kpick 225363 # WallpaperPicker: bump gradle
kpick 225365 # WallpaperPicker: materialize delete icon
kpick 225367 # WallpaperPicker: Update for wallpaper API changes
kpick 225370 # WallpaperPicker: add a "No Wallpaper" option
kpick 225369 # WallpaperPicker: Add icon near dialog items
kpick 225371 # WallpaperPicker: Move strings for translation
kpick 225372 # WallpaperPicker: 15.1 wallpapers

# packages/inputmethods/LatinIME
kpick -t pie-keyboard

# packages/providers/CallLogProvider

# packages/provider/ContackProvider
kpick 225408 # ContactsProvider: Prevent device contact being deleted.
kpick 225409 # CallLogDatabase: Bump the version and try to re-run the version 5 upgrade path

# packages/providers/DownloadProvider

# packages/providers/MediaProvider
kpick 225412 # Fix mounting of non-FAT formatted SD cards (2/2)

# packages/providers/TelephonyProvider
kpick 226394 # TelephonyProvider: add upgrade support from cm-14.1

# packages/services/Telecomm
kpick 226093 # Telecomm: Make sensitive phone numbers not to be shown in call log history.

# packages/services/Telephony
kpick 225420 # Use proper summary for network select list preference on dsds/dsda/tsts

# system/bt
kpick 223945 # Prevent abort in case of command timeout
kpick 224813 # bt: osi: undef PROPERTY_VALUE_MAX
kpick 225422 # Bluetooth: Read BLE vendor capability to proceed on Secure conn
kpick 225423 # Add support to force disable enhanced sco commands

# system/core
privpick system/core refs/changes/19/206119/2 # init: I hate safety net
kpick 223085 # adbd: Disable "adb root" by system property (2/3)
kpick 224264 # debuggerd: Resolve tombstoned missing O_CREAT mode
kpick 226119 # libion: save errno value
kpick 226120 # fs_mgr: Wrapped key support for FBE
kpick 226193 # Show bootanimation after decrypt
#kpick 226917 # Switch root to /system in first stage mount
#kpick 226923 # init: First Stage Mount observe nofail mount flag

# system/extras
kpick 225426 # f2fs_utils: Add a static libf2fs_sparseblock for minvold
kpick 225427 # ext4_utils: Fix FS creation for filesystems with exactly 32768 blocks.
cd system/extras/
git stash >/dev/null
git clean -xdf >/dev/null
cd $topdir
kpick 225428 # extras: remove su
if [ -d $topdir/system/extras/su ]; then
   cd $topdir/system/extras/su
   git stash >/dev/null
fi
repo sync --force-sync system/extras/su

# system/extras/su

# system/libvintf
kpick 226922 # System always contains root dir.

# system/netd

# system/sepolicy
kpick 223746 # Add rules required for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 223748 # Build sepolicy tools with Android.bp.

# system/tool/aidl
kpick 223133 # AIDL: Add option to generate No-Op methods

# system/update/engine
kpick 225430 # update_engine: run backuptool script before normal postinstall script

# system/vold
kpick 225436 # vold: add support for more filesystems for public storage
kpick 225437 # vold: Fix fsck on public volumes
kpick 225438 # vold: Support internal storage partitions
kpick 225439 # vold: Honor mount options for ext4 partitions
kpick 225440 # vold: Honor mount options for f2fs partitions
kpick 225441 # vold: Mount ext4/f2fs portable storage with sdcard_posix
kpick 225442 # vold: ntfs: Use strlcat
kpick 225443 # Treat removable UFS card as SD card
kpick 225444 # vold: dont't use commas in device names
kpick 225445 # vold ext4/f2fs: do not use dirsync if we're mounting adopted storage
kpick 225446 # Fix the group permissions of the sdcard root.
kpick 225447 # vold: skip first disk change when converting MBR to GPT
kpick 225448 # vold: Allow reset after shutdown
kpick 225449 # vold: Accept Linux GPT partitions on external SD cards
kpick 225450 # vold: Make sure block device exists before formatting it
kpick 225451 # vold: Also wait for dm device when mounting private volume
kpick 225452 # secdiscard: should pin_file to avoid moving blocks in F2FS
kpick 225881 # vold: Make exfat driver support generic
kpick 225948 # Support Samsung's implementation of exfat, called sdfat
kpick 226109 # vold: Add Hardware FDE feature
kpick 226110 # system: vold: Remove crypto block device creation
kpick 226127 # vold: Move QCOM HW FDE inclusion under lineage namespace
kpick 226111 # vold: Wrapped key support for FBE

# vendor/lineage
kpick 223773 # Add IPv6 for Oister and 3. The 3.dk and oister.dk carriers now support IPv6 with the APN ”data.tre.dk”.
kpick 224828 # vendor/lineage: Add support for java source overlays
kpick 224758 # overlay/common: Unlock swipe gesture nav bar
kpick 225882 # soong_config: Add TARGET_EXFAT_DRIVER variable
kpick 225921 # overlay: Update list of GSF/GMS activities
kpick 225938 # roomservice.py: document the hell out of the current behavior of the script
kpick 225865 # soong_config: Allow extension of valid gralloc 1.0 buffer usage bits
#kpick 225978 # soong_config: Remove extra spacing
kpick 225939 # roomservice.py: non-depsonly: bootstrap first device repo from Hudson
#kpick 225981 # roomservice.py: depsonly: do not look up device repo by name in the manifest
#kpick 225982 # roomservice.py: Strip cm.{mk,dependencies} support
kpick 226123 # soong_config: Add new flags for HW FDE
kpick 226125 # soong_config: Add flag for legacy HW FDE
kpick 226126 # soong_config: Add flag for crypto waiting on QSEE to start
kpick 226184 # soong_config: Allow process-specific override of target SDK version
kpick 226443 # soong: Add additional_deps attribute for libraries and binaries
kpick 226444 # soong: Add generated_headers module alias
kpick 226591 # soong: Add support for target specific headers

# vendor/qcom/opensource/audio

# vendor/qcom/opensource/cryptfs/hw
kpick 226128 # cryptfs_hw: Add compatibility for pre-O hw crypto
kpick 226129 # cryptfs_hw: Featureize support for waiting on QSEE to start
kpick 226130 # cryptfs_hw: add missing logging tag
kpick 226403 # cryptfs_hw: Remove unused variable
kpick 226404 # [TEMP]: Header hack to compile for 8974

#-----------------------
# translations

##################################
echo
echo "---------------------------------------------------------------"
read -n1 -r -p "  Picking remote changes finished, Press any key to continue..." key

[ $op_pick_remote_only -eq 0 ] && patch_local local
[ -f $script_file.tmp ] && mv $script_file.tmp $script_file.new
[ -f $topdir/.mypatches/rr-cache/rr-cache.tmp ] && \
   mv $topdir/.mypatches/rr-cache/rr-cache.tmp $topdir/.mypatches/rr-cache/rr-cache.list
rrCache backup # backup rr-cache

