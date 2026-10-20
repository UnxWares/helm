# Contributing to UnxWares Helm Charts

Thank you for your interest in contributing to UnxWares Helm Charts! We welcome contributions from the community and appreciate your help in making our charts better.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Chart Guidelines](#chart-guidelines)
- [Testing](#testing)
- [Documentation](#documentation)
- [Submitting Changes](#submitting-changes)
- [Review Process](#review-process)
- [Releases and Signing](#releases-and-signing)

## Code of Conduct

By participating in this project, you agree to maintain a respectful and inclusive environment. We expect all contributors to:

- Be respectful and considerate in communication
- Welcome newcomers and help them get started
- Accept constructive criticism gracefully
- Focus on what's best for the community
- Show empathy towards other community members

## How Can I Contribute?

There are many ways to contribute to this project:

### Reporting Bugs

If you find a bug in one of our charts:

1. **Check existing issues** to see if it's already reported
2. **Create a new issue** with a clear title and description
3. Include the following information:
   - Chart name and version
   - Kubernetes version
   - Helm version
   - Steps to reproduce
   - Expected behavior vs actual behavior
   - Relevant logs or error messages
   - Your `values.yaml` configuration (sanitize sensitive data)

### Suggesting Enhancements

We welcome feature requests and suggestions:

1. **Check existing issues** to avoid duplicates
2. **Open a new issue** with the "enhancement" label
3. Clearly describe:
   - The problem you're trying to solve
   - Your proposed solution
   - Any alternative solutions you've considered
   - How this benefits other users

### Improving Documentation

Documentation improvements are always welcome:

- Fix typos or unclear explanations
- Add examples and use cases
- Improve existing documentation
- Translate documentation (if applicable)

### Contributing Code

Code contributions are highly valued:

- Fix bugs
- Implement new features
- Improve chart templates
- Add tests
- Optimize performance

## Getting Started

### Prerequisites

Before contributing, ensure you have:

- [Git](https://git-scm.com/) installed
- [Helm](https://helm.sh/) 3.18+ or 4 (CI tests both)
- [helm-docs](https://github.com/norwoodj/helm-docs) 1.14.2 and the
  [helm-values-schema-json](https://github.com/losisin/helm-values-schema-json) plugin 2.6.0, to regenerate READMEs and schemas
- [kubeconform](https://github.com/yannh/kubeconform) to validate rendered manifests
- Optionally [chart-testing](https://github.com/helm/chart-testing) and [kind](https://kind.sigs.k8s.io/) to run the CI install tests locally
- Basic understanding of Helm charts and Kubernetes

### Fork and Clone

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:

```bash
git clone https://github.com/YOUR_USERNAME/helm.git
cd helm
```

3. **Add upstream remote**:

```bash
git remote add upstream https://github.com/UnxWares/helm.git
```

4. **Create a feature branch**:

```bash
git checkout -b feature/your-feature-name
```

## Development Workflow

### 1. Make Your Changes

Edit the relevant files in the `charts/` directory. Common changes include:

- Modifying templates in `charts/<chart-name>/templates/`
- Updating default values in `charts/<chart-name>/values.yaml`
- Updating chart metadata in `charts/<chart-name>/Chart.yaml`
- Improving documentation in `charts/<chart-name>/README.md`

### 2. Test Your Changes

Always test your changes before submitting:

```bash
# Lint with the default values and every CI values file
helm lint --strict charts/<chart-name>
helm lint --strict charts/<chart-name> -f charts/<chart-name>/ci/default-values.yaml

# Render and validate against the Kubernetes schemas (all charts, two Kubernetes versions)
.github/scripts/kubeconform.sh 1.31.0 1.34.0

# What CI runs on a kind cluster: install every changed chart with each ci/*-values.yaml, then `helm test`
ct lint --config ct.yaml
ct install --config ct.yaml --excluded-charts laravel-generic,openeverest-database-tools
```

### 3. Update Version

**IMPORTANT**: All charts in this repository follow a **calendar-based versioning scheme**.

#### Version Format

```
year.month.version_number
```

- **Year**: 4-digit year (e.g., `2026`)
- **Month**: Month number without leading zero (e.g., `3` for March, `12` for December)
- **Version Number**: Sequential number starting from 1 for each month

#### Examples

- `2026.3.1` - First version released in March 2026
- `2026.3.2` - Second version released in March 2026 (even if released on March 28th)
- `2026.4.1` - First version released in April 2026

#### How to Increment Versions

1. **Same month as last release**: Increment the version number
   - If last version was `2026.3.5`, next version is `2026.3.6`

2. **New month**: Reset version number to 1
   - If last version was `2026.3.5` in March, first April version is `2026.4.1`

3. **Update Chart.yaml**:
   ```yaml
   # charts/<chart-name>/Chart.yaml
   version: 2026.3.2  # Increment according to calendar versioning
   ```

#### When to Create a New Version

Create a new version for:
- Bug fixes
- New features
- Documentation updates (optional, use judgment)
- Breaking changes
- Security patches
- Dependency updates

**Note**: The version number sequence doesn't indicate the magnitude of changes - use commit messages and changelog to communicate breaking changes.

### 4. Update Documentation

Chart READMEs and `values.schema.json` are generated, never edited by hand:

- describe each value with a `# --` comment on the line above it (it becomes the README table and the schema
  description), and constrain it with an inline `# @schema` annotation when useful (`enum:[a, b]`, `type:[string, null]`,
  `skipProperties:true` for free-form Kubernetes objects such as `resources` or probes)
- write the prose in `README.md.gotmpl`, including an "Upgrading" section for breaking changes
- run `./generate-schemas.sh <chart-name>` and commit the result: CI fails when the generated files are out of date
- list the release's changes in the `artifacthub.io/changes` annotation of `Chart.yaml` (replace the previous list:
  Artifact Hub shows it per version), set `artifacthub.io/containsSecurityUpdates: "true"` when the release fixes CVEs,
  and keep `artifacthub.io/images` in sync with the images the chart deploys (the weekly Trivy scan reads it)

## Chart Guidelines

### Chart Structure

Follow the standard Helm chart structure:

```
charts/<chart-name>/
├── Chart.yaml           # Chart metadata and Artifact Hub annotations
├── values.yaml          # Default values, documented with `# --` comments
├── values.schema.json   # Generated by ./generate-schemas.sh
├── README.md.gotmpl     # README template
├── README.md            # Generated by ./generate-schemas.sh
├── LICENSE.md
├── .helmignore          # Excludes ci/ and README.md.gotmpl from the package
├── ci/                  # Values files used by CI (lint, kubeconform, ct install)
│   └── default-values.yaml
└── templates/
    ├── _helpers.tpl
    ├── NOTES.txt
    ├── tests/           # `helm test` pods
    └── ...
```

### Best Practices

#### Values Files

- Use clear, descriptive parameter names
- Provide sensible defaults
- Add comments explaining each parameter
- Group related parameters together
- Use proper YAML formatting and indentation

```yaml
# Good example
database:
  # -- Database engine.
  type: postgresql # @schema enum:[postgresql, mysql]
  # -- Database host.
  host: ""
  # -- Existing Secret holding the password (key `password`). Leave empty to generate one.
  existingSecret: ""
```

#### Templates

- Use `_helpers.tpl` for reusable template snippets
- Include proper labels and annotations
- Support common Kubernetes features (resources, nodeSelector, tolerations, etc.)
- Make templates flexible with conditionals
- Use proper indentation (2 spaces)

```yaml
# Good example
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "chart.serviceAccountName" . }}
  labels:
    {{- include "chart.labels" . | nindent 4 }}
{{- end }}
```

#### Security

- Never ship default passwords: generate secrets once (`lookup` + `randAlphaNum`) so they survive upgrades, accept an
  `existingSecret`, and pass them to containers with `secretKeyRef`, never as plain `value:` entries or in ConfigMaps
- Pin image tags (or digests) and list them in `artifacthub.io/images`; prefer the variant with the fewest CVEs
- Run as non-root with numeric `runAsUser`/`runAsGroup`, `readOnlyRootFilesystem: true` (with `emptyDir` volumes for
  the paths that must be writable), `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` and seccomp
  `RuntimeDefault`. When an upstream image must start as root, add back only the capabilities it needs and explain
  why in `values.yaml`
- Set `automountServiceAccountToken: false` unless the workload calls the Kubernetes API, and keep RBAC least-privilege
- Offer an optional NetworkPolicy, and probes on a real health endpoint

#### Documentation

- Keep README.md comprehensive and up-to-date
- Include installation instructions
- Document all configuration parameters
- Provide usage examples
- Add troubleshooting section

## Testing

Every pull request runs `.github/workflows/lint-test.yaml`:

- `helm lint --strict` with Helm 3 and Helm 4, on the default values and each `ci/*-values.yaml`
- kubeconform on Kubernetes 1.31 and 1.34, including CRDs (ServiceMonitor, HTTPRoute) through the CRDs catalog
- chart-testing: `ct lint` (yamllint, version increment) and `ct install` on kind, with `helm test`
- `ah lint` for the Artifact Hub metadata
- a check that `values.schema.json` and `README.md` match `./generate-schemas.sh`

Charts that cannot start without user input (`laravel-generic` needs your application image) or external
prerequisites (`openeverest-database-tools` needs the OpenEverest operator) are linted and validated but not installed.

### Integration Testing

Test in a real Kubernetes cluster:

```bash
# Install the chart
helm install test-release charts/<chart-name> -n test-namespace --create-namespace

# Verify resources are created
kubectl get all -n test-namespace

# Test functionality
# (specific to your chart)

# Clean up
helm uninstall test-release -n test-namespace
kubectl delete namespace test-namespace
```

## Submitting Changes

### Commit Guidelines

Write clear, descriptive commit messages:

```bash
# Good commit messages
git commit -m "feat(bind9): add support for zone transfer notifications"
git commit -m "fix(openeverest-database-tools): correct ArgoCD sync wave annotation"
git commit -m "docs(cloudreve): update storage configuration examples"
git commit -m "chore(kener): bump version to 2026.3.2"

# Use conventional commit format
# <type>(<scope>): <subject>
#
# Types: feat, fix, docs, style, refactor, test, chore
# Scope: chart name (bind9, cloudreve, excalidash, fossflow, kener, laravel-generic,
#        openeverest-database-tools, powerdns, taiga) or ci, docs
```

### Push Your Changes

```bash
git push origin feature/your-feature-name
```

### Open a Pull Request

1. Navigate to the [original repository](https://github.com/UnxWares/helm)
2. Click "New Pull Request"
3. Select your fork and branch
4. Fill in the PR template with:
   - Clear description of changes
   - Related issue numbers (if applicable)
   - Testing performed
   - Screenshots (if relevant)
   - Breaking changes (if any)

### Pull Request Template

The template in `.github/PULL_REQUEST_TEMPLATE.md` is filled in automatically when you open the pull request.

## Review Process

### What to Expect

1. **Automated Checks**: CI/CD pipelines will run automated tests
2. **Maintainer Review**: A maintainer will review your PR
3. **Feedback**: You may receive feedback or change requests
4. **Approval**: Once approved, your PR will be merged

### Review Criteria

Maintainers will check for:

- Code quality and best practices
- Test coverage and functionality
- Documentation completeness
- Backwards compatibility
- Security considerations
- Adherence to chart guidelines

### Response Time

- We aim to respond to PRs within 3-5 business days
- Complex changes may require more time for review
- Feel free to ping maintainers if you haven't heard back in a week

## Releases and Signing

Merging into `main` runs `.github/workflows/release.yaml`: chart-releaser packages every chart whose version changed,
signs it with the **UnxWares Helm Charts** OpenPGP key, uploads the package and its `.prov` file to a GitHub release,
and updates `index.yaml` on GitHub Pages together with `artifacthub-repo.yml` and `pgp-public-key.asc`.

The signing key is stored in two repository secrets: `HELM_SIGNING_KEY` (the base64 of
`gpg --export-secret-keys <fingerprint>`) and `HELM_SIGNING_PASSPHRASE`. The release fails when they are missing,
so an unsigned package is never published. To rotate the key: create a new RSA key (Helm cannot use ed25519 keys),
update both secrets, `pgp-public-key.asc`, the fingerprint in `SECURITY.md`, `README.md` and the
`artifacthub.io/signKey` annotation of every chart.

## Verified Publisher Status

This repository is configured as a **Verified Publisher** on Artifact Hub. To maintain this status:

### What Is Verified Publisher?

The "Verified Publisher" badge on Artifact Hub indicates that the repository publisher owns or has control over the repository. This helps users trust the authenticity of the charts.

### Maintaining Verification

1. **Do not modify** the `artifacthub-repo.yml` file unless you're updating maintainer information
2. The `repositoryID` field must match the ID shown in the [Artifact Hub Control Panel](https://artifacthub.io/control-panel)
3. The file is automatically deployed to GitHub Pages during releases

### Troubleshooting Verification

If the verified badge doesn't appear:

1. **Check Repository ID**: Ensure `repositoryID` in `artifacthub-repo.yml` matches your Artifact Hub repository ID
2. **Verify File Location**: The file must be served at `https://helm.unxwares.studio/artifacthub-repo.yml`
3. **Trigger Re-scan**: Make a change to any chart to trigger a new release (updates `index.yaml`)
4. **Wait for Processing**: Artifact Hub processes repositories periodically; verification may take a few minutes

### Adding New Maintainers

To add a new maintainer to the verified publisher list, update `artifacthub-repo.yml`:

```yaml
owners:
  - name: New Maintainer Name
    email: email@unxwares.com
```

Then create a pull request with the changes.

## Getting Help

If you need help or have questions:

- **General Questions**: opensource@unxwares.com
- **Security Issues**: security@unxwares.com
- **GitHub Discussions**: Open a discussion on GitHub
- **Issues**: Create an issue for bugs or feature requests

## License

By contributing to this project, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to UnxWares Helm Charts! Your efforts help make Kubernetes deployments easier for everyone.
