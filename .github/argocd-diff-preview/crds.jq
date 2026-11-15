# Prod CRDs reduced to API registration, for render:diff's --preinstall-folder.
# Charts only check .Capabilities (is the API served?), so schemas are dropped.
[
  .items[]
  # k3s, its bundled traefik and Gateway API, and Argo CD bring their own CRDs.
  | select(.spec.group | test("cattle\\.io$|^traefik\\.|^hub\\.traefik\\.io$|^gateway\\.networking\\.k8s\\.io$|^argoproj\\.io$") | not)
  | {
      apiVersion,
      kind,
      metadata: {
        name: .metadata.name,
        # The API server rejects *.k8s.io / *.kubernetes.io CRDs without this.
        annotations: (
          if (.spec.group | test("(^|\\.)k8s\\.io$|(^|\\.)kubernetes\\.io$"))
          then {"api-approved.kubernetes.io": "https://github.com/kubernetes/enhancements/pull/1111"}
          else {}
          end
        )
      },
      spec: (
        .spec
        | del(.conversion)
        | .versions |= map(
            # These reference schema fields that no longer exist.
            del(.subresources, .additionalPrinterColumns, .selectableFields)
            | .schema = {openAPIV3Schema: {type: "object", "x-kubernetes-preserve-unknown-fields": true}}
          )
      )
    }
]
