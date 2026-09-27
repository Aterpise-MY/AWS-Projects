"""Client for the Ebteqdesk Business Sync Trigger API.

POST /api/integrations/business-sync/{portal}   -> 202 new run | 200 already-active run
GET  /api/integrations/business-sync/runs/{id}  -> status queued|running|succeeded|failed
"""

import json
import re
import urllib.error
import urllib.parse
import urllib.request

TRIGGER_ID_RE = re.compile(r"^[A-Za-z0-9:._-]{1,100}$")
FINISHED_STATUSES = ("succeeded", "failed")
_LOCAL_HOSTS = ("127.0.0.1", "localhost")


class ApiError(Exception):
    """The API could not be used: unreachable, auth, misconfigured, or non-JSON."""


def validate_base_url(base_url):
    """https only. Plain http is accepted for a local stub server (tests) and nothing else."""
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme == "https" and parsed.hostname:
        return base_url.rstrip("/")
    if parsed.scheme == "http" and parsed.hostname in _LOCAL_HOSTS:
        return base_url.rstrip("/")
    raise ApiError("EBTEQDESK_BASE_URL must be an https:// URL")


def _unwrap(body):
    # Accept both {"data": {...}} (Laravel JsonResource) and a flat object.
    if isinstance(body, dict) and isinstance(body.get("data"), dict):
        return body["data"]
    return body


class EbteqdeskClient:
    def __init__(self, base_url, token, timeout=20):
        self.base_url = validate_base_url(base_url)
        self.token = token
        self.timeout = timeout

    def _request(self, method, path, headers=None):
        req = urllib.request.Request(
            self.base_url + path,
            method=method,
            data=b"" if method == "POST" else None,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
                **(headers or {}),
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                status, ctype, raw = resp.status, resp.headers.get("Content-Type", ""), resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise ApiError("401 Unauthorized：token 与 Ebteqdesk 的 BUSINESS_SYNC_TRIGGER_TOKEN 不一致") from None
            if exc.code == 503:
                raise ApiError("503：Ebteqdesk 没有设置 BUSINESS_SYNC_TRIGGER_TOKEN") from None
            if exc.code == 422:
                raise ApiError("422：Ebteqdesk 拒绝了这个 portal 或 X-Trigger-Id") from None
            raise ApiError(f"HTTP {exc.code} from Ebteqdesk") from None
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise ApiError(f"无法连接 Ebteqdesk：{type(exc).__name__}: {exc}") from None

        # A firewall challenge or login page can come back as HTML 200. Never treat it as success.
        if "json" not in ctype.lower():
            raise ApiError(f"Ebteqdesk 返回的不是 JSON（Content-Type: {ctype or 'none'}），可能被 firewall 拦截")
        try:
            return status, _unwrap(json.loads(raw.decode("utf-8")))
        except ValueError:
            raise ApiError("Ebteqdesk 返回的 JSON 无法解析") from None

    def trigger(self, portal, trigger_id):
        """Start a sweep, or adopt the portal's already-active one.

        Returns (http_status, run). 202 = new run; 200 = an active run was returned
        (any trigger id — Ebteqdesk never runs two sweeps per portal at once).
        """
        if not TRIGGER_ID_RE.match(trigger_id):
            raise ApiError(f"invalid trigger id: {trigger_id!r}")
        status, run = self._request(
            "POST",
            f"/api/integrations/business-sync/{urllib.parse.quote(portal)}",
            headers={"X-Trigger-Id": trigger_id},
        )
        if status not in (200, 202) or not isinstance(run, dict) or "id" not in run:
            raise ApiError(f"unexpected trigger response: HTTP {status}")
        return status, run

    def get_run(self, run_id):
        status, run = self._request("GET", f"/api/integrations/business-sync/runs/{urllib.parse.quote(str(run_id))}")
        if status != 200 or not isinstance(run, dict) or "status" not in run:
            raise ApiError(f"unexpected run response: HTTP {status}")
        return run
