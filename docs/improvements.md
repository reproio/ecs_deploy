# Improvement Proposals: ecs_deploy

> Analyzed: 2026-03-26
> Repository: /Users/ksato/rp/ecs_deploy

## Summary

- **Test coverage is thin**: only 6 spec files cover a codebase of 22 Ruby files, and the most complex production logic (service.rb, task_definition.rb, capistrano.rb) has no tests at all.
- **Ruby 2.5/2.6 support is a maintenance burden**: both versions reached end-of-life in 2021; dropping them would allow use of modern language features and reduce CI matrix complexity.
- **The auto-scaler's threading model lacks explicit error boundaries**: unhandled exceptions in worker threads can silently kill scaling behavior without alerting operators.
- **Configuration is validated only at runtime**: invalid YAML configs for the auto-scaler cause crashes mid-flight rather than being caught at startup.
- **Several large methods exceed single-responsibility**: `service.rb` and `auto_scaling_group_config.rb` have methods over 60 lines combining business logic, AWS API calls, and logging.

---

## 1. Code Quality & Refactoring

### Issues

**Long methods mixing concerns**

`lib/ecs_deploy/service.rb` — The `deploy` and `wait_for_deploy` methods each span 60–80+ lines, blending AWS API calls, state mutation, logging, and retry logic. This makes them difficult to test in isolation and hard to modify safely.

`lib/ecs_deploy/auto_scaler/auto_scaling_group_config.rb` — `decrease_desired_capacity` mixes instance selection, AZ balancing, ECS draining, and ASG detach into a single method, making edge cases hard to reason about.

**Config struct uses `Struct.new` with keyword_init inconsistently**

`lib/ecs_deploy/auto_scaler/config_base.rb` uses `Struct.new` without `keyword_init: true`, meaning positional arguments are accepted silently. Any argument-order mistake is invisible until runtime.

**Old-format YAML config supported indefinitely**

`lib/ecs_deploy/auto_scaler.rb` silently handles both old and new YAML config formats. The old format appears to predate v1.0.0. Without a deprecation warning or removal timeline, this dual-path adds permanent maintenance cost.

### Recommendations

- Extract private helper methods from `deploy` and `wait_for_deploy` in `service.rb` — e.g., `build_service_params`, `poll_until_stable`, `log_deployment_events`.
- Add `keyword_init: true` to all `Struct.new` calls in the auto-scaler config classes (breaking change — do in a minor version bump with CHANGELOG note).
- Emit a deprecation warning when old-format YAML config is detected, and document a removal target version.

---

## 2. Security

### Issues

**No credential validation or masking in logs**

`lib/ecs_deploy/configuration.rb` exposes `access_key_id` and `secret_access_key` fields. If the global logger is set to `DEBUG`, AWS SDK calls may log request parameters. There is no explicit guard against accidentally logging credentials.

**SQS message contents are parsed without schema validation**

`lib/ecs_deploy/auto_scaler/instance_drainer.rb` — SQS messages are parsed with `JSON.parse` and then immediately accessed by key (e.g., `body["detail"]["instance-id"]`). A malformed or unexpected message structure will raise a `NoMethodError` or `TypeError`, potentially crashing the drainer thread.

**No pinning of GitHub Actions to commit SHA**

`.github/workflows/test.yml` uses `actions/checkout@v6.0.1` and `ruby/setup-ruby@v1.286.0` by tag. Tags are mutable — a compromised tag could silently alter CI behavior. Pinning to a full commit SHA is the security-hardened practice.

### Recommendations

- Add a check in `Configuration` that warns if `access_key_id` / `secret_access_key` are set and `log_level` is `DEBUG`.
- Wrap SQS message parsing in `instance_drainer.rb` with a rescue and a schema check before accessing nested keys:
  ```ruby
  body = JSON.parse(msg.body) rescue nil
  next unless body.is_a?(Hash) && body.dig("detail", "instance-id")
  ```
- Pin GitHub Actions to commit SHAs in `.github/workflows/test.yml`:
  ```yaml
  - uses: actions/checkout@<full-sha>  # v6.0.1
  ```

---

## 3. Performance

### Issues

**`wait_for_deploy` polls all services sequentially with `sleep`**

`lib/ecs_deploy/service.rb` — When multiple services are deployed, each service's stability polling loop uses `sleep` and runs in a single thread. Deployments of N services take at least N × poll_interval seconds sequentially, even though the services are independent.

**`ClusterResourceManager` background thread timeout is hardcoded**

`lib/ecs_deploy/auto_scaler/cluster_resource_manager.rb` — The capacity-update background thread uses a hardcoded 180-second timeout (`@condition.wait(@mutex, 180)`). Under AWS API throttling or slow responses, this silent wait may cause the auto-scaler to act on stale capacity data.

**Repeated `describe_services` calls per poll cycle**

`lib/ecs_deploy/auto_scaler/service_config.rb` — Each auto-scaler polling cycle issues individual `describe_services` calls per service. AWS ECS `describe_services` supports up to 10 services per request; batching these would reduce API call volume significantly in environments with many services.

### Recommendations

- Move `wait_for_deploy` polling into threads (one per service), similar to how `auto_scaler.rb` already uses threads for scaling. The multi-threaded structure already exists in the codebase and could be reused.
- Make the `ClusterResourceManager` timeout configurable via YAML config and add a log warning when a timeout occurs.
- Batch `describe_services` calls in the auto-scaler polling loop by grouping services into chunks of 10.

---

## 4. Documentation Gaps

### Issues

**No YARD/RDoc documentation on public methods**

None of the public methods in the core classes (`Service`, `TaskDefinition`, `ScheduledTask`) have inline documentation. Contributors must read full method bodies to understand parameters and return values.

**README auto-scaler section lacks signal behavior and daemon management**

The README documents YAML config well but does not explain how to run the auto-scaler as a managed system service (systemd, supervisord), how to handle log rotation, or what the OS signals do at runtime.

**CHANGELOG entries lack context**

Entries like "Fixed Aws::AutoScaling ValidationError" (v1.0.7) do not explain when the error occurs, what causes it, or what the fix was. This makes it hard for users to assess whether an upgrade is necessary.

**No documentation for required IAM permissions per feature**

The README mentions IAM policies are needed but does not include a ready-to-use IAM policy JSON. Users must derive required permissions manually by running into `AccessDenied` errors.

### Recommendations

- Add YARD doc comments to the public interface of `Service`, `TaskDefinition`, and `AutoScaler`.
- Add a "Running the Auto Scaler in Production" section to the README with a systemd unit file example.
- Expand CHANGELOG entries with a one-sentence "Why" and "Impact" for each fix.
- Add a complete IAM policy document to the README (one for Capistrano, one for the auto-scaler daemon).

---

## 5. Architecture

### Issues

**Global logger shared across all threads without synchronization**

`lib/ecs_deploy/ecs_deploy.rb` sets a single `Logger` instance on `EcsDeploy.logger`. The auto-scaler runs multiple threads simultaneously (one per service config, one for instance draining). Ruby's `Logger` is thread-safe for individual `#info`/`#error` calls, but log interleaving across threads can make output difficult to correlate without a request/thread ID in each message.

**AutoScaler config loading happens at startup only**

`lib/ecs_deploy/auto_scaler.rb` loads the YAML config once at startup. There is no mechanism to reload config without restarting the daemon. In production, changing scaling parameters requires a service restart, which risks brief gaps in scaling coverage.

**`InstanceFluctuationManager` duplicates scaling logic from `AutoScalingGroupConfig`**

`lib/ecs_deploy/instance_fluctuation_manager.rb` implements its own logic for finding and terminating redundant instances that overlaps significantly with `auto_scaling_group_config.rb`. The two paths can diverge over time, leading to inconsistent behavior between Capistrano-driven and auto-scaler-driven scaling.

**No structured error handling or alerting in the auto-scaler main loop**

`lib/ecs_deploy/auto_scaler.rb` — If an unhandled exception propagates out of a service-scaling thread, it is caught by the outer rescue but only logged. There is no mechanism to notify operators (e.g., via CloudWatch metrics or SQS dead-letter) that scaling has failed for a specific service.

### Recommendations

- Add a thread/service identifier to each log line in the auto-scaler (e.g., `[service:my-service]` prefix) for easier log correlation.
- Add a `SIGHUP` handler to `auto_scaler.rb` that reloads the YAML config without full restart, following the Unix convention for daemons.
- Consolidate instance-selection and termination logic into `AutoScalingGroupConfig` and have `InstanceFluctuationManager` delegate to it, removing the duplication.
- In the auto-scaler rescue blocks, publish a CloudWatch custom metric (e.g., `ScalingError` count) so failures are observable without requiring log scraping.

---

## 6. Deployment Pipeline: Capistrano vs GitHub Actions

The gem is designed as a Capistrano extension, which was a natural fit when teams were already using Capistrano for traditional Rails deployments. However, GitHub Actions offers meaningful advantages worth evaluating.

### Capistrano strengths in this codebase

- **Ruby DSL for task definitions** — `fetch(:sha1)`, `fetch(:rails_env)`, and multi-container definitions expressed in Ruby are concise. Equivalent GitHub Actions YAML would be significantly more verbose.
- **Multi-stage environment model** — Capistrano's stage system (production, staging) with per-stage variable overrides maps naturally to multi-cluster ECS deployments.
- **First-class rollback** — `ecs:rollback` walks ECS task definition ARN history in Ruby. No AWS-native equivalent exists as a simple action.
- **Pre/post deploy orchestration** — `increase_instances_to_max_size` → `deploy` → `terminate_redundant_instances` is expressed as ordered Capistrano tasks with shared state.

### GitHub Actions advantages

| Area | Advantage |
|---|---|
| Audit trail | Every deploy is a named workflow run with full logs linked to a commit; Capistrano deploys leave no trace in GitHub |
| Secrets management | OIDC-based role assumption via `aws-actions/configure-aws-credentials` — no long-lived AWS keys needed |
| Trigger integration | Block deploys on failing checks, require PR approval for production, auto-deploy on merge to main |
| No local toolchain | Anyone can trigger a deploy from the GitHub UI without Capistrano/Ruby installed locally |
| Parallelism | Multi-region deploys can fan out as parallel jobs natively |

### Recommendation

A pragmatic hybrid: keep Capistrano for the Ruby DSL and rollback logic, but trigger it from GitHub Actions (`bundle exec cap production ecs:deploy`) rather than running it locally. This gains the audit trail and OIDC secrets management without rewriting the deploy logic. Full migration to native GitHub Actions steps is worthwhile only if the team wants to remove the Capistrano dependency entirely and is willing to reimplement rollback and the instance fluctuation orchestration.

---

## 7. Auto-Scaler: Fundamental Architecture Alternatives

The current auto-scaler daemon handles three concerns that have different optimal solutions today:

| Concern | Current approach | Better alternative |
|---|---|---|
| Standard ECS service scaling | Custom polling daemon | AWS Application Auto Scaling (step scaling policies) |
| EC2 capacity management | Custom ASG logic with AZ balancing | ECS Capacity Providers with Managed Scaling |
| Spot interruption draining | SQS polling + custom drain logic | `ECS_ENABLE_SPOT_INSTANCE_DRAINING=true` in launch template |

### Features AWS native cannot replace

Three features in the daemon have no direct AWS equivalent:

- **`max_task_count: [10, 25]` with `cooldown_time_for_reach_max`** — staged caps where a service is held at the first tier until a cooldown elapses before being allowed to scale to the second tier. AWS Step Scaling has cooldown periods but not staged caps.
- **`idle_time`** — suppresses re-evaluation for N seconds after any scaling action. AWS cooldowns are similar but not identical.
- **`prioritized_over_upscale_triggers`** — a downscale trigger that overrides a simultaneous upscale trigger.

### Recommended approach: AWS native + small Go daemon

Delegate the standard work to AWS and reduce the custom daemon to only the three features above.

**Why Go over Java or Rust for the daemon:**

| | Go | Java | Rust |
|---|---|---|---|
| Cold start (if Lambda) | ~5–15ms | 500ms–3s (needs SnapStart) | ~1ms |
| AWS SDK maturity | Production-grade | Most mature | Good, youngest |
| Deployment | Single binary ~10MB | JAR + JVM or GraalVM | Single binary ~5MB |
| Fit for this logic | Direct mapping of Ruby sync primitives | Overkill, cold start problem | Marginal perf gain vs Go, higher dev cost |

Go is the right choice: Rust's cold start advantage over Go is ~5–10ms — undetectable when each AWS API call takes 50–200ms. Java cold starts are a real problem unless SnapStart is used.

**Why a daemon over Lambda for the custom features:**

The missing features are inherently stateful across polling cycles — `reach_max_at` and `last_updated_at` are timestamps checked on every poll. In Lambda these require DynamoDB conditional writes with optimistic locking to handle concurrent invocations. In a daemon they are plain in-memory struct fields. The daemon is simpler when the state is fundamentally continuous.

However, one enhancement is worth adding even with a daemon: **persist `reach_max_at` and `last_updated_at` to SSM Parameter Store or a single DynamoDB item per service on write, and restore on startup**. This eliminates state loss on process restart without the full Lambda+DynamoDB coordination complexity.

**Resulting daemon scope in Go (~200–300 lines):**

```
poll loop (or Kafka consumer — see below)
  → fan out describe_alarms calls (sync.WaitGroup, one goroutine per trigger)
  → compute desired_count differences using in-memory state
  → call ecs:update_service
  → persist state to SSM/DynamoDB
```

No EC2 API calls. No AZ balancing. No orphan instance cleanup. No SQS polling.

### If Kafka is available

If an EventBridge → Kafka bridge already exists in the system, the daemon's polling loop can be replaced with a Kafka consumer subscribing to a `cloudwatch.alarm.state-changes` topic. This eliminates all `describe_alarms` API calls and reduces reaction time from up to `polling_interval` seconds to seconds. Spot interruption events can also be routed through Kafka, removing the SQS dependency.

If the bridge does not exist today, building it solely for this daemon is not worth the effort. The polling overhead is acceptable at the scale of a few services. The bridge becomes worthwhile when alarm events are consumed by multiple systems beyond just the scaler.

---

## Priority Matrix

| Priority | Item | Effort |
|----------|------|--------|
| 🔴 High | Add tests for `service.rb`, `task_definition.rb`, `capistrano.rb` | L |
| 🔴 High | Validate SQS message schema before key access in `instance_drainer.rb` | S |
| 🔴 High | Add structured error reporting in auto-scaler thread rescue blocks | M |
| 🔴 High | Migrate standard scaling to AWS Application Auto Scaling + Capacity Providers | L |
| 🟡 Medium | Replace auto-scaler daemon with small Go daemon for custom-logic-only services | L |
| 🟡 Medium | Persist `reach_max_at`/`last_updated_at` to SSM/DynamoDB for restart safety | S |
| 🟡 Medium | Enable `ECS_ENABLE_SPOT_INSTANCE_DRAINING` and remove `InstanceDrainer` SQS logic | M |
| 🟡 Medium | Trigger Capistrano deploys from GitHub Actions for audit trail + OIDC secrets | M |
| 🟡 Medium | Batch `describe_services` API calls in auto-scaler polling | M |
| 🟡 Medium | Parallelize `wait_for_deploy` across services | M |
| 🟡 Medium | Add `SIGHUP` config-reload handler to auto-scaler | S |
| 🟡 Medium | Pin GitHub Actions to commit SHAs | S |
| 🟡 Medium | Consolidate duplicated scaling logic between `InstanceFluctuationManager` and `AutoScalingGroupConfig` | M |
| 🟡 Medium | If EventBridge→Kafka bridge exists: replace CloudWatch polling with Kafka consumer | M |
| 🟢 Low | Drop Ruby 2.5/2.6 support, simplify CI matrix | S |
| 🟢 Low | Add YARD documentation to public methods | M |
| 🟢 Low | Emit deprecation warning for old YAML config format | S |
| 🟢 Low | Add `keyword_init: true` to Struct definitions in auto-scaler configs | S |
