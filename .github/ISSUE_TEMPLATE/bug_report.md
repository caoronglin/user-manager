name: Bug Report
description: Report a bug to help us improve
title: '[Bug]: '
labels: ['bug']
body:
  - type: markdown
    attributes:
      value: |
        Thanks for taking the time to fill out this bug report!
  - type: textarea
    id: description
    attributes:
      label: Describe the bug
      description: A clear and concise description of what the bug is
    validations:
      required: true
  - type: textarea
    id: reproduction
    attributes:
      label: Steps to Reproduce
      description: Steps to reproduce the behavior
      placeholder: |
        1. Run command '...'
        2. Select option '...'
        3. See error
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
      description: What you expected to happen
    validations:
      required: true
  - type: textarea
    id: screenshots
    attributes:
      label: Screenshots
      description: If applicable, add screenshots to help explain your problem
  - type: input
    id: version
    attributes:
      label: Version
      description: What version of User Manager are you using?
      placeholder: v0.2.1
    validations:
      required: true
  - type: input
    id: system
    attributes:
      label: System Information
      description: What OS and version are you running?
      placeholder: Ubuntu 22.04 LTS
    validations:
      required: true
  - type: textarea
    id: logs
    attributes:
      label: Relevant logs
      description: Please copy and paste any relevant log output
      render: shell
