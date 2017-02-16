#!/bin/bash
set -e
set -x

: ${NAMESPACE:="ceph"}
: ${LABLE:="ceph-mon"}
: ${SECRET_NAMESPACE:="default"}
: ${OUTPUT:="dashboard-secrets.yaml"}
: ${CEPH_USER:="client.admin"}
: ${DOMAINNAME:="true"}

USAGE="Usage: -n [ceph_namespace] -l [ceph-mon-label] -s [secret_namespace] -f [output_filename]

    ceph_namespace   [default: ${NAMESPACE}]
    ceph-mon-label   [default: ${LABLE}]
    secret_namespace [default: ${SECRET_NAMESPACE}]
    output_filename  [default: ${OUTPUT}]
"

while getopts "n:l:s:h" OPTION
do
  case $OPTION in
    n) NAMESPACE="$OPTARG" ;;
    l) LABLE="$OPTARG" ;;
    s) SECRET_NAMESPACE="$OPTARG" ;;
    h) echo "$USAGE"; exit;;
  esac
done

echo "ceph_namespace: ${NAMESPACE}"
echo "ceph-mon-label: ${LABLE}"
echo "secret_namespace: ${SECRET_NAMESPACE}"

command -v kubectl > /dev/null 2>&1 || { echo "Command not found: kubectl"; exit 1; }
KUBECTL=$(command -v kubectl)

POD=$(${KUBECTL} --namespace=${NAMESPACE} get pod -l name=${LABLE} | awk 'NR==2{print$1}')

if [ -z ${POD} ]; then
  echo "Pod ceph-mon not found"
  exit 0
fi

$KUBECTL exec --namespace=${NAMESPACE} ${POD} cat /etc/ceph/ceph.${CEPH_USER}.keyring > keyring

if [ "${DOMAINNAME}" == "true" ]; then
  echo -e "[global]\nmon host = ${LABLE}.${NAMESPACE}" > ceph.conf
else
  $KUBECTL exec --namespace=${NAMESPACE} ${POD} cat /etc/ceph/ceph.conf > ceph.conf
fi

$KUBECTL create secret generic dashboard-secrets --namespace=ceph --from-file=keyring --from-file=ceph.conf
rm keyring ceph.conf
echo "Generate ${OUTPUT} done"
