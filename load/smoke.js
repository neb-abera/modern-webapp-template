import http from "k6/http";
import { check } from "k6";

// Two profiles.
//
// `make load` (the default): enough traffic to surface gross regressions (a
// lost cache header, an accidental N+1) without pretending shared hardware
// gives benchmark-grade numbers. Tune stages and thresholds for your app.
//
// LOAD_PROFILE=smoke, run by scripts/verify.sh: one user, three passes, and
// thresholds on correctness alone. It proves the harness builds, runs and
// reaches the app. Latency is never gated there: shared runners make timing
// numbers noise.
const smoke = __ENV.LOAD_PROFILE === "smoke";

export const options = smoke
  ? {
      vus: 1,
      iterations: 3,
      thresholds: {
        checks: ["rate==1"],
        http_req_failed: ["rate==0"],
      },
    }
  : {
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
    "api greets": (r) => r.status === 200 && r.json("message") !== "",
  });
}
