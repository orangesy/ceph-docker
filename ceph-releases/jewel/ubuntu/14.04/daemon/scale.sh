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

function mon_health {
    CLUSTER_PATH=ceph-config/${CLUSTER}
    while [ true ]; do
        date
        check_health
        sleep 30
    done
}

function check_health {
    local ceph_status=$(ceph ${CEPH_OPTS} status | awk '/health/ {print $2}')
    MON_LIST=$(ceph mon dump 2>/dev/null | awk '/mon\./ { sub ("mon.", "", $3); print $3}')

    if [ ${ceph_status} != "HEALTH_OK" ]; then
        local quorum_status=$(ceph ${CEPH_OPTS} status | grep "mons down")
    else
        return 0
    fi

    # is the unhealth status caused by mon_quorum?
    if [ -z "${quorum_status}" ]; then
        return 0
    fi

    # find the mon not in mon_quorum and remove it.
    for mon in ${MON_LIST}; do
        echo ${quorum_status} | grep ${mon} >/dev/null || mon_cleanup $mon
        start_config
    done
}

function mon_cleanup {
    if [ ! -z "$1" ]; then
        local MON_NAME=$1
    fi
    K8S_IP=$(grep COREOS_PRIVATE_IPV4 /etc/COREOS_ENV | sed 's/COREOS_PRIVATE_IPV4=//g')

    # check the K8S label
    local target_k8s_ip=$(kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/mon_k8s_ip/${MON_NAME})
    K8S_MON_LIST=$(kubectl get node --show-labels --server=${K8S_IP}:8080 | awk '/ceph\_mon\=true/ { print $1}')

    # if MON not in k8s list then remove it
    if ! echo ${K8S_MON_LIST} | grep -w ${target_k8s_ip} >/dev/null; then
        ceph ${CEPH_OPTS} mon remove ${MON_NAME}
        ceph ${CEPH_OPTS} mon getmap -o /tmp/monmap
        uuencode /tmp/monmap - | kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} put ${CLUSTER_PATH}/monmap -
        rm /tmp/monmap
    fi

    # delete the failed MON info on ETCD
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} del ${CLUSTER_PATH}/mon_host/${MON_NAME}
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} del ${CLUSTER_PATH}/mon_k8s_ip/${MON_NAME}
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
    NODEs=$(ceph ${CEPH_OPTS} osd tree | awk '/host/ { print $2 }' | grep -v ^0$ -c)
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
function osd_controller_init () {

    command -v jq > /dev/null 2>&1 || { echo "Command not found: jq"; exit 1; }
    command -v docker > /dev/null 2>&1 || { echo "Command not found: docker"; exit 1; }
    command -v lspci > /dev/null 2>&1 || { echo "Command not found: lspci"; exit 1; }
    JQ_CMD=$(command -v jq)
    JQ_CMD=$(which jq)
    DOCKER_CMD=$(command -v docker)
    DOCKER_VERSION=$($DOCKER_CMD -v | awk  /Docker\ version\ /'{print $3}')
    # show docker version and check docker libraries load status
    if [[ -n "${DOCKER_VERSION}" ]]; then
        log_info "docker version ${DOCKER_VERSION}"
    else
        $DOCKER_CMD -v
        exit 1
    fi

    : ${SYS_BLOCK:="/sys/class/block/"}
    : ${DISK_MAPPING:="/disk-mapping.json"}
    : ${DISKS:=""}
    : ${OSD_ENABLE:=true}
    : ${OSD_ENABLE_CONF:="/ceph-osd-enable-list.json"}
    : ${OSD_ENABLE_LIST:=""}
    : ${OSD_MAP_DIR:="/var/lib/ceph/osd"}
    : ${OSD_MAP_CONF:="${OSD_MAP_DIR}/map.conf"}
    if [ ! -z $OSD_MEM ]; then OSD_MEM="-m ${OSD_MEM}"; fi
    if [ ! -z $OSD_CPU_CORE ]; then OSD_CPU_CORE="-c ${OSD_CPU_CORE}"; fi
}

#check local disks
function get_disks () {

    BLOCKS=$(readlink ${SYS_BLOCK}* -e | sed -n "s/\(.*ata[0-9]\{,2\}\).*\/\(sd[a-z]\)$/\1 \2/p")
    [[ -n "${BLOCKS}" ]] || ( log_err "NO such disk block on ${SYS_BLOCK}" && exit 1 )

    HW_BIOS=$(lspci -mm | sed 's/\([^"]*\)"\([^"]*\)".*/\1 \2/' | md5sum | awk '{print $1}')
    [[ -n "${HW_BIOS}" ]] || ( log_err "NO such pci_md5 " && exit 1 )

    [ -e $DISK_MAPPING ] || ( log_err "NO such file ${DISK_MAPPING}" && exit 1 )
}

# get OSD enable list & OSD map config
function get_OSD_config () {

    if [ -e $OSD_ENABLE_CONF ]; then
        OSD_ENABLE_LIST=$(cat $OSD_ENABLE_CONF | $JQ_CMD '.slot_osd_disks[]')
    elif [ ! -z $OSD_ENABLE_LIST ]; then
        OSD_ENABLE_LIST=$(echo "${OSD_ENABLE_LIST}" | tr "," "\n")
    else
        log_info "NO such file ${OSD_ENABLE_CONF}"
        OSD_ENABLE_LIST=false
    fi

    if [[ "${OSD_ENABLE}" == false || -z "${OSD_ENABLE_LIST}" ]]; then
        log_info "NO such ${OSD_ENABLE_CONF} info"
        OSD_ENABLE_LIST=false
    else
        log_info "OSD_ENABLE_LIST is $(echo $OSD_ENABLE_LIST | sed ':a;N;$!ba;s/\n/ /g') from $OSD_ENABLE_CONF list"
    fi
    mkdir -p $OSD_MAP_DIR
    touch $OSD_MAP_CONF
    OSD_MAP=$(cat $OSD_MAP_CONF)
}

#use paas_sds.json filter and build container in local disks list
function build_osd_container () {

    while read line ; do
        disk_block=$(echo $line | awk '{print $1}')
        disk_name=$(echo $line | awk '{print $2}')

        #check disk_name if empty continue run next
        [[ -n "${disk_name}" ]] || ( log_err "NO such $disk_name" && continue )

        #check disk_slot if empty continue run next
        disk_slot=$(cat $DISK_MAPPING | $JQ_CMD --arg hw_id $HW_BIOS --arg port $disk_block '.[$hw_id].disks[]  | select(.port == $port) | .slot' | sed  's/\"//g' )
        [[ -n "${disk_slot}" ]] || ( log_err "NO such $disk_block disk slot on $DISK_MAPPING" && continue ) 

        # SSD disk rota=0
        disk_rota=$(lsblk /dev/$disk_name --output NAME,ROTA | grep $disk_name | grep -v '-' | awk '{print $2}')
        disk_size=$(lsblk /dev/$disk_name --output NAME,SIZE | grep $disk_name | grep -v '-' | awk '{print $2}')
        log_info "get slots $disk_slot $disk_name SIZE=$disk_size ROTA=$disk_rota on $SYS_BLOCK$disk_name"

        #check disk is system disk , if true continue run next disk
        if [[ "${disk_name}" == "$(df | grep '/var/lib/ceph' | awk '{print $1}' | sed -n 's/.*\/\([a-z]*\)[0-9]/\1/p')" ]]; then
            log_info "$disk_name is system disk"
            continue
        fi

        #check OSD_ENABLE create OSD_ENABLE_CONF list to build container
        if [[ "${OSD_ENABLE_LIST}" = false || -n $(echo "$OSD_ENABLE_LIST" | awk /^$disk_slot$/'{print $0}') ]]; then

            container_id=$(echo "$OSD_MAP" | awk /^$disk_slot\ $disk_name\ /'{print $3}')
            if [[ -n "$container_id" ]]; then

                if is_container_running $container_id; then
                    echo "$disk_slot $disk_name $container_id" >> ${OSD_MAP_CONF}.tmp
                    log_success "OSD $disk_slot $disk_name container $container_id is exist"
                else
                    log_info "OSD container $container_id not running"
                    create_OSD_container
                fi
            else
                create_OSD_container
            fi

            if [[ "${OSD_ENABLE_LIST}" = false ]]; then
                break
            fi
        fi
    done < <(echo "$BLOCKS")

    if [[ -n "${OSD_MAP_CONF}.tmp" ]]; then
        cat ${OSD_MAP_CONF}.tmp > ${OSD_MAP_CONF}
        rm ${OSD_MAP_CONF}.tmp
    else
        log_err "NO such ${OSD_MAP_CONF}.tmp , check your disk list"
    fi

    check_OSD_container
    log_success "finish create osd and output osd map config to ${OSD_MAP_CONF}"
}

function check_OSD_container () {

    log_info "check each OSD status"
    sleep 10
    OSD_COUNT=$(cat ${OSD_MAP_CONF} | wc -l)

    until [ "${OSD_RUNNING}" = "${OSD_COUNT}" ]; do
        OSD_RUNNING=0
        while read line ; do
            disk_slot=$(echo $line | awk '{print $1}')
            disk_name=$(echo $line | awk '{print $2}')
            container_id=$(echo $line | awk '{print $3}')
            status=$(cat /var/lib/ceph/osd/${disk_slot}_status)

            log_info "$disk_slot OSD container $container_id status $status"
            case "$status" in
                OSD_Starting)
                    if is_container_running $container_id; then
                        OSD_RUNNING=$(( $OSD_RUNNING + 1))
                    else
                        $DOCKER_CMD start $container_id
                    fi
                ;;
                PREPARE_ERR)
                    disk_mktable
                ;;
                ZAP_ERR)
                    disk_mktable
                ;;
                CLUSTER_LOST_CON)
                    restart_OSD
                ;;
                "")
                ;;
                *)
                    if is_container_running $container_id; then
                        OSD_RUNNING=$(( $OSD_RUNNING + 1))
                    else
                        $DOCKER_CMD start $container_id
                    fi
                ;;
            esac

        done < <(cat "${OSD_MAP_CONF}")

        log_info "create $OSD_RUNNING / $OSD_COUNT OSD container"
        sleep 20
    done
}

function create_OSD_container () {

    touch /var/lib/ceph/osd/${disk_slot}_status

    OSD_NAME="OSD_${disk_name}"
    $DOCKER_CMD stop ${OSD_NAME} > /dev/null 2>&1 && $DOCKER_CMD rm ${OSD_NAME} > /dev/null

    container_id=$($DOCKER_CMD run -d --name=${OSD_NAME} --privileged=true --net=host --pid=host -v /dev:/dev -v /var/lib/ceph/osd/${disk_slot}_status:/status ${OSD_MEM} ${OSD_CPU_CORE} -e DEBUG_MODE=${DEBUG_MODE} -e OSD_DEVICE=/dev/${disk_name} -e OSD_TYPE=disk ${DAEMON_VERSION} osd | cut -c1-10 )
    if [[ -z "${container_id}" ]]; then
        log_err "failed to create ceph osd container on slot $disk_slot $disk_name"
    else
        echo "$disk_slot $disk_name $container_id" >> ${OSD_MAP_CONF}.tmp
        log_success "create ceph osd container $container_id on slot $disk_slot $disk_name"
    fi
}

function disk_mktable () {
    $DOCKER_CMD stop $container_id > /dev/null
    parted --script /dev/${disk_name} mktable gpt
    sleep 1
    echo "" > /var/lib/ceph/osd/${disk_slot}_status
    log_info "make new disk table of /dev/${disk_name}"
    $DOCKER_CMD start $container_id > /dev/null
}

function restart_OSD () {
    $DOCKER_CMD stop $container_id > /dev/null
    sleep 1
    echo "" > /var/lib/ceph/osd/${disk_slot}_status
    $DOCKER_CMD start $container_id > /dev/null
}

function hotplug_OSD () {

    inotifywait -r -m /dev/ -e CREATE -e DELETE | while read dev_msg
    do
        dev_path=$(echo $dev_msg | awk '{print $1}')
        action=$(echo $dev_msg | awk '{print $2}')
        disk_name=$(echo $dev_msg | awk '{print $3}')

        if [[ "$dev_path" == "/dev/" && $disk_name =~ ^[a-z]*$ ]]; then
            log_info "$dev_msg"
            if [[ "$action" ==  "CREATE"  && -b "/dev/$disk_name" ]]; then
                while [ -e /tmp/osd_lock ]; do
                    log_info "lock!" && sleep 5
                done

                echo "lock" > /tmp/osd_lock
                build_osd
                rm /tmp/osd_lock
            fi

            if [ "$action" ==  "DELETE" ]; then        
                if is_container_running OSD_$disk_name; then
                    log_info "stop OSD_$disk_name container"
                    $DOCKER_CMD stop OSD_$disk_name && $DOCKER_CMD rm -f OSD_$disk_name >/dev/null
                fi
            fi
        fi

    done
}

function is_container_running () {
    local status=$($DOCKER_CMD inspect -f '{{.State.Running}}' $1 2>/dev/null) || true
    case $status in
        true)
            return 0
            ;;
        false)
            return 1
            ;;
        *)
            log_warn "Fail to check State of container: $1"
            return 2
            ;;
    esac
}
