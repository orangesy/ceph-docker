#!/bin/bash

declare -r LOG_DEFAULT_COLOR="\033[0m"
declare -r LOG_ERROR_COLOR="\033[1;31m"
declare -r LOG_INFO_COLOR="\033[1m"
declare -r LOG_SUCCESS_COLOR="\033[1;32m"
declare -r LOG_WARN_COLOR="\033[1;35m"

function log() {
  local log_text="$1"
  local log_level="$2"
  local log_color="$3"

  # Default level to "info"
  [[ -z ${log_level} ]] && log_level="INFO";
  [[ -z ${log_color} ]] && log_color="${LOG_INFO_COLOR}";

  echo -e "${log_color}[$(date +"%Y-%m-%d %H:%M:%S")] [${log_level}] ${log_text} ${LOG_DEFAULT_COLOR}";
  return 0;
}

function log_info() { log "$@"; }
function log_success() { log "$1" "SUCCESS" "${LOG_SUCCESS_COLOR}"; }
function log_err() { log "$1" "ERROR" "${LOG_ERROR_COLOR}"; }
function err_status() { log "$1" "ERROR & WAIT" "${LOG_ERROR_COLOR}"; echo "$1" >/status; /usr/bin/tail -f /dev/null; }
function success_status() { echo "$1" >/status; }
function log_warn() { log "$1" "WARN" "${LOG_WARN_COLOR}"; }

function check_mon {
  CLUSTER_PATH=ceph-config/${CLUSTER}
  : ${K8S_IP:=${KV_IP}}
  : ${K8S_PORT:=8080}
  check_mon_data_version
  check_single_mon
}

function check_mon_data_version {
  timeout 20 ceph ${CEPH_OPTS} health || return 0

  if [ ! -e /var/lib/ceph/mon/${CLUSTER}-${MON_NAME}/keyring ]; then
    return 0
  fi

  ceph-mon -i ${MON_NAME} --extract-monmap /tmp/monmap
  local local_version=$(monmaptool -p /tmp/monmap  | awk '/^epoch/ {print $2}')
  local cluster_version=$(ceph ${CEPH_OPTS} mon dump | awk '/^epoch/ {print $2}')

  # if local mon data is old, remove it.
  if [ ${local_version} -lt ${cluster_version} ]; then
    # cd /var/lib/ceph/mon/ && tar jcf ${MON_NAME}-$(date +%s).tar.bz2 ${CLUSTER}-*
    rm -r /var/lib/ceph/mon/${CLUSTER}-${MON_NAME}
  elif [ ${local_version} -gt ${cluster_version} ]; then
    err_status "Monmap version in this container is newer then cluster's."
  fi
  rm /tmp/monmap
}

function check_single_mon {
  # check again. if ceph is health then leave.
  timeout 10 ceph ${CEPH_OPTS} health && return 0

  # if MON has single_mon label on K8S then enter single mode
  if kubectl get node --show-labels --server=${K8S_IP}:${K8S_PORT} | grep -w "${K8S_IP}" | grep -w "single_mon=true" >/dev/null; then
    ceph-mon -i ${MON_NAME} --extract-monmap /tmp/monmap

    # remove all monmap list then add itself
    local MONMAP_LIST=$(monmaptool -p /tmp/monmap | awk '/mon\./ { sub ("mon.", "", $3); print $3}')
    for del_mon in ${MONMAP_LIST}; do
      monmaptool --rm $del_mon /tmp/monmap
    done
    monmaptool --add ${MON_NAME} ${MON_IP}:6789 /tmp/monmap
    ceph-mon -i ${MON_NAME} --inject-monmap /tmp/monmap
    kubectl label node --server=${K8S_IP}:${K8S_PORT} ${K8S_IP} single_mon-
    rm /tmp/monmap
  fi
}

function mon_controller {
  CLUSTER_PATH=ceph-config/${CLUSTER}
  : ${MAX_MONS:=3}
  : ${K8S_IP:=${KV_IP}}
  : ${K8S_PORT:=8080}

  etcdctl -C ${KV_IP}:${KV_PORT} mkdir ${CLUSTER_PATH} > /dev/null 2>&1 || log_warn "CLUSTER_PATH already exists"
  etcdctl -C ${KV_IP}:${KV_PORT} set ${CLUSTER_PATH}/max_mons ${MAX_MONS} > /dev/null 2>&1
  etcdctl -C ${KV_IP}:${KV_PORT} mkdir ${CLUSTER_PATH}/mon_list > /dev/null 2>&1  || log_warn "mon_list already exists"

  # if node have ceph_mon=true label, then add it into mon_list.
  get_mon_label
  for node in ${nodes_have_mon_label}; do etcdctl -C ${KV_IP}:${KV_PORT} set ${CLUSTER_PATH}/mon_list/${node} ${node} >/dev/null 2>&1; log_success "Add ${node} to mon_list"; done

  while [ true ]; do
    get_mon_label
    check_mon_list
    sleep 60
  done
}

function check_mon_list {
  if [ "${MAX_MONS}" -eq "0" ]; then
    return 0
  fi

  until [ $(current_mons) -ge "${MAX_MONS}" ] || [ -z "${nodes_without_mon_label}" ]; do
    local node_to_add=$(echo ${nodes_without_mon_label} | awk '{ print $1 }')
    etcdctl -C ${KV_IP}:${KV_PORT} set ${CLUSTER_PATH}/mon_list/${node_to_add} ${node_to_add} >/dev/null 2>&1
    kubectl label node --server=${K8S_IP}:${K8S_PORT} ${node_to_add} ceph_mon=true --overwrite >/dev/null 2>&1 && log_success "Add ${node_to_add} to mon_list"
    get_mon_label
  done
}

function current_mons {
  etcdctl -C ${KV_IP}:${KV_PORT} ls ${CLUSTER_PATH}/mon_list | wc -l
}

function get_mon_label {
  nodes_have_mon_label=$(kubectl get node --show-labels --server=${K8S_IP}:${K8S_PORT} | awk '/Ready/ { print $1 " " $4 }' | awk '/ceph_mon=true/ { print $1 }')
  nodes_without_mon_label=$(kubectl get node --show-labels --server=${K8S_IP}:${K8S_PORT} | awk '/Ready/ { print $1 " " $4 }' | awk '!/ceph_mon=true/ { print $1 }')
}

function crush_initialization () {
  CLUSTER_PATH=ceph-config/${CLUSTER}

  # DO NOT EDIT DEFAULT POOL
  DEFAULT_POOL=rbd

  # Default crush leaf [ osd | host | rack] & replication size 1 ~ 9
  DEFAULT_CRUSH_LEAF=osd
  DEFAULT_POOL_COPIES=1
  DEFAULT_CRUSHMAP="/crushmap.bin"

  # set lock to avoid multiple node writting together
  until etcdctl -C ${KV_IP}:${KV_PORT} mk ${CLUSTER_PATH}/osd_init_lock ${HOSTNAME} > /dev/null 2>&1; do
    local LOCKER_NAME=$(kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/osd_init_lock)
    if [[ ${LOCKER_NAME} == ${HOSTNAME} ]]; then
      log_warn "Last time Crush Initialization is locked by ${HOSTNAME} itself."
      break
    else
      log_warn "Crush Initialization is locked by ${LOCKER_NAME}. Waiting..."
      sleep 3
    fi
  done

  # check complete status
  if kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/initialization_complete > /dev/null 2>&1 ; then
    log_success "We detected a complete status, no need to initialize."
  else

    # initialization of crushmap
    log_info "Initialization of crushmap"
    ceph ${CEPH_OPTS} osd setcrushmap -i ${DEFAULT_CRUSHMAP}

    # crush_ruleset 1 for host, 2 for osd, 3 for rack
    case ${DEFAULT_CRUSH_LEAF} in
      host)
        ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 0
        ;;
      osd)
        ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 1
        ;;
      rack)
        ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 2
        ;;
      *)
        log_warn "DEFAULT_CRUSH_LEAF not in [ osd | host | rack ], do nothing"
        ;;
    esac

    # Replication size of rbd pool
    # check size in the range 1 ~ 9
    local re='^[1-9]$'

    if ! [[ ${DEFAULT_POOL_COPIES} =~ ${re} ]]; then
      local size_defined_on_etcd=$(kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/global/osd_pool_default_size)
      ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size ${size_defined_on_etcd}
      log_warn "DEFAULT_POOL_COPIES is not in the range 1 ~ 9, using default value ${size_defined_on_etcd}"
    else
      ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size ${DEFAULT_POOL_COPIES}
    fi

    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} put ${CLUSTER_PATH}/initialization_complete true > /dev/null 2>&1
  fi

  log_info "Removing lock for ${HOSTNAME}"
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} del ${CLUSTER_PATH}/osd_init_lock > /dev/null 2>&1

}

function auto_change_crush () {
  # DO NOT EDIT DEFAULT POOL
  DEFAULT_POOL=rbd
  : ${CRUSH_TYPE:=1}
  : ${PGs_PER_OSD:=64}

  # set lock to avoid multiple node writting together
  until etcdctl -C ${KV_IP}:${KV_PORT} mk ${CLUSTER_PATH}/osd_crush_lock ${HOSTNAME} > /dev/null 2>&1; do
    local LOCKER_NAME=$(kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/osd_crush_lock)
    if [[ ${LOCKER_NAME} == ${HOSTNAME} ]]; then
      log_warn "Last time auto_change_crush is locked by ${HOSTNAME} itself."
      break
    else
      log_warn "Auto_change_crush is locked by ${LOCKER_NAME}. Waiting..."
      sleep 30
    fi
  done

  # NODES not include some host weight=0
  NODEs=$(ceph ${CEPH_OPTS} osd tree | awk '/host/ { print $2 }' | grep -v ^0$ -c || true)
  # Only count OSD that status is up
  OSDs=$(ceph ${CEPH_OPTS} osd stat | awk '{ print $5 }')
  # Put crush type into ETCD
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} put ${CLUSTER_PATH}/crush_type ${CRUSH_TYPE} >/dev/null 2>&1

  case ${CRUSH_TYPE} in
    0)
      log_success "Disable changing crush rule automatically"
      ;;
    1)
      MAX_COPIES=3
      crush_type1
      auto_change_crush_leaf ${MAX_COPIES}
      ;;
    2)
      MAX_COPIES=2
      crush_type2
      auto_change_crush_leaf ${MAX_COPIES}
      ;;
    *)
      log_warn "Definition of CRUSH_TYPE error. 0, 1 & 2 only"
      ;;
  esac

  log_info "Removing lock for ${HOSTNAME}"
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} del ${CLUSTER_PATH}/osd_crush_lock > /dev/null 2>&1
}

# auto change pg & crush leaf. Max replications is 3.
function crush_type1 () {
  # RCs not greater than 3
  if [ ${OSDs} -eq "0" ]; then
    log_warn "No OSD, do nothing with resizing RCs"
  elif [ ${OSDs} -lt "3" ]; then
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size ${OSDs}
  else
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size 3
  fi

  # multiple = OSDs / 3, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr ${OSDs} '+' 1)
  local multiple=$(expr ${prefix_multiple} '/' 3)
  if [ ${multiple} -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr ${PGs_PER_OSD} '*' ${multiple})
  set_pg_num ${DEFAULT_POOL} ${PG_NUM}
}

# auto change pg & crush leaf. Max replications is 2.
function crush_type2 () {
  # RCs not greater than 2
  if [ ${OSDs} -eq "0" ]; then
    log_warn "No OSD, do nothing with resizing RCs"
  elif [ ${OSDs} -eq "1" ]; then
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size 1
  else
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size 2
  fi

  # multiple = OSDs / 2, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr ${OSDs} '+' 1)
  local multiple=$(expr ${prefix_multiple} '/' 2)
  if [ ${multiple} -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr ${PGs_PER_OSD} '*' ${multiple})
  set_pg_num ${DEFAULT_POOL} ${PG_NUM}
}

# usage: auto_change_crush_leaf ${MAX_COPIES}
function auto_change_crush_leaf () {
  # crush_ruleset 0 for host, 1 for osd, 2 for rack
  if [ ${NODEs} -ge $1 ]; then
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 0
  else
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 1
  fi
}

function set_pg_num () {
  # $1 = pool_name, $2 = pg_num
   if ! ceph ${CEPH_OPTS} osd pool set $1 pg_num $2; then
     log_warn "Fail to Set pg_num of $1 pool"
     return 0
   fi

  # wait for pg_num resized and change pgp_num
  until [ $(ceph ${CEPH_OPTS} -s | grep creating -c) -eq 0 ]; do
    sleep 5
  done
  if ! ceph ${CEPH_OPTS} osd pool set $1 pgp_num $2; then
    log_warn "Fail to Set pgp_num of $1 pool"
    return 0
  fi
}

# setup/check require option and tool
function osd_controller_env () {
  : ${CLUSTER_PATH:=ceph-config/${CLUSTER}}
  command -v docker > /dev/null 2>&1 || { echo "Command not found: docker"; exit 1; }
  DOCKER_CMD=$(command -v docker)
  DOCKER_VERSION=$($DOCKER_CMD -v | awk  /Docker\ version\ /'{print $3}')
  # show docker version and check docker libraries load status
  if [[ -n "${DOCKER_VERSION}" ]]; then
    log_info "docker version ${DOCKER_VERSION}"
  else
    $DOCKER_CMD -v
    exit 1
  fi

  : ${OSD_FOLDER:="/var/lib/ceph/osd"}
  mkdir -p ${OSD_FOLDER}
  chown ceph. ${OSD_FOLDER}
  if [ -n "${OSD_MEM}" ]; then OSD_MEM="-m ${OSD_MEM}"; fi
  if [ -n "${OSD_CPU_CORE}" ]; then OSD_CPU_CORE="-c ${OSD_CPU_CORE}"; fi
}

# Start OSDs they are ready to run. (existing osds)
function osd_controller_init () {
  BUILD_FIRST_OSD=true

  # get all avail disks
  DISKS=$(get_avail_disks)

  if [ -z "${DISKS}" ]; then
    log_err "No available disk"
    return 0
  fi

  for disk in ${DISKS}; do
    if [ "$(is_osd_disk ${disk})" == "true" ]; then
      activate_osd $disk
    fi
  done

  # If no osd is running, then build one.
  if [ "${BUILD_FIRST_OSD}" == "true" ]; then
    add_new_osd
  fi
}

function activate_osd () {
  if [ -z "$1" ]; then
    log_err "activate_osd () need to assign a OSD."
    return 1
  else
    local disk2act=$1
  fi

  # if OSD is running or come from another cluster, then return 0.
  if is_osd_running ${disk2act}; then
    BUILD_FIRST_OSD=false
    log_success "${disk2act} is running as OSD."
    return 0
  elif ! is_osd_correct ${disk2act}; then
    log_warn "The OSD disk ${disk2act} isn't correct for current Ceph cluster."
    return 0
  fi

  OSD_NAME=$(disk_2_osd_id ${disk2act})
  # XXX: auto find DAEMON_VERSION
  osd_container=$($DOCKER_CMD run -d --name=${OSD_NAME} --privileged=true --net=host --pid=host -v /dev:/dev  ${OSD_MEM} ${OSD_CPU_CORE} -e KV_TYPE=${KV_TYPE} -e KV_PORT=${KV_PORT} -e DEBUG_MODE=${DEBUG_MODE} -e OSD_DEVICE=${disk2act} -e OSD_TYPE=activate ${DAEMON_VERSION} osd | cut -c 1-12)

  # XXX: check OSD container status for few seconds
  if is_osd_running ${disk2act}; then
    BUILD_FIRST_OSD=false
    log_success "Success to activate ${disk2act}"
  fi
}

function add_new_osd () {
  # if $1 is null, then add one osd.
  if [ -z "$1" ]; then
    add_n=1
  else
    add_n=$1
  fi

  # find a usable disk and format it.
  DISKS=$(get_avail_disks)

  if [ -z "${DISKS}" ]; then
    log_warn "No available disk for adding a new OSD."
    return 0
  fi

  COUNTER=0
  osd2add=""
  for disk in ${DISKS}; do
    if [ "$(is_osd_disk ${disk})" == "false" ] && [ "${COUNTER}" -lt "${add_n}" ]; then
      osd2add="${osd2add} ${disk}"
      let COUNTER=COUNTER+1
    fi
  done

  for disk in ${osd2add}; do
    if ! prepare_new_osd ${disk}; then
      log_err "OSD ${disk} fail to prepare."
    elif ! activate_osd ${disk}; then
      log_err "OSD ${disk} fail to activate."
    fi
  done
}

function prepare_new_osd () {
  if [ -z "$1" ]; then
    log_err "prepare_new_osd need to assign a disk."
    return 1
  else
    local osd2prepare=$1
  fi
  local prepare_id="$(disk_2_osd_id ${osd2prepare})_prepare_$(date +%N)"
  if $DOCKER_CMD run --privileged=true --name=${prepare_id} -v /dev/:/dev/ -e KV_PORT=2379 -e KV_TYPE=etcd -e OSD_TYPE=prepare -e OSD_DEVICE=${osd2prepare} -e OSD_FORCE_ZAP=1 ${DAEMON_VERSION} osd &>/dev/null; then
    return 0
  else
    return 1
  fi
}

function disk_2_osd_id () {
  # if $1 is /dev/sdx then search OSD container ID
  if [ -z "$1" ]; then
    return 1
  elif echo "$1" | grep -q "^/dev/"; then
    local SHORT_DEV_NAME=$(echo "$1" | sed 's/\/dev\///g')
    # echo OSD_NAME
    echo "OSD_${SHORT_DEV_NAME}"
  else
    echo ""
  fi
}

function is_osd_running () {
  # convert disk name to OSD container ID.
  if [ -z "$1" ]; then
    log_err "is_osd_running () need to assign a OSD."
    return 1
  else
    OSD_NAME=$(disk_2_osd_id $1)
  fi

  local state_running=$(${DOCKER_CMD} inspect -f '{{.State.Running}}' ${OSD_NAME} 2>/dev/null)
  if [ -z "${state_running}" ]; then
    return 1
  elif [ "${state_running}" == "false" ]; then
    ${DOCKER_CMD} rm ${OSD_NAME} >/dev/null
    return 1
  elif [ "${state_running}" == "true" ]; then
    return 0
  else
    return 1
  fi
}

function is_osd_correct() {
  if [ -z "$1" ]; then
    log_err "is_osd_correct () need to assign a OSD."
    return 1
  else
    disk2verify=$1
  fi

  # FIXME: Find OSD data partition & JOURNAL partition
  disk2verify="${disk2verify}1"
  if ceph-disk --setuser ceph --setgroup disk activate ${disk2verify} &>/dev/null; then
    OSD_ID=$(df | grep "${disk2verify}" | sed "s/.${CLUSTER}//g")
    umount ${disk2verify}
    return 0
  else
    return 1
  fi
}

function is_osd_disk() {
  # Check label partition table includes "ceph journal" or not
  if parted -s $1 print 2>/dev/null | egrep -sq '^ 1.*ceph data' ; then
    echo "true"
  else
    echo "false"
  fi
}

# Find disks not only unmounted but also non-ceph disks
function get_avail_disks () {
  BLOCKS=$(readlink /sys/class/block/* -e | sed -n "s/\(.*ata[0-9]\{,2\}\).*\/\(sd[a-z]\)$/\2/p")
  [[ -n "${BLOCKS}" ]] || ( echo "" ; return 1 )

  while read disk ; do
    # Double check it
    if ! lsblk /dev/${disk} > /dev/null 2>&1; then
      log_warn "Disk ${disk} is not a valid block device"
      continue
    fi

    if [[ -z "$(lsblk /dev/${disk} -no MOUNTPOINT)" &&
      "$(lsblk /dev/${disk}1 -no PARTLABEL 2>/dev/null)" != "ceph data" ]]; then
      # Find it
      echo "/dev/${disk}"
    fi
  done < <(echo "$BLOCKS")

  # No available disks
  echo ""
}

function hotplug_OSD () {
  inotifywait -r -m /dev/ -e CREATE -e DELETE | while read dev_msg; do
    local disk_name=$(echo $dev_msg | awk '{print $1$3}')
    local action=$(echo $dev_msg | awk '{print $2}')

    if [[ "${disk_name}" =~ /dev/sd[a-z]$ ]] && is_osd_disk ${disk_name}; then
      OSD_NAME=$(disk_2_osd_id ${disk_name})
      case ${action} in
        CREATE)
          log_info "Add ${disk_name}"
          activate_osd "${disk_name}"
          ;;
        DELETE)
          log_info "Remove ${disk_name}"
          if is_osd_running ${disk_name}; then
            ${DOCKER_CMD} stop ${OSD_NAME} >/dev/null && ${DOCKER_CMD} rm ${OSD_NAME} >/dev/null
          fi
          ;;
        *)
          ;;
      esac
    fi
  done
}
# XXX: We suppose we don't need any lvs and raid disks at all and just delete them
function clear_lvs_disks () {
  lvs=$(lvscan | grep '/dev.*' | awk '{print $2}')

  if [ -n "$lvs" ]; then
    log_info "Find logic volumes, inactive them."
    for lv in $lvs
    do
      lvremove -f -y "${lv//\'/}"
    done

  fi

  vgs=$(vgdisplay -C --noheadings --separator '|' | cut -d '|' -f 1)
  if [ -n "$vgs" ]; then
    log_info "Find VGs, delete them."
    for vg in $vgs
    do
      vgremove -f "$vg"
    done

  fi


  pvs=$(pvscan -s | grep '/dev/sd[a-z].*')
  if [ -n "$pvs" ]; then
    log_info "Find PVs, delete them."
    for pv in $pvs
    do
      pvremove -ff -y "$pv"
    done

  fi
}

function clear_raid_disks () {
  mds=$(mdadm --detail --scan  | awk '{print $2}')

  if [ -z "${mds}" ]; then
    # Nothing to do
    return 0
  fi

  for md in ${mds}
  do
    devs=$(mdadm --detail --export "${md}" | grep MD_DEVICE_.*_DEV | cut -d '=' -f 2)
    if [ -z "$devs" ]; then
      log_info "No invalid devices"
      return 1
    fi
    mdadm --stop ${md}

    for dev in ${devs}
    do
      log_info "Clear MD device: $dev"
      mdadm --wait --zero-superblock --force "$dev"
    done
  done
}


