import http from 'k6/http';
import { check } from 'k6';

const target = __ENV.TARGET_URL ||
  'http://127.0.0.1:18080/blog/next-server-actions-client-side-data-fetching';
const method = (__ENV.METHOD || 'HEAD').toUpperCase();

export const options = {
  discardResponseBodies: true,
  scenarios: {
    capacity: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 1000,
      stages: [
        { target: 25, duration: '30s' },
        { target: 50, duration: '1m' },
        { target: 100, duration: '1m' },
        { target: 150, duration: '1m' },
        { target: 225, duration: '1m' },
        { target: 300, duration: '1m' },
        { target: 0, duration: '30s' },
      ],
      gracefulStop: '10s',
    },
  },
  thresholds: {
    http_req_failed: [
      { threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s' },
    ],
    http_req_duration: [
      'p(95)<500',
    ],
  },
};

export default function () {
  const response = http.request(method, target, null, {
    headers: {
      Host: 'arunanshu.dev',
      'User-Agent': 'arunanshu-dev-capacity-test/1.0',
    },
    redirects: 0,
    timeout: '10s',
    tags: { route: 'heavy-blog-page' },
  });

  check(response, {
    'response is successful': (res) => res.status >= 200 && res.status < 400,
  });
}
