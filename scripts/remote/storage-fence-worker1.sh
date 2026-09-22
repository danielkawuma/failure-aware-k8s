#!/usr/bin/env bash

set -euo pipefail

WORKER1_IP="102.34.160.87"
NFS_PORT="2049"

ACTION="${1:-}"

case "${ACTION}" in

    fence)
        echo "[STORAGE FENCE] blocking Worker1 from NFS storage"

        sudo iptables -C INPUT \
            -s "${WORKER1_IP}" \
            -p tcp \
            --dport "${NFS_PORT}" \
            -j DROP \
            2>/dev/null \
        || sudo iptables -I INPUT 1 \
            -s "${WORKER1_IP}" \
            -p tcp \
            --dport "${NFS_PORT}" \
            -j DROP

        echo "[STORAGE FENCE] Worker1 storage access blocked"
        ;;

    unfence)
        echo "[STORAGE FENCE] restoring Worker1 NFS access"

        while sudo iptables -C INPUT \
            -s "${WORKER1_IP}" \
            -p tcp \
            --dport "${NFS_PORT}" \
            -j DROP \
            2>/dev/null
        do
            sudo iptables -D INPUT \
                -s "${WORKER1_IP}" \
                -p tcp \
                --dport "${NFS_PORT}" \
                -j DROP
        done

        echo "[STORAGE FENCE] Worker1 storage access restored"
        ;;

    status)
        if sudo iptables -C INPUT \
            -s "${WORKER1_IP}" \
            -p tcp \
            --dport "${NFS_PORT}" \
            -j DROP \
            2>/dev/null
        then
            echo "FENCED"
            exit 0
        else
            echo "NOT_FENCED"
            exit 1
        fi
        ;;

    *)
        echo "Usage:"
        echo "  $0 fence"
        echo "  $0 unfence"
        echo "  $0 status"
        exit 1
        ;;
esac