"""
board_http.py - HTTP to the DE25-Standard's web GUI, for the host tools
(deploy_bundle.py, the tests).

request() sends a POST's headers first and waits a moment: the board answers
a refusal it can make from them (no or wrong token, too big, an install
already running) at once and closes without reading the body. Sending the
body anyway would then end in a broken pipe instead of that answer.
"""
import http.client
import json
import select
import urllib.parse

EARLY_ANSWER_S = 1.0     # how long a POST waits for an answer before its body


def request(url, data=None, headers=None, timeout=10):
    """(status, JSON reply) of a GET, or of a POST when data is given"""
    u = urllib.parse.urlsplit(url)
    c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)
    try:
        c.putrequest("POST" if data is not None else "GET", u.path + ("?" + u.query if u.query else ""))
        for k, v in dict(headers or {}, **({"Content-Length": str(len(data))} if data is not None else {})).items():
            c.putheader(k, v)
        c.endheaders()
        if data and not select.select([c.sock], [], [], EARLY_ANSWER_S)[0]:
            c.sock.sendall(data)
        r = c.getresponse()
        body = r.read()
    finally:
        c.close()
    try:
        return r.status, json.loads(body or b"{}")
    except ValueError:
        return r.status, {"error": body.decode(errors="replace")}
