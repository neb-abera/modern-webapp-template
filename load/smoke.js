import http from "k6/http";
import { check } from "k6";

// Baseline load shape: enough to surface gross regressions (a lost cache
// header, an accidental N+1) without pretending shared hardware gives
// benchmark-grade numbers. Tune stages/thresholds for your app.
export const options = {
  stages: [
    { duration: "10s", target: 20 },
    { duration: "20s", target: 20 },
    { duration: "5s", target: 0 },
  ],
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<250"],
  },
};

const base = __ENV.BASE_URL || "http://localhost:8080";

export default function () {
  const home = http.get(`${base}/`);
  check(home, { "document 200": (r) => r.status === 200 });

  const hello = http.get(`${base}/api/hello`);
  check(hello, {
    "api 200": (r) => r.status === 200,
    "api greets": (r) => r.json("message") !== "",
  });
}
