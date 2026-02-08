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
- [Kubernetes](https://kubernetes.io/) cluster (local or remote) for testing
- [Helm 3.0+](https://helm.sh/) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured
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
# Lint the chart
helm lint charts/<chart-name>

# Template to see rendered manifests
helm template test-release charts/<chart-name>

# Install in a test cluster
helm install test-release charts/<chart-name> --dry-run --debug

# Actual installation for integration testing
helm install test-release charts/<chart-name> -n test-namespace --create-namespace
```

### 3. Update Version

If you're making changes that affect functionality, update the chart version in `Chart.yaml`:

- **Patch version** (x.x.X): Bug fixes, documentation updates
- **Minor version** (x.X.x): New features, backwards-compatible changes
- **Major version** (X.x.x): Breaking changes

```yaml
# charts/<chart-name>/Chart.yaml
version: 2026.2.2  # Increment appropriately
```

### 4. Update Documentation

Ensure all documentation is up to date:

- Update `README.md` if you added new features or changed configuration options
- Add examples for new features
- Update configuration tables with new parameters
- Document any breaking changes in the changelog

## Chart Guidelines

### Chart Structure

Follow the standard Helm chart structure:

```
charts/<chart-name>/
├── Chart.yaml          # Chart metadata
├── values.yaml         # Default configuration values
├── templates/          # Kubernetes manifest templates
│   ├── _helpers.tpl    # Template helpers
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ...
├── README.md          # Chart documentation
└── LICENSE.md         # License file
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
  # Type of database (mysql, postgresql, mongodb)
  type: postgresql

  # Database host
  host: localhost

  # Database port
  port: 5432
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

- Never include default passwords or secrets
- Support external secret management (Kubernetes secrets, sealed secrets, etc.)
- Use security contexts appropriately
- Follow the principle of least privilege for RBAC

#### Documentation

- Keep README.md comprehensive and up-to-date
- Include installation instructions
- Document all configuration parameters
- Provide usage examples
- Add troubleshooting section

## Testing

### Linting

Always lint your charts before submitting:

```bash
helm lint charts/<chart-name>
```

### Template Validation

Verify that templates render correctly:

```bash
helm template test-release charts/<chart-name> --debug
```

### Dry Run

Test installation without actually deploying:

```bash
helm install test-release charts/<chart-name> --dry-run --debug
```

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

# Use conventional commit format
# <type>(<scope>): <subject>
#
# Types: feat, fix, docs, style, refactor, test, chore
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

```markdown
## Description
Brief description of your changes

## Related Issues
Fixes #123

## Changes Made
- Added feature X
- Fixed bug Y
- Updated documentation for Z

## Testing Performed
- [ ] Linted chart
- [ ] Tested template rendering
- [ ] Tested installation in cluster
- [ ] Verified functionality

## Breaking Changes
List any breaking changes and migration steps

## Screenshots (if applicable)
Add screenshots here
```

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
