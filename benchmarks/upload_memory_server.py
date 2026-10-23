#!/usr/bin/env python3
"""Local HTTP transport for paired upload measurements; synthetic data only."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import base64
import hashlib
import json
import os
import queue
import subprocess
import sys
import threading
import time

FIRST = 'data: {"choices":[{"index":0,"delta":{"content":"译文OK"}}]}\n\n'.encode()
LAST = b'data: {"choices":[{"index":0,"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_args):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def reply(self, status, length, **headers):
        self.send_response(status)
        self.send_header('Content-Length', str(length))
        for name, value in headers.items():
            self.send_header(name.replace('_', '-'), value)
        self.end_headers()

    def do_POST(self):
        try:
            self.process_upload()
        except BaseException as error:
            self.server.reports.put({'error': repr(error)})
            self.close_connection = True

    def process_upload(self):
        length = int(self.headers['Content-Length'])
        assert 0 < length < 14 * 1024 * 1024
        assert self.headers['Content-Type'] == 'application/json'
        if self.path != '/final':
            assert self.headers['Authorization'] == 'Bearer synthetic-probe-key'
        if self.path == '/reject':
            self.reply(401, 0, Connection='close')
            self.close_connection = True
            self.server.reports.put({'rejected': True})
            return
        if self.path == '/cancel-upload':
            self.server.ready.touch()
            time.sleep(.05)  # Let backpressure hold the producer while cancellation arrives.
            received = 0
            try:
                while received < length:
                    chunk = self.rfile.read1(min(65536, length - received))
                    if not chunk:
                        break
                    received += len(chunk)
            except ConnectionResetError:
                pass
            assert received < length, 'Cancelled upload sent the complete body'
            self.close_connection = True
            self.server.reports.put({'cancelled_upload_bytes': received})
            return
        body = self.rfile.read(length)
        assert len(body) == length
        if self.path in ('/redirect307', '/redirect308'):
            self.reply(int(self.path[-3:]), 0, Location='/final')
        else:
            self.reply(200, len(FIRST) + len(LAST), Content_Type='text/event-stream')
            self.wfile.write(FIRST)
            self.wfile.flush()
            if self.path == '/cancel-response':
                try:
                    assert self.rfile.read(1) == b'', 'Response cancellation did not close the connection'
                except ConnectionResetError:
                    pass
                self.close_connection = True
            else:
                time.sleep(.1)  # Same deliberate waiting interval in both versions.
                self.wfile.write(LAST)
                self.wfile.flush()
        # Validation occurs after the timed response, never on the measured client.
        payload = json.loads(body)
        assert payload['model'] == 'deepseek-flash' and payload['stream'] is True
        assert payload['thinking'] == {'type': 'disabled'} and payload['max_tokens'] == 16384
        content = payload['messages'][1]['content']
        assert len(payload['messages']) == 2 and len(content) == 2
        image = content[1]['image_url']
        assert image['detail'] == 'original'
        prefix, encoded = image['url'].split(',', 1)
        assert prefix == 'data:image/png;base64'
        raw = base64.b64decode(encoded, validate=True)
        assert raw == bytes([0xA5]) * self.server.expected_size
        self.server.reports.put({'body_bytes': length, 'sha256': hashlib.sha256(body).hexdigest()})


def main():
    root = Path(sys.argv[1])
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.reports = queue.Queue()
    server.ready = root / 'upload-headers-received'
    threading.Thread(target=server.serve_forever, daemon=True).start()
    expected_hashes = {}

    def run(version, size, mode='normal'):
        server.expected_size = size
        if server.ready.exists():
            server.ready.unlink()
        environment = {**os.environ, 'PROBE_URL': f'http://127.0.0.1:{server.server_port}/{mode}',
                       'PROBE_READY_PATH': str(server.ready)}
        result = subprocess.run([str(root / f'{version}-probe'), str(size), mode],
                                env=environment, capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr + repr(list(server.reports.queue)))
        for _ in range(2 if mode.startswith('redirect') else 1):
            report = server.reports.get(timeout=10)
            assert 'error' not in report, report
            if 'sha256' in report:
                expected = expected_hashes.setdefault(size, report['sha256'])
                assert report['sha256'] == expected, 'Before/after/replay body bytes differ'
        assert server.reports.empty()
        return result.stdout.strip()

    try:
        # Exercise actual CFNetwork stream replay and cancellation, separately
        # from timing. Both versions must preserve the same transport behavior.
        for version in ('before', 'after'):
            for mode in ('redirect307', 'redirect308', 'cancel-upload', 'cancel-response', 'reject'):
                run(version, 10 * 1024 * 1024, mode)
                print(f'PASS {version}: {mode}', file=sys.stderr, flush=True)
        print('version,run,input_bytes,upload_ms,elapsed_ms,cpu_ms,baseline_MiB,prepared_MiB,waiting_MiB,current_MiB,peak_MiB', flush=True)
        for size in (65536, 1048576, 10485760):
            for repetition in range(1, 6):
                versions = ('before', 'after') if repetition % 2 else ('after', 'before')
                for version in versions:
                    fields = run(version, size).split()
                    print(','.join([version, str(repetition)] + [field.split('=', 1)[1] for field in fields]), flush=True)
        print('PASS: all uploaded bodies and replayed bodies match byte for byte; decoded inputs match.', file=sys.stderr)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
