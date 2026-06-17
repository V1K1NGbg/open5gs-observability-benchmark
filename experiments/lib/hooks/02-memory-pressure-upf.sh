#!/usr/bin/env bash
# Hook: 02-memory-pressure-upf
#
# StressChaos allocates in chaos-daemon's cgroup, NOT inside the target
# container. To actually hit UPF's 128Mi limit and trigger an OOM kill,
# also allocate memory inside the UPF container. The alloc dies with the
# container, so no manual cleanup is needed.
#
# After delete, restart SMF to clear stale PFCP session state.

during_fault() {
    local upf_pod
    upf_pod=$(kubectl get pods -n open5gs -l app.kubernetes.io/name=upf \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$upf_pod" ]]; then
        echo "  [hook 02] WARNING: UPF pod not found, skipping in-container alloc" >&2
        return 0
    fi
    echo "  [hook 02] allocating 150MB inside UPF ($upf_pod) to force OOM..."
    kubectl exec -n open5gs "$upf_pod" -c open5gs-upf -- \
        perl -e 'my $x = "a" x (150*1024*1024); print "allocated 150MB\n"; sleep 400' \
        >/dev/null 2>&1 &
}

post_delete() {
    echo "  [hook 02] waiting for UPF restart, then restarting SMF..."
    until kubectl get pod -n open5gs -l app.kubernetes.io/name=upf \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q .; do
        sleep 3
    done
    sleep 5
    kubectl rollout restart deployment/open5gs-smf -n open5gs
    kubectl rollout status  deployment/open5gs-smf -n open5gs --timeout=60s
}
