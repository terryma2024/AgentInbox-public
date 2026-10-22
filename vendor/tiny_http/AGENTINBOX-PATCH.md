# Local patch to tiny_http 0.12.0

Upstream source from Cargo registry checksum locked previously in Cargo.lock, repository https://github.com/tiny-http/tiny-http. Original LICENSE-MIT and LICENSE-APACHE retained. No change to request/response format or authentication.

`src/util/task_pool.rs`: worker capacity subtracts connections already queued under the same mutex: create a thread when `waiting_tasks <= queue.len()` rather than only `waiting_tasks == 0`. Without this, bursts can reserve the same idle workers multiple times; workers block waiting on idle HTTP keep-alive sockets while extra queued connections starve.

The embedded regression constructs the valid queued-four/idle-four intermediate state with four releasable blocking connection tasks and verifies the fifth connection runs immediately. `tests/tiny_http_scheduler.rs` compiles that exact module in the product test suite. Red evidence `evidence/http-scheduler-red.txt`, green in `http-scheduler-green.txt`; black-box 24 persistent connection burst test retains all idle sockets and checks a later authenticated request.

This proves the scheduler design defect; it does not assert that earlier three HTTP timeouts were necessarily caused by this exact race. No timeout or response-binding assertion was relaxed. Monitor during real deployment. Library's existing unbounded per-connection thread model remains a limitation; relay only loopback behind approved private Tailscale access.
