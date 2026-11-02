# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

- Email **security@unxwares.com**, or
- use GitHub's [private vulnerability reporting](https://github.com/UnxWares/helm/security/advisories/new).

Include the chart name and version, what an attacker can do, and the steps to reproduce.
We acknowledge reports within 3 business days and keep you informed until a fixed chart is released.

## Supported versions

Only the latest released version of each chart receives fixes. Charts use calendar
versioning (`year.month.number`), so the newest version is always the supported one.

## Vulnerabilities in application images

Most CVEs reported by Artifact Hub's security report come from the application images, not
from the charts. Two things keep them down:

- **UnxWares images** ([images/](images/README.md)): where the upstream images lag behind, we
  rebuild them twice a week (Monday and Thursday) on current bases, with dependencies bumped and
  the upstream security fixes that are merged but not released yet. The charts use them by default
  and keep the upstream images as an option.
- **CVE watch** (`.github/workflows/cve-watch.yaml`): every 6 hours, and after each rebuild of the
  UnxWares images, Trivy scans every image the charts can deploy and updates the open issue
  labelled [`cve-watch`](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch):
  fixable vulnerabilities of our images, and upstream fix candidates (application dependencies
  to bump upstream, images that only need a rebuild). New fixable critical/high vulnerabilities
  are posted as a comment. When upstream has not fixed one yet, we send them the pull request.
- **Rebuild as soon as a fix is out**: when the CVE watch finds a critical or high vulnerability
  in one of our images that a rebuild fixes (an OS package, or the Go standard library of the
  build image), it starts the image workflow at once instead of waiting for the Monday or Thursday
  rebuild, and says in the issue which images and vulnerabilities. It skips the vulnerabilities
  that the image's `.trivyignore` accepts (each one documented), never starts a rebuild from the
  watch that follows a rebuild, and waits 20 hours after the previous image build. Vulnerable
  application dependencies pinned in `images/` need a pull request: they stay listed in the issue.

We bump image tags as soon as a fixed build exists. Releases that only exist for that reason
carry the `artifacthub.io/containsSecurityUpdates: "true"` annotation.

## Verifying chart signatures

Every chart published from this repository since 2026.10 is signed with the
**UnxWares Helm Charts** OpenPGP key:

```
Fingerprint: 7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B
Public key:  https://helm.unxwares.studio/pgp-public-key.asc
```

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg

helm repo add unxwares https://helm.unxwares.studio
helm install my-dns unxwares/powerdns --verify --keyring ~/.gnupg/unxwares-helm.gpg
# or, for a downloaded package:
helm pull unxwares/powerdns --verify --keyring ~/.gnupg/unxwares-helm.gpg
```
