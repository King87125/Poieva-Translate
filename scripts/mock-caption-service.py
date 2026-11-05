#!/usr/bin/env python3
"""Loopback-only WebSocket protocol fixture. Not a speech recognition model.

Only public synthetic audio is used in tests. No audio or credentials are logged.
The minimal server supports one transcription turn and validates the client wire format.
"""
import base64
import hashlib
import json
import socket
import struct
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    stats_lock = threading.Lock()
    redirect_sink_hits = 0

    def log_message(self, *args):
        pass

    def read_exact(self, length):
        value = bytearray()
        while len(value) < length:
            chunk = self.rfile.read(length - len(value))
            if not chunk:
                raise EOFError()
            value.extend(chunk)
        return value

    def receive(self):
        first, second = self.read_exact(2)
        if first & 15 == 8:
            raise EOFError()
        assert first == 0x81 and second & 0x80
        length = second & 127
        if length == 126:
            length = struct.unpack('!H', self.read_exact(2))[0]
        elif length == 127:
            length = struct.unpack('!Q', self.read_exact(8))[0]
        assert length <= 65536
        mask = self.read_exact(4)
        data = self.read_exact(length)
        return json.loads(bytes(value ^ mask[index % 4] for index, value in enumerate(data)))

    def send(self, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        header = bytes([0x81, len(data)]) if len(data) < 126 else bytes([0x81, 126]) + struct.pack('!H', len(data))
        self.wfile.write(header + data)
        self.wfile.flush()

    def do_GET(self):
        if self.path == '/fixture-stats':
            with self.stats_lock:
                data = json.dumps({'redirect_sink_hits': type(self).redirect_sink_hits}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith('/forbidden'):
            self.send_error(401)
            return
        if self.path.startswith('/redirect'):
            self.send_response(302)
            self.send_header('Location', 'ws://127.0.0.1:19084/credential-sink')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/credential-sink'):
            with self.stats_lock:
                type(self).redirect_sink_hits += 1
            print('ERROR: Client followed a WebSocket redirect', flush=True)
            self.send_error(400)
            return
        route = urlsplit(self.path)
        qwen = route.path == '/api-ws/v1/realtime' and set(parse_qs(route.query)) == {'model'}
        if self.path != '/v1/realtime?intent=transcription' and not qwen:
            self.send_error(404)
            return
        key = self.headers.get('Sec-WebSocket-Key', '')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        self.connection.settimeout(30)
        try:
            if qwen:
                self.handle_qwen(parse_qs(route.query)['model'][0])
                return
            update = self.receive()
            assert update['type'] == 'session.update'
            session = update['session']
            assert session['type'] == 'transcription'
            audio = session['audio']['input']
            assert audio['format'] == {'type': 'audio/pcm', 'rate': 24000}
            assert audio['turn_detection'] is None
            model = audio['transcription']['model']
            if model == 'fixture-wait':
                self.receive()
                return
            if model == 'fixture-wrong-session':
                self.send({'type': 'session.updated', 'session': {'type': 'realtime'}})
                self.receive()
                return
            assert model in ['fixture-valid', 'fixture-auth']
            if model == 'fixture-auth':
                assert self.headers.get('Authorization') == 'Bearer fixture-only-key'
            self.send({'type': 'session.updated', 'session': session})
            received_audio = False
            while True:
                event = self.receive()
                if event['type'] == 'input_audio_buffer.append':
                    data = base64.b64decode(event['audio'], validate=True)
                    assert len(data) <= 19200 and len(data) % 2 == 0
                    if not received_audio:
                        received_audio = True
                        self.send({'type': 'conversation.item.input_audio_transcription.delta', 'item_id': 'one', 'delta': 'Hello,'})
                elif event['type'] == 'input_audio_buffer.commit':
                    assert received_audio
                    self.send({'type': 'input_audio_buffer.committed', 'item_id': 'one', 'previous_item_id': None})
                    self.send({'type': 'conversation.item.input_audio_transcription.completed', 'item_id': 'one', 'transcript': 'Hello, how are you?'})
                    print('Public audio turn received and transcribed by fixed protocol fixture.', flush=True)
        except (EOFError, OSError, ValueError, KeyError, AssertionError):
            pass
        finally:
            self.close_connection = True

    def handle_qwen(self, model):
        """Qwen VAD wire fixture; snapshots replace earlier text, never append."""
        assert self.headers.get('Authorization') in (None, 'Bearer fixture-only-key')
        self.send({'type': 'session.created', 'session': {'model': model}})
        update = self.receive()
        assert update['type'] == 'session.update' and update['event_id']
        session = update['session']
        assert session['input_audio_format'] == 'pcm' and session['sample_rate'] == 16000
        assert session['turn_detection'] == {'type': 'server_vad', 'threshold': 0.0, 'silence_duration_ms': 400}
        assert 'audio' not in session and 'type' not in session
        if model == 'fixture-qwen-wait':
            self.receive()
            return
        ready = {'model': model, 'modalities': ['text'], 'input_audio_format': 'pcm16',
                 'sample_rate': 16000, 'turn_detection': session['turn_detection']}
        if model == 'fixture-qwen-wrong':
            ready['sample_rate'] = 24000
        self.send({'type': 'session.updated', 'session': ready})
        if model == 'fixture-qwen-wrong':
            self.receive()
            return
        assert model == 'qwen3-asr-flash-realtime'
        event_ids = {update['event_id']}
        packets = 0
        while True:
            event = self.receive()
            event_id = event.get('event_id')
            assert event_id and event_id not in event_ids
            event_ids.add(event_id)
            if event['type'] == 'input_audio_buffer.append':
                data = base64.b64decode(event['audio'], validate=True)
                assert 0 < len(data) <= 12800 and len(data) % 2 == 0
                packets += 1
                if packets == 1:
                    self.send({'type': 'input_audio_buffer.committed', 'item_id': 'qwen-one', 'previous_item_id': None})
                    self.send({'type': 'conversation.item.input_audio_transcription.text', 'item_id': 'qwen-one', 'text': '', 'stash': 'Hello,'})
                elif packets == 2:
                    self.send({'type': 'conversation.item.input_audio_transcription.text', 'item_id': 'qwen-one', 'text': 'Hello, ', 'stash': 'how are you?'})
            elif event['type'] == 'session.finish':
                if packets:
                    self.send({'type': 'conversation.item.input_audio_transcription.completed', 'item_id': 'qwen-one', 'transcript': 'Hello, how are you?'})
                self.send({'type': 'session.finished'})
                print('Public Qwen PCM16/16k turn flushed by fixed protocol fixture.', flush=True)
                return
            else:
                raise AssertionError('Unexpected client event in server VAD mode')


if __name__ == '__main__':
    print('Caption protocol fixture: ws://127.0.0.1:19084/v1/realtime (not a real ASR model)', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 19084), Handler).serve_forever()
