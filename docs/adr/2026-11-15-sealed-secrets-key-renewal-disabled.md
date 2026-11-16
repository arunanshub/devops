# Sealed-secrets key renewal disabled; SOPS is the root key

Status: accepted, 2026-11-15

## Context

The repo is public. Two encryption layers protect the secrets in it:

```
age identity (.sops.yaml recipient)
  └─ decrypts every *.sops.yaml in git
       ├─ cloud credentials, tunnel token, repo SSH key, …
       └─ kubernetes/bootstrap/secrets/sealed-secrets-master-key.sops.yaml
            └─ decrypts every *.sealedsecret.yaml in git
```

The sealed-secrets controller renews its sealing key every 30 days by default
and never deletes old keys. On 2026-11-15 it held 7 keys; the SOPS backup held
only the first (`bnqjp`), which the `secrets:seal*` tasks pin with `--cert`.
The 6 newer keys were never used. Any secret sealed against them (plain
`kubeseal`, `--re-encrypt`) could not be decrypted after a rebuild.

Upstream renewal limits the damage of a sealing key that leaks **on its own**:
seals made after the next renewal use a key the attacker lacks. That case
does not exist here:

- An age-key leak exposes the SOPS backup, so every sealing key in it (and
  every new key, if renewal were done properly with backups).
- An in-cluster leak (kube-system Secrets, etcd snapshots, Velero backups)
  exposes every key and the plaintext Secrets.

## Decision

- `keyrenewperiod: "0"` in `kubernetes/base/infra/sealed-secrets/values.yaml`.
  The controller keeps one key: the backed-up one.
- Sealing stays offline and pinned to the backup cert (`just seal*`).
- The age identity is the load-bearing secret. Protect it and keep an offline
  second recipient so losing one identity file does not lose the cluster.

## Consequences

- An undetected key leak stays exploitable until a manual rotation. This is
  equally true under renewal, because the leak paths above expose every key.
- On a suspected leak of the age key or the sealing key: rotate the real
  credentials (git history keeps every old ciphertext public), force a new
  sealing key with the controller's `--key-cutoff-time "$(date -R)"`, back it
  up into SOPS, and re-seal.
- The certificate of `bnqjp` is valid 10 years (to 2036).
- The 6 unused controller keys can be deleted by hand. Every committed
  SealedSecret decrypts with `bnqjp` (verified 2026-11-15).
