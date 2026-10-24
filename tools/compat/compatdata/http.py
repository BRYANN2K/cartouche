"""Polite HTTP for the builder: a User-Agent naming the project, a pause between
requests to the same host, and backoff when a host is busy or unreachable."""

import email.utils
import os
import time
import urllib.error
import urllib.parse
import urllib.request

# In CI the repository is the contact address
_REPO = os.environ.get("GITHUB_REPOSITORY")
USER_AGENT = "Cartouche-compat-builder/1 (Cartouche game launcher; nightly, cached" + (
    f"; +https://github.com/{_REPO})" if _REPO else ")")

# Answers worth asking again for. Anything else is final.
RETRY_STATUS = {408, 425, 429, 500, 502, 503, 504}


class Unavailable(Exception):
    """The source did not answer usefully, even after backoff."""


class Fetcher:
    def __init__(self, attempts=4, backoff=2.0, max_wait=120.0, interval=1.0,
                 timeout=60.0, sleep=time.sleep, clock=time.monotonic, opener=None):
        self.attempts = attempts
        self.backoff = backoff
        self.max_wait = max_wait
        self.interval = interval
        self.timeout = timeout
        self.sleep = sleep
        self.clock = clock
        self.opener = opener or urllib.request.build_opener()
        self.last = {}
        self.requests = 0

    def get(self, url, params=None, timeout=None):
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        host = urllib.parse.urlsplit(url).netloc
        reason = "no attempt"
        for attempt in range(self.attempts):
            self._pace(host)
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            wait = self.backoff * (2 ** attempt)
            try:
                self.requests += 1
                with self.opener.open(request, timeout=timeout or self.timeout) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                reason = f"HTTP {error.code}"
                error.close()
                if error.code not in RETRY_STATUS:
                    raise Unavailable(f"{url}: {reason}") from error
                wait = max(wait, _retry_after(error.headers.get("Retry-After")))
            except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
                reason = str(getattr(error, "reason", error))
            finally:
                self.last[host] = self.clock()
            if attempt + 1 < self.attempts:
                self.sleep(min(wait, self.max_wait))
        raise Unavailable(f"{url}: {reason} after {self.attempts} attempts")

    def _pace(self, host):
        if host in self.last:
            gap = self.interval - (self.clock() - self.last[host])
            if gap > 0:
                self.sleep(gap)


def _retry_after(value):
    if not value:
        return 0.0
    try:
        return float(value)
    except ValueError:
        pass
    try:
        when = email.utils.parsedate_to_datetime(value)
        return max(0.0, when.timestamp() - time.time())
    except (TypeError, ValueError):
        return 0.0
