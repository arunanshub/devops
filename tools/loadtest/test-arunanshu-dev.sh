#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_script="${script_dir}/arunanshu-dev.js"

k6 inspect "${test_script}" >/dev/null
grep -q 'ramping-arrival-rate' "${test_script}"
grep -q 'Host.*arunanshu.dev' "${test_script}"
grep -q 'http_req_failed' "${test_script}"
grep -q 'rate<0.05' "${test_script}"
grep -q 'http_req_duration' "${test_script}"
grep -q 'p(95)<500' "${test_script}"
grep -q 'dropped_iterations' "${test_script}"
grep -q 'count==0' "${test_script}"
grep -q 'target: 300, duration' "${test_script}"
grep -q "__ENV.METHOD || 'HEAD'" "${test_script}"
! grep -q "p(95)<500'.*abortOnFail" "${test_script}"
