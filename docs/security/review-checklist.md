# Security Review Checklist

Required topics for mutation-capable lab release:

- [ ] Root privileges and Linux capabilities CAP_BPF, CAP_SYS_ADMIN, CAP_PERFMON reviewed.
- [ ] Config injection and shell concatenation risks reviewed.
- [ ] Cgroup escape and stale-scope races reviewed.
- [ ] Audit ledger append-only and tamper/duplicate protections reviewed.
- [ ] BPF verifier assumptions and kernel/API drift reviewed.
- [ ] Log privacy and private command-line sampling reviewed.
- [ ] Packaging defaults and service enablement reviewed.
- [ ] Rollback/fallback and SysRq runbook reviewed.
- [ ] Production-claim wording reviewed.

Unsigned or incomplete mutation-capable review artifacts must fail `qa/security_gate.sh --profile mutation-capable-lab`.
