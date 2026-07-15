# Codex Project Bootstrap Design

## Goal

Prepare this repository so Codex can continue development with reliable project
context, component-specific instructions, and one local verification entry point.
The setup must remain isolated from the existing Claude Code workflow and must
not be pushed to the current GitLab `origin`.

## Current State

The repository has three distinct working areas:

- `backend/`: Python asyncio relay, WebSocket and HTTP endpoints, ASR,
  endpointing, translation, room authorization, and session history.
- `mac-app/`: SwiftUI macOS client with microphone and system-audio capture,
  relay connections, transcript display, and app packaging.
- `deploy/`: AWS provisioning and operations for EC2, CloudFront, Lambda, S3,
  IAM, and SSM.

The root documentation explains the product and operational procedures well,
but there is no agent-oriented entry point. The existing `.omc/` memory does not
contain useful build or test commands. There is one standalone Python behavior
test and no Swift test target.

## Proposed Structure

### Root `AGENTS.md`

The root instruction file will provide:

- A concise system and data-flow overview.
- A map of authoritative documentation and important source files.
- Common editing rules and cross-component contracts.
- A validation matrix based on changed paths.
- Security rules for tokens, local state, AWS identifiers, and generated apps.
- Git rules that prohibit pushing this branch to the existing GitLab `origin`
  unless the user explicitly changes that instruction.

It will direct Codex to the nearest component-level `AGENTS.md` for detailed
instructions rather than duplicating all component knowledge.

### Component Instructions

`backend/AGENTS.md` will describe the Python runtime, WebSocket and HTTP
boundaries, the ASR/segmenter/translator flow, concurrency-sensitive behavior,
configuration conventions, and focused validation commands.

`mac-app/AGENTS.md` will describe the Swift package, application state and relay
flow, audio capture constraints, macOS permissions and signing behavior, and
build verification.

`deploy/AGENTS.md` will describe the existing AWS scripts, local state and
secret files, the current live-environment workflow, CloudFront routing hazards,
and post-deployment health checks. It will preserve the existing operational
model instead of introducing a second deployment system.

### Verification Entry Point

`scripts/codex-check.sh` will be an additive, standalone command. It will:

1. Compile-check tracked Python sources without starting models or contacting
   AWS.
2. Run the existing endpointing behavior test when a Python interpreter with
   the required dependency is available.
3. Syntax-check the repository's shell scripts.
4. Build the Swift package.

The script will stop on real failures and print a clear warning when the
dependency-backed Python behavior test cannot run. It will accept an explicit
Python interpreter override so Codex can use `backend/.venv/bin/python` without
changing the project's dependency layout.

Remote AWS verification remains component-specific. Backend or deployment
changes that need live confirmation will first pass local checks and then use
the existing scripts and health endpoints documented by the repository.

## Compatibility Boundaries

This bootstrap will not:

- Create or modify `CLAUDE.md`, `.claude/`, `.omc/`, or Kiro configuration.
- Change application behavior, deployment scripts, README files, dependencies,
  or generated artifacts.
- Add CI automation that can deploy or operate AWS without an active Codex
  task.
- Push commits or branches to the current GitLab `origin`.

Because all added files are Codex documentation or an opt-in verification
command, the existing Claude Code and runtime workflows remain unchanged.

## Error Handling

The verification script will use strict shell behavior and identify the failed
phase. Optional dependency absence will be reported as a skipped behavior test,
not hidden. Component instructions will require Codex to report any local or
remote verification that could not be completed.

AWS instructions will require checking the active account, region, and local
deployment state before live operations. Existing rollback references in
`VERSIONS.md`, Git tags, and the recorded deployment workflow remain the source
of truth.

## Acceptance Criteria

- Codex can identify the repository architecture and the correct files to read
  without reconstructing the project from scratch.
- Each component has focused instructions for editing and validation.
- One command performs the available local checks and returns a nonzero status
  for actual failures.
- No existing source, deployment, Claude Code, or product documentation file is
  modified.
- Work exists only on the local `codex/bootstrap` branch and is not pushed to
  the existing GitLab remote.
