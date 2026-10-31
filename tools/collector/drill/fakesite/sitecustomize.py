"""Drill-only urllib patch (process-pair drill, scenario A/C).

The sidecar's REST transport is stdlib ``urllib.request.urlopen``
(sidecar.py do_rest: POST {rest_domain}/api/dostk/rkinfo), and stdlib
modules cannot be shadowed through PYTHONPATH the way a site package
can. This ``sitecustomize`` is auto-imported at interpreter start when
tools/collector/drill/fakesite is on PYTHONPATH, and patches
``urllib.request.urlopen`` with a simulated ka10027 endpoint.

Scope guard (fail-safe): the patch is installed ONLY when the drill
driver exported ``HSDRILL=1``. Without it this file is completely inert
— no import side effect beyond this check — so a leaked PYTHONPATH can
never patch urllib outside the drill. The drill environment is built per
run by tools/collector/drill/drill_pair.sh; default behavior elsewhere
is byte-identical.

Simulated responses: one terminal ka10027 page per direction (headers
``cont-yn: N``, no next-key), body from drill_fixtures.ka10027_page —
the documented list key/row fields/return_code facts (see
drill_fixtures.py header for the sources). The request's authorization
header is inspected for presence only (the transport must send it,
README §2.4) and its value is never logged (README §5: 토큰 값은 어디에도
출력되지 않는다).
"""

import json
import os

if os.environ.get("HSDRILL") == "1":  # drill-only: inert anywhere else
    import urllib.request

    import drill_fixtures as fx

    _log = fx.wirelog()

    class _FakeRESTResponse:
        """The slice of urlopen()'s result sidecar.py do_rest uses:
        status / headers.get(...) / read(), as a context manager."""

        def __init__(self, status, headers, body):
            self.status = status
            self.headers = headers
            self._body = body

        def read(self):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def _drill_urlopen(req, timeout=None):
        url = req.full_url
        headers = {k.lower(): v for k, v in req.header_items()}
        body = json.loads(req.data.decode("utf-8")) if req.data else {}
        if url != "https://mockapi.kiwoom.com/api/dostk/rkinfo":
            raise AssertionError("drill fake: unexpected REST url %r" % url)
        if req.get_method() != "POST":
            raise AssertionError("drill fake: unexpected REST method %r"
                                 % req.get_method())
        if headers.get("api-id") != "ka10027":
            raise AssertionError("drill fake: api-id header missing: %r"
                                 % headers.get("api-id"))
        if not headers.get("authorization"):
            raise AssertionError("drill fake: authorization header missing")
        sort_tp = body.get("sort_tp")
        if sort_tp not in ("1", "3"):
            raise AssertionError("drill fake: sort_tp not 1|3: %r" % sort_tp)
        direction = "up" if sort_tp == "1" else "down"
        codes = [fx.UP_CODE] if direction == "up" else [fx.DOWN_CODE]
        if _log:
            # Never logs authorization or any body field but sort_tp.
            _log(ev="rest_request", method=req.get_method(), path=url,
                 api_id=headers.get("api-id"), sort_tp=sort_tp,
                 direction=direction, timeout=timeout)
        # Terminal page: cont-yn "N", no next-key (README §2.4: 페이지
        # 반복 판단은 core — 단말 cont_yn으로 감사된다).
        return _FakeRESTResponse(
            200, {"cont-yn": "N"}, fx.ka10027_page(codes))

    urllib.request.urlopen = _drill_urlopen
