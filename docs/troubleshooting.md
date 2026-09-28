# Troubleshooting and lessons learned

These diagnostic areas follow the implementation and original deployment notes.
They are not claims of new incidents, measured uptime or benchmark results.
Use commands only in an authorized environment and keep returned identifiers,
addresses and logs private.

## RKE2 tools and node readiness

On the server, tools and credentials are configured as follows:

```bash
export PATH="$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
kubectl get nodes
kubectl get pods -A
systemctl status rke2-server --no-pager
```

The worker uses `rke2-agent`. The bootstrap waits for two Ready nodes; EC2 running
status alone is insufficient. Check supervisor reachability on 9345, matching
join credentials, provider IDs, Cilium readiness and scheduling constraints.
Do not print tokens while diagnosing. Restoring PATH can resolve a missing
`kubectl` executable without reinstalling Kubernetes. Sourcing another environment
file can replace a session's PATH.

## Load balancing and subnet discovery

```bash
kubectl get deployment aws-load-balancer-controller -n kube-system
kubectl get service traefik -n traefik
kubectl get endpointslices -n traefik
```

Inspect controller events/logs privately for IAM failures and subnet discovery.
Verify that tagged subnets are genuinely suitable for an internet-facing NLB.
For unhealthy instance targets, inspect registered nodes, selected NodePorts,
service endpoints and applicable security-group rules. NLB hostname assignment
alone does not establish healthy targets or external connectivity.

## Traefik, Gateway and Rancher routing

```bash
kubectl get gatewayclass
kubectl get gateway rancher-gateway -n cattle-system
kubectl get httproute rancher-route -n cattle-system
kubectl get service rancher -n cattle-system
kubectl get endpointslices -n cattle-system
```

Inspect Gateway `Accepted`/`Programmed` and route `Accepted`/`ResolvedRefs`
conditions where reported. Check the hostname, listener attachment, same-namespace
route policy, TLS Secret reference and backend Service port 80. Confirm Rancher
pods are Ready. Inspect NodePort reachability separately from public NLB traffic.

The script's final check uses a local NodePort, loopback and `curl -k`; it cannot
prove public DNS, NLB target health or certificate trust. When manually using
`curl --resolve`, its address argument must be an IP, not the NLB DNS hostname.
Do not paste a real deployment address into public troubleshooting examples.

## cert-manager and DNS

```bash
kubectl get clusterissuer letsencrypt-staging
kubectl get certificates,certificaterequests,orders,challenges -n cattle-system
```

Inspect challenge status and solver HTTPRoutes. HTTP-01 needs the public hostname
to resolve to the serving load balancer and port 80 to reach the solver. Check
Gateway support, namespace attachment, issuer readiness and public DNS propagation.
The configured public resolvers affect cert-manager's HTTP-01 self-checks; this
is not DNS-01 validation.

DNS is updated before certificate and HTTPS checks. The script does not wait for
Route53 INSYNC explicitly, and future NLB replacements do not continuously update
the alias. Staging certificates remain untrusted even when Ready=True. Gateway
TLS is managed by cert-manager; the old PDF/ODT certificate-copy procedure is not
the current automated implementation.

## Retry and lifecycle boundaries

Retries use a fixed delay, not exponential backoff. A timed-out cloud-init script
may leave a partially configured environment; successful Terraform creation does
not retry that workflow. Review `/var/log/user-data-rke2.log` privately, since
failed Helm command logging can contain sensitive arguments. Do not rerun the
migration script as a harmless diagnostic: it changes cluster resources and DNS.

For any recovery or teardown, obtain separate operational authorization and
account for resources owned outside Terraform.
