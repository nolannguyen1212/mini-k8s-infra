# 10. Secrets: SOPS and age

Chapter 8 put two plaintext passwords straight into `Secret` manifests. Those manifests cannot go into git as-is: base64 is not encryption, anyone who can read the file (or the git history, forever) has the credential. This chapter replaces both with something safe to commit.

## 10.1 Why SOPS+age instead of Vault

Vault is the other well-known answer to this problem: secrets live in a separate running service, fetched into a Pod at runtime by an identity check, never touching git at all. It's the right choice the moment more than one person needs centrally-audited, revocable access, or secrets need to be dynamically generated (database credentials with a TTL, cloud IAM tokens) — genuinely worth knowing exists and being able to speak to in an interview.

For one person operating one VPS, SOPS trades Vault's live service for something with no service of its own to keep running, upgrade, unseal after a reboot, or back up separately: a secret is just a file, encrypted against a keypair, decrypted only at the moment it's actually rendered. The cost is a step Vault doesn't need — something has to hold the decryption key, and that something can't itself be bootstrapped by git (10.4).

## 10.2 age: the encryption half

age is a modern, small file-encryption tool: a keypair (public + private), encrypt against the public key, decrypt with the private key. SOPS uses age as one of several possible backends (others: PGP, cloud KMS); age is the right choice here for the same reason a managed database would be the right choice over self-hosting Postgres past a certain scale — no extra service dependency, a keypair is just two strings.

```sh
mkdir -p age
age-keygen -o age/keys.txt
cat age/keys.txt
```

Output looks like:

```
# created: 2026-09-12T13:39:16+07:00
# public key: age1jp2qg24ldhac2zh29u59dun4gnag4283zhv0jjayjh6t66t73gnsxmadfl
AGE-SECRET-KEY-1546SYZCSZR6PUF9Z9T38EDU5KP7FV3ESKH5MGLX7QNQ5UJSPP4WSHC72TY
```

`age/keys.txt` must never be committed:

```sh
cat > .gitignore <<'EOF'
age/keys.txt
charts/**/charts/
charts/**/Chart.lock
.DS_Store
EOF
```

## 10.3 SOPS: which files, which keys

```sh
cat > .sops.yaml <<'EOF'
creation_rules:
  - path_regex: apps/.*\.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1jp2qg24ldhac2zh29u59dun4gnag4283zhv0jjayjh6t66t73gnsxmadfl
EOF
```

Replace the `age:` value with **your own** public key from 10.2. Two things this file does:

* `path_regex: apps/.*\.enc\.yaml$` — only files under `apps/` ending in `.enc.yaml` are ever candidates for encryption. Naming a file wrong fails loudly (sops has nothing to encrypt) instead of silently committing plaintext.
* `encrypted_regex: ^(data|stringData)$` — only the `data`/`stringData` keys of a `Secret` get encrypted. `apiVersion`, `kind`, `metadata.name`, even key *names*, stay plaintext, so a `git diff` on a rotated secret still shows which key changed, just not its value.

## 10.4 Encrypt and decrypt one file by hand

Worth doing once with a throwaway file, before Kubernetes or Kustomize enter the picture:

```sh
mkdir -p apps/scratch
cat > apps/scratch/secrets.enc.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: scratch-secret
type: Opaque
stringData:
  EXAMPLE_KEY: hello-this-is-plaintext-for-now
EOF

SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -e -i apps/scratch/secrets.enc.yaml
cat apps/scratch/secrets.enc.yaml   # EXAMPLE_KEY is now ENC[AES256_GCM,...]
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -d apps/scratch/secrets.enc.yaml   # prints the original plaintext back
```

`SOPS_AGE_KEY_FILE` must be an **absolute path** — this matters again in chapter 12, where a relative path fails with a confusing, unrelated-looking error.

To edit an already-encrypted file in place — the command you'll actually use from chapter 12 onward — `sops apps/<x>/secrets.enc.yaml` opens the *decrypted* content in `$EDITOR` and re-encrypts on save:

```sh
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops apps/scratch/secrets.enc.yaml
# change EXAMPLE_KEY's value, save, quit
git diff apps/scratch/secrets.enc.yaml   # only the ENC[...] blob changed, structure identical
rm -rf apps/scratch   # only a throwaway exercise
```

One mistake worth seeing once: put an explanatory comment *inside* `stringData:` before encrypting, then encrypt and look at the result — sops turns the comment into its own `ENC[...]` entry too, unreadable in a `git diff` forever. Any note that needs to stay human-readable belongs outside `stringData:` entirely, or in the repo's README, never inside the encrypted block.

## 10.5 "Secret zero"

Every secret from chapter 12 onward gets decrypted the same way: something holds the age private key, and uses it at the moment a secret is needed. That something — chapter 13's ArgoCD — is itself a workload running in the cluster, and it cannot fetch its own decryption key from an encrypted file, since decrypting that file is the exact capability it doesn't have yet. This is "secret zero," created by hand, once, directly against the cluster, not through git:

```sh
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic sops-age \
  -n argocd \
  --from-file=age.agekey=age/keys.txt
```

This is the only `kubectl create secret` command anywhere in this repo's operation. Write down, somewhere that is not this repo, that `age/keys.txt`'s content is the one thing here that cannot be reconstructed from git: losing it without a backup makes every encrypted file in git history permanently unreadable, forever, by design.

## 10.6 Try it

```sh
git status                      # confirm age/keys.txt shows as ignored
git check-ignore -v age/keys.txt
```

Redo 10.4's encrypt/decrypt cycle once more from memory before continuing. The rest of this repo's secret handling is this exact command pair, just triggered by Kustomize (chapter 12) instead of by hand.
