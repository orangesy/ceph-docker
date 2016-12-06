#!/bin/bash

  : ${NAMESPACE:="default"}
  : ${LABLE:="ceph-mon"}
  : ${SECRET_NAMESPACE:="default"}
  : ${OUTPUT:="ceph-secrets.yaml"}

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

  echo "use ceph_namespace=${NAMESPACE} ceph-mon-label=${LABLE} secret_namespace=${SECRET_NAMESPACE} output to ${OUTPUT}"

  command -v kubectl > /dev/null 2>&1 || { echo "Command not found: kubectl"; exit 1; }
  KUBECTL=$(command -v kubectl)

  POD=$( $KUBECTL --namespace=$NAMESPACE get pod -l name=$LABLE | awk 'NR==2{print$1}')

  if [ ! -z $POD ]; then
    KEY=$( $KUBECTL exec -it $POD grep key /etc/ceph/ceph.client.admin.keyring |awk '{printf "%s", $NF}'|base64 )

    sed "s/\$SECRET_NAMESPACE/${SECRET_NAMESPACE}/g" ceph-secrets.yaml.template | sed "s/\$KEY/${KEY}/g" > ${OUTPUT}

  else
    echo "ceph-mon not found"
  fi
