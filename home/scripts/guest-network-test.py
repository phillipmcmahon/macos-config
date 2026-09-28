#!/usr/bin/env python3
"""Guest network checks for Phill's UniFi home network. Version 1.0.2.

Run after joining guestwifi and completing the captive portal:
    python3 guest-network-test.py
    python3 guest-network-test.py --interface en0

Requires Python 3.8+, curl and dig. Supports macOS and Linux (iproute2).
No sudo, packages, configuration changes, logins or file uploads are performed.
Only DNS lookups, TCP connections and bounded, unauthenticated HTTP GETs are sent.
The only persistent local change is the text report in the current directory.

Expectations: 28 September 2026 UniFi backup and NPM screenshots, with guest
DHCP DNS restored to 10.77.180.1 as agreed. Hypervisor is 10.77.130.20 in this
backup. The script deliberately does not use the older .241 address.
Updated policy: guest access to KEF TCP port 80 was removed on 28 September
2026. All three KEF HTTP endpoints are now checked as denied on every run.

PASS = a positive response supports the stated expectation.
FAIL = a definite mismatch (including an expected service failing to respond).
BLOCKED = TCP did not connect. This is an observation, not proof of which
firewall blocked it. A stopped service or offline host can give the same result.
WARN = result needs interpretation. SKIP = the check could not safely run.
Exit codes: 0 no FAIL results, 1 one or more FAIL results, 2 setup error.
WARN/BLOCKED/SKIP results still need review even with exit code 0.

Limits: these are point-in-time samples, not every port or firewall rule.
No IPS attack simulation, UDP/QUIC blocking assertion, playback test or TLS
interception is performed. Portal listeners/TLS are checked, not authentication.
Other DNS-over-HTTPS providers and VPNs are outside the fixed resolver list.
An internal NPM ACL cannot be isolated from guest when the network blocks
the connection before it reaches NPM. Check that ACL from an allowed network.

Technical references:
https://help.ui.com/hc/en-us/articles/12568927589143-Content-and-Domain-Filtering-in-UniFi
https://help.ui.com/hc/en-us/articles/9794438523799-UniFi-Gateway-Ad-Blocking
https://developers.cloudflare.com/1.1.1.1/setup/
https://curl.se/docs/manpage.html
"""

import argparse
import concurrent.futures
import datetime
import errno
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

VERSION = '1.0.2'
GUEST_NET = ipaddress.ip_network('10.77.180.0/24')
GATEWAY = '10.77.180.1'
DMZ = '10.77.170.50'
SERVICES = '10.77.130.34'
DOMAIN = 'phillipmcmahon.com'
PORTAL = 'wifi.guest.' + DOMAIN
PORTAL_IP = '10.77.1.1'
# AP redirector.url in the supplied backup uses this portal endpoint.
PORTAL_PORT = 8444
PORTAL_PATH = '/guest/s/default/'
ADMIN = 'proxy.dmz.' + DOMAIN
BACKEND_PORTS = [3900, 4533, 8096, 9445, 18080, 18096, 22280, 22299, 47823]
PUBLIC_APPS = ['emby', 'jellyfin', 'moodist', 'music', 'ntfy', 'romm',
               'unifi-reader', 'vault']
SERVICES_NAMES = ['admin.s3', 'ajtnas', 'convertx', 'copyparty', 'deemix',
                  'filebot', 'hedgedoc', 'hotelnas', 'kvm', 'nas', 'plex',
                  'proxy.services', 'torrents']
S3_BUCKETS = ['b78452a7dcd84e269a07c57a4cbdf282.s3',
              'dd7ae9cfed0b5d34b9a2a7e03514057d.s3']
PUBLIC_RESOLVERS = ['1.1.1.1', '1.0.0.1', '1.1.1.2', '1.0.0.2', '1.1.1.3',
                    '1.0.0.3', '8.8.8.8', '8.8.4.4', '9.9.9.9', '149.112.112.112']
FILTER_DOMAINS = ['malware.testcategory.com', 'nudity.testcategory.com',
                  'www.googleadservices.com']
KNOWN_BLOCK_IPS = {'0.0.0.0', '127.0.0.1', GATEWAY, PORTAL_IP,
                   '162.159.36.12', '162.159.46.12', '203.0.113.250'}
# UniFi UBIOS_BLOCKPAGE_JUMP uses the exact 203.0.113.250 address.
# This is a DNS filtering signature, not a check that its block page renders.
# First-hand rule dump:
# https://community.ui.com/questions/Clients-not-using-dedicated-DNS-servers-after-update/3cc09143-12a5-426a-a348-ae64708ea626


def command(args, timeout=8):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, errors='replace', timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, '', 'command exceeded its timeout'
    except OSError as e:
        return 127, '', str(e)


def clean(text, limit=350):
    return re.sub(r'[\x00-\x1f\x7f]', ' ', str(text))[:limit].strip()


def parse_dns(text, code=0):
    match = re.search(r'status: ([A-Z]+)', text)
    records = []
    for line in text.splitlines():
        if line.startswith(';'):
            continue
        parts = line.split()
        if len(parts) >= 5 and parts[2] == 'IN':
            records.append((parts[0].rstrip('.').lower(), parts[3], parts[4].rstrip('.')))
    return {'code': code, 'status': match.group(1) if match else '',
            'records': records, 'ips': [v for _, t, v in records if t == 'A'],
            'cnames': [v.lower() for _, t, v in records if t == 'CNAME'],
            'ede_block': bool(re.search(r'EDE: (?:15|16|17|18)\b', text)),
            'raw': text}


def dns_summary(d):
    return 'status={} A={} CNAME={}'.format(d['status'] or 'no response',
        ','.join(d['ips']) or '-', ','.join(d['cnames']) or '-')


def classify_tcp(expected, connected, error='', optional=False):
    if connected:
        return ('PASS', 'TCP connection established') if expected else (
            'FAIL', 'TCP connection established to an endpoint that should be inaccessible')
    if expected:
        return ('WARN' if optional else 'FAIL', error)
    return 'BLOCKED', error + '. No TCP connection. Firewall attribution is unproven'


def http_size_capped(r):
    # Some curl builds report the deliberate body limit as 56 instead of 63.
    # Do not accept other receive failures or responses with no HTTP status.
    return 200 <= r['status'] < 600 and (r['rc'] == 63 or (
        r['rc'] == 56 and 'maximum file size exceeded' in r['error'].lower()))


def http_transport_ok(r):
    return 200 <= r['status'] < 600 and (r['rc'] == 0 or http_size_capped(r))


def classify_http(r, mode='app'):
    status = r['status']
    if r['rc'] == 60:
        return 'FAIL', 'TLS certificate validation failed. This is not a successful access denial'
    if not http_transport_ok(r):
        return 'FAIL', 'HTTP/TLS request failed (HTTP {}, curl={}): {}'.format(status, r['rc'], r['error'])
    if mode == 'admin':
        if status == 403:
            if re.search(r'nginx|openresty', r['headers'], re.I):
                return 'PASS', 'HTTP 403 from nginx/openresty, consistent with the NPM admin ACL'
            return 'WARN', 'HTTP 403 received, but the responding component is not identified as NPM'
        return 'FAIL', 'Expected HTTP 403 from the NPM admin ACL, received HTTP {}'.format(status)
    if mode == 's3':
        if status in (401, 403) and re.search(r'<(?:\w+:)?Code>AccessDenied</', r['body']):
            return 'PASS', 'S3 AccessDenied response: bucket endpoint reached, anonymous access denied'
        if 200 <= status < 300:
            return 'WARN', 'S3 answered HTTP {} without credentials. Review whether anonymous access is intended'.format(status)
        return 'WARN', 'S3 answered HTTP {}. This does not establish bucket health or permissions'.format(status)
    if status in (502, 503, 504):
        return 'FAIL', 'Proxy answered HTTP {}: upstream service unavailable'.format(status)
    if 200 <= status < 400 or status == 401:
        return 'PASS', 'HTTPS endpoint responded with HTTP {}. Application login/playback is not tested'.format(status)
    return 'WARN', 'HTTPS endpoint answered HTTP {}. Inspect the application or NPM logs'.format(status)


class Audit:
    def __init__(self, args):
        self.args = args
        self.os = platform.system()
        self.iface = ''
        self.source = ''
        self.route_cache = {}
        self.rows = []
        self.internet_ok = False
        stamp = datetime.datetime.now().strftime('%Y%m%dT%H%M%S%f')
        self.path = Path(args.output or ('guest-network-test-' + stamp + '.txt')).expanduser()
        fd = os.open(str(self.path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        self.log = os.fdopen(fd, 'w', encoding='utf-8')
        self.use_colour = args.colour == 'always' or (args.colour == 'auto' and sys.stdout.isatty())

    def say(self, text=''):
        print(text, flush=True)
        self.log.write(text + '\n')
        self.log.flush()

    def result(self, level, name, detail):
        self.rows.append((level, name, detail))
        line = '[{:<7}] {}: {}'.format(level, name, clean(detail, 650))
        self.log.write(line + '\n')
        self.log.flush()
        colours = {'PASS': '32', 'FAIL': '31', 'WARN': '33', 'BLOCKED': '36', 'SKIP': '33'}
        print(('\033[' + colours.get(level, '0') + 'm' + line + '\033[0m')
              if self.use_colour else line, flush=True)

    def section(self, title):
        self.say('\n' + title)

    def route(self, target):
        if target in self.route_cache:
            return self.route_cache[target]
        if self.os == 'Darwin':
            rc, out, err = command(['/sbin/route', '-n', 'get', target])
            data = dict(re.findall(r'^\s*(interface|gateway):\s*(\S+)', out, re.M))
            answer = {'dev': data.get('interface'), 'gateway': data.get('gateway'), 'src': None}
        else:
            rc, out, err = command(['ip', '-j', '-4', 'route', 'get', target])
            try:
                data = json.loads(out)[0]
            except (ValueError, IndexError, TypeError):
                data = {}
            answer = {'dev': data.get('dev'), 'gateway': data.get('gateway'),
                      'src': data.get('prefsrc') or data.get('src')}
        if rc or not answer.get('dev'):
            raise RuntimeError('Cannot inspect route to {}: {}'.format(target, clean(err or out)))
        self.route_cache[target] = answer
        return answer

    def safe_route(self, target):
        try:
            r = self.route(target)
            if r['dev'] != self.iface:
                return 'route uses {}, not selected guest interface {}'.format(r['dev'], self.iface)
            if r.get('src') and r['src'] != self.source:
                return 'route source {} differs from guest source {}'.format(r['src'], self.source)
            if ipaddress.ip_address(target) not in GUEST_NET and r.get('gateway') != GATEWAY:
                return 'route does not use guest gateway {} (reported {})'.format(GATEWAY, r.get('gateway'))
            return ''
        except (RuntimeError, ValueError) as e:
            return str(e)

    def preflight(self):
        self.say('guest-network-test.py v' + VERSION)
        self.say('Started: ' + datetime.datetime.now().astimezone().isoformat(timespec='seconds'))
        self.say('Read-only, IPv4 checks. Complete guest portal login before running.')
        self.say('Report: ' + str(self.path.resolve()))
        self.say('BLOCKED means no TCP connection, not proof of a particular firewall rule.')
        if self.os not in ('Darwin', 'Linux'):
            raise RuntimeError('This script supports macOS and Linux.')
        for tool in ['curl', 'dig'] + (['ip'] if self.os == 'Linux' else []):
            if not shutil.which(tool):
                raise RuntimeError('Required command is missing: ' + tool)
        self.section('1. Guest attachment and routing')
        r = self.route('1.1.1.1')
        self.iface = self.args.interface or r['dev']
        if self.iface != r['dev']:
            raise RuntimeError('Default route uses {}. Disconnect other links/VPNs before testing {}.'.format(r['dev'], self.iface))
        if r.get('gateway') != GATEWAY:
            raise RuntimeError('Internet route does not use guest gateway {}. Reported gateway: {}'.format(GATEWAY, r.get('gateway')))
        if self.os == 'Darwin':
            rc, out, err = command(['/usr/sbin/ipconfig', 'getifaddr', self.iface])
            self.source = out.strip()
            rc6, out6, _ = command(['/sbin/ifconfig', self.iface])
            ipv6s = re.findall(r'\binet6\s+([0-9a-fA-F:]+)', out6)
            rc_dns, dns, _ = command(['/usr/sbin/ipconfig', 'getoption', self.iface, 'domain_name_server'])
            configured = re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', dns) if rc_dns == 0 else []
        else:
            rc, out, err = command(['ip', '-j', 'address', 'show', 'dev', self.iface])
            try:
                entries = json.loads(out)[0]['addr_info']
            except (ValueError, IndexError, KeyError, TypeError):
                raise RuntimeError('Cannot read interface addresses.')
            candidates = [x['local'] for x in entries if x.get('family') == 'inet'
                          and ipaddress.ip_address(x['local']) in GUEST_NET]
            self.source = r.get('src') or (candidates[0] if candidates else '')
            ipv6s = [x['local'] for x in entries if x.get('family') == 'inet6']
            configured = []
            if shutil.which('resolvectl'):
                _, dns, _ = command(['resolvectl', 'dns', self.iface])
                configured = re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', dns)
            elif shutil.which('nmcli'):
                _, dns, _ = command(['nmcli', '-g', 'IP4.DNS', 'device', 'show', self.iface])
                configured = re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', dns)
        try:
            if ipaddress.ip_address(self.source) not in GUEST_NET:
                raise ValueError()
        except ValueError:
            raise RuntimeError('Selected interface has no usable 10.77.180.x source address.')
        self.result('PASS', 'Guest attachment', '{} source={} gateway={}'.format(self.iface, self.source, GATEWAY))
        self.result('PASS' if configured == [GATEWAY] else 'WARN', 'Advertised/configured DNS',
                    '{}. Expected only {}. DHCP information does not prove which resolver every app uses'.format(', '.join(configured) or 'not readable', GATEWAY))
        unwanted = [x for x in ipv6s if not (ipaddress.ip_address(x).is_link_local or ipaddress.ip_address(x).is_loopback)]
        self.result('FAIL' if unwanted else 'PASS', 'IPv6 addressing',
                    'Unexpected non-link-local addresses: ' + ', '.join(unwanted) if unwanted
                    else 'No non-link-local IPv6 address on the guest interface. IPv6 traffic is not tested')
        if any(os.environ.get(x) for x in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')):
            self.result('INFO', 'Proxy environment', 'Ignored by curl. Every request is direct and uses the guest source address')
        self.result('INFO', 'Network scope', 'Per-destination routes are checked. OS network extensions/Private Relay still require manual review')

    def dns(self, host, server=GATEWAY, tcp=False):
        problem = self.safe_route(server)
        if problem:
            return {'problem': problem}
        args = ['dig', '-4', '-b', self.source, '@' + server, host.rstrip('.') + '.',
                'A', '+time=2', '+tries=1', '+nosearch']
        args += ['+tcp'] if tcp else ['+notcp', '+ignore']
        rc, out, err = command(args, timeout=5)
        return parse_dns(out + '\n' + err, rc)

    def check_dns(self, name, host, expected=None, server=GATEWAY, tcp=False):
        d = self.dns(host, server, tcp)
        if 'problem' in d:
            self.result('SKIP', name, d['problem'])
            return d
        good = (d['code'] == 0 and d['status'] == 'NOERROR' and bool(d['ips']))
        if expected:
            good = good and set(d['ips']) == {expected}
        self.result('PASS' if good else 'FAIL', name, dns_summary(d))
        return d

    def tcp(self, name, ip, port, expected=False, optional=False):
        problem = self.safe_route(ip)
        if problem:
            return 'SKIP', name, problem
        started = time.monotonic()
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(self.args.timeout)
                s.bind((self.source, 0))
                s.connect((ip, port))
            level, detail = classify_tcp(expected, True)
        except OSError as e:
            if isinstance(e, socket.timeout) or e.errno == errno.ETIMEDOUT:
                reason = 'timed out'
            elif e.errno == errno.ECONNREFUSED:
                reason = 'connection refused/rejected'
            elif e.errno in (errno.EHOSTUNREACH, errno.ENETUNREACH):
                reason = 'host/network unreachable'
            elif e.errno in (errno.EADDRNOTAVAIL, errno.EACCES, errno.EPERM):
                return 'WARN', name, 'Local test error: ' + str(e)
            else:
                return 'WARN', name, 'Unclassified connection error: ' + str(e)
            level, detail = classify_tcp(expected, False, reason, optional)
        return level, name, '{}:{} {} ({:.1f}s)'.format(ip, port, detail, time.monotonic() - started)

    def tcp_batch(self, jobs):
        # Small, bounded concurrency. This is an explicit endpoint list, not a scan.
        for ip in set(job[1] for job in jobs):
            self.safe_route(ip)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            pending = [pool.submit(self.tcp, *job) for job in jobs]
            for future in pending:
                self.result(*future.result())

    def http(self, host, ip, scheme='https', port=None, path='/', headers=None):
        problem = self.safe_route(ip)
        if problem:
            return {'problem': problem}
        port = port or (443 if scheme == 'https' else 80)
        url = '{}://{}:{}{}'.format(scheme, host, port, path)
        with tempfile.TemporaryDirectory(prefix='guest-check-') as tmp:
            hdr, body = str(Path(tmp) / 'headers'), str(Path(tmp) / 'body')
            args = ['curl', '-q', '-4', '--silent', '--show-error', '--noproxy', '*',
                    '--interface', self.source, '--connect-timeout', str(self.args.timeout),
                    '--max-time', str(self.args.timeout + 5), '--max-filesize', '262144',
                    '--resolve', '{}:{}:{}'.format(host, port, ip),
                    '--dump-header', hdr, '--output', body,
                    '--write-out', '%{http_code}\t%{remote_ip}\t%{local_ip}',
                    '--user-agent', 'guest-network-test/' + VERSION]
            for h in headers or []:
                args += ['--header', h]
            args.append(url)
            rc, out, err = command(args, self.args.timeout + 8)
            fields = out.strip().split('\t')
            status = int(fields[0]) if fields and fields[0].isdigit() else 0
            response_headers = Path(hdr).read_text(errors='replace') if Path(hdr).exists() else ''
            response_body = ''
            if Path(body).exists():
                with open(body, 'rb') as f:
                    response_body = f.read(65536).decode('utf-8', 'replace')
            if len(fields) > 2 and fields[2] and fields[2] != self.source:
                return {'problem': 'curl used unexpected source address ' + fields[2]}
            return {'rc': rc, 'status': status, 'error': clean(err),
                    'headers': response_headers, 'body': response_body,
                    'remote': fields[1] if len(fields) > 1 else '', 'url': url}

    def check_http(self, name, host, ip, mode='app'):
        r = self.http(host, ip)
        if 'problem' in r:
            self.result('SKIP', name, r['problem'])
        else:
            level, detail = classify_http(r, mode)
            if http_size_capped(r):
                detail += '. Body download stopped at the intentional 256 KiB limit'
            self.result(level, name, detail)
        return r

    def dns_and_internet(self):
        self.section('2. Gateway DNS, internet access and captive portal')
        a = self.check_dns('External lookup through guest DNS / UDP', 'example.com')
        self.check_dns('External lookup through guest DNS / TCP', 'example.com', tcp=True)
        self.check_dns('Portal local DNS', PORTAL, PORTAL_IP)
        if 'problem' not in a and a['ips'] and a['status'] == 'NOERROR':
            ip = a['ips'][0]
            if ipaddress.ip_address(ip).is_global:
                r = self.http('example.com', ip)
                if 'problem' in r:
                    self.result('SKIP', 'Internet HTTPS', r['problem'])
                else:
                    self.internet_ok = http_transport_ok(r) and r['status'] == 200
                    self.result('PASS' if self.internet_ok else 'FAIL', 'Internet HTTPS',
                                'HTTP {} curl={}. TLS verified unless a TLS error is reported. {}'.format(r['status'], r['rc'], r['error']))
                plain = self.http('example.com', ip, scheme='http')
                if 'problem' not in plain:
                    location = re.search(r'^location:\s*(.+)', plain['headers'], re.I | re.M)
                    redirected = bool(location and (PORTAL in location.group(1) or '10.77.' in location.group(1)))
                    self.result('WARN' if redirected or not http_transport_ok(plain) or plain['status'] != 200 else 'PASS',
                                'Internet HTTP / portal interception',
                                'Guest portal redirect still present. Complete login in a browser and rerun' if redirected
                                else 'HTTP {} curl={}. A 200 alone does not certify portal authentication. {}'.format(plain['status'], plain['rc'], plain['error']))
            else:
                self.result('FAIL', 'Internet DNS', 'example.com resolved to a non-public address: ' + ip)
        if not self.internet_ok:
            self.result('WARN', 'Negative-test confidence', 'Internet positive control failed. Do not interpret external connection failures as proven DNS blocking')
        self.tcp_batch([('Configured portal HTTPS listener', PORTAL_IP, PORTAL_PORT, True, True)])
        portal = self.http(PORTAL, PORTAL_IP, port=PORTAL_PORT, path=PORTAL_PATH)
        if 'problem' in portal:
            self.result('SKIP', 'Portal HTTPS certificate', portal['problem'])
        elif http_transport_ok(portal):
            self.result('PASS', 'Portal HTTPS certificate',
                        'TLS hostname/CA validation succeeded on port {}. HTTP {} at {} does not verify the complete portal journey'.format(PORTAL_PORT, portal['status'], PORTAL_PATH))
        else:
            self.result('WARN', 'Portal HTTPS certificate',
                        'No verified HTTPS response on {}: {}. Check the actual portal URL and browser certificate'.format(PORTAL_PORT, portal['error']))
        self.result('INFO', 'Portal browser check', 'Listener checks do not verify the complete portal journey. Use a fresh unauthorised guest session to check redirect, certificate and acceptance')

    def redirection(self):
        self.section('3. Plain DNS interception and encrypted DNS egress')
        # TEST-NET-1 cannot be a legitimate public resolver. A matching local
        # answer from 192.0.2.53 provides stronger evidence than SERVER in dig.
        for server in ['1.1.1.1', '8.8.8.8', '192.0.2.53']:
            for tcp in (False, True):
                name = 'DNS interception via {} / {}'.format(server, 'TCP' if tcp else 'UDP')
                self.check_dns(name, PORTAL, PORTAL_IP, server, tcp)
        self.result('INFO', 'DNS interpretation', 'Answers to public DNS IPs are expected: guest-gateway-redirect-dns captures TCP/UDP 53. The dig SERVER field cannot prove the original server answered')
        jobs = []
        for ip in PUBLIC_RESOLVERS:
            jobs.append(('DoH destination TCP block', ip, 443, False, False))
        for ip in ['1.1.1.1', '8.8.8.8', '9.9.9.9']:
            jobs.append(('DoT TCP block', ip, 853, False, False))
        self.tcp_batch(jobs)
        self.result('INFO', 'Encrypted DNS coverage', 'TCP destination checks only. UDP 443/853, DoQ and providers outside the configured resolver IP list need separate tests')

    def filtering(self):
        self.section('4. Content filtering and SafeSearch')
        for host in FILTER_DOMAINS + self.args.blocked_domain:
            d = self.dns(host)
            if 'problem' in d:
                self.result('SKIP', host, d['problem'])
                continue
            ips = set(d['ips'])
            if d['code'] == 0 and d['ede_block']:
                self.result('PASS', host, 'DNS explicitly reports a policy block (EDE). ' + dns_summary(d))
            elif d['code'] == 0 and ips and ips.issubset(KNOWN_BLOCK_IPS):
                detail = 'DNS returned only recognised sinkhole/block-page addresses. '
                if '203.0.113.250' in ips:
                    detail += 'UniFi block-page destination recognised. Page rendering is not tested. '
                self.result('PASS', host, detail + dns_summary(d))
            else:
                # NXDOMAIN/REFUSED alone can also mean a missing domain or a
                # resolver problem. A timeout is never considered a pass.
                self.result('WARN', host, 'No conclusive filtering signature. ' + dns_summary(d)
                            + '. Check the guest Content Filter log for this exact query')
            if d.get('code') == 0 and ips and ips.issubset(KNOWN_BLOCK_IPS):
                other = self.dns(host, '1.1.1.1')
                if 'problem' in other:
                    self.result('SKIP', host + ' via 1.1.1.1', other['problem'])
                else:
                    same = other['code'] == 0 and set(other['ips']) == ips
                    self.result('PASS' if same else 'WARN', host + ' via 1.1.1.1',
                                'Same filtered answer after DNS redirection' if same else dns_summary(other))
        for host, forced in [('www.google.com', 'forcesafesearch.google.com'),
                             ('www.bing.com', 'strict.bing.com')]:
            actual, reference = self.dns(host), self.dns(forced)
            if 'problem' in actual or 'problem' in reference:
                self.result('SKIP', host + ' SafeSearch', actual.get('problem') or reference.get('problem'))
                continue
            public_reference = bool(reference['ips']) and all(
                ipaddress.ip_address(x).is_global and x not in KNOWN_BLOCK_IPS for x in reference['ips'])
            supported = actual['code'] == reference['code'] == 0 and (
                actual['status'] == reference['status'] == 'NOERROR') and public_reference and (
                forced in actual['cnames'] or bool(set(actual['ips']) & set(reference['ips'])))
            self.result('PASS' if supported else 'WARN', host + ' SafeSearch',
                        'DNS answer matches the forced SafeSearch endpoint' if supported
                        else 'No matching DNS evidence. ' + dns_summary(actual))
        self.result('INFO', 'Filter scope', 'Harmless vendor test domains and an ad-domain DNS query only. Category mappings and block-page IPs can vary. WARN is not a confirmed bypass. No malware/adult site content is downloaded')

    def isolation(self):
        self.section('5. Expected network denials')
        jobs = []
        for ip in [GATEWAY, PORTAL_IP]:
            for port in [22, 443]:
                jobs.append(('Gateway management denied', ip, port, False, False))
        for ip, ports, label in [
            ('10.77.130.28', [445, 5001, 3260], 'NAS direct access denied'),
            ('10.77.130.20', [22, 443], 'Hypervisor management denied'),
            ('10.77.130.22', [443], 'XOA management denied'),
            (SERVICES, [22, 80, 443], 'Services host direct access denied'),
            (DMZ, [22, 81, 8080, 8081, 8443], 'DMZ management/untranslated ports denied'),
            ('10.77.120.14', [22, 445], 'Trusted Mac mini access denied'),
            ('10.77.140.80', [80, 443, 9100], 'IoT printer direct access denied')]:
            for port in ports:
                jobs.append((label, ip, port, False, False))
        for port in BACKEND_PORTS:
            jobs.append(('Direct proxy backend denied', SERVICES, port, False, False))
        self.tcp_batch(jobs)
        self.result('INFO', 'Confirming a firewall rule', 'For BLOCKED entries, confirm that the target is listening from an authorised host and match the attempt to UniFi/host firewall logs. Guest observations cannot distinguish every protection layer')

    def npm(self):
        self.section('6. DMZ NPM access, TLS and admin denial')
        self.tcp_batch([('DMZ NPM HTTP allowed', DMZ, 80, True, False),
                        ('DMZ NPM HTTPS allowed', DMZ, 443, True, False)])
        for short in PUBLIC_APPS:
            host = short + '.' + DOMAIN
            self.check_dns(host + ' local DNS', host, DMZ)
            self.check_http(host + ' via DMZ NPM', host, DMZ)
        self.check_dns('DMZ NPM admin DNS', ADMIN, DMZ)
        self.check_http('DMZ NPM admin ACL', ADMIN, DMZ, mode='admin')
        redirect = self.http(ADMIN, DMZ, scheme='http')
        if 'problem' not in redirect:
            location = re.search(r'^location:\s*(.+)', redirect['headers'], re.I | re.M)
            target = urlsplit(location.group(1).strip()) if location else None
            safe_redirect = bool(target and target.scheme == 'https' and target.hostname == ADMIN)
            if not http_transport_ok(redirect):
                self.result('WARN', 'NPM admin HTTP', 'Request failed: HTTP {} curl={} {}'.format(redirect['status'], redirect['rc'], redirect['error']))
            elif redirect['status'] == 403:
                self.result('PASS', 'NPM admin HTTP', 'HTTP 403 denial')
            elif 300 <= redirect['status'] < 400 and safe_redirect:
                self.result('PASS', 'NPM admin HTTP', 'Redirects to HTTPS on the same admin hostname, whose ACL is tested separately')
            elif redirect['status'] == 200:
                self.result('FAIL', 'NPM admin HTTP', 'Admin hostname returned HTTP 200 over plain HTTP')
            else:
                self.result('WARN', 'NPM admin HTTP', 'Unexpected response HTTP {} curl={}'.format(redirect['status'], redirect['rc']))
        for short in S3_BUCKETS:
            self.check_http(short + ' via DMZ NPM', short + '.' + DOMAIN, DMZ, mode='s3')
        self.result('INFO', 'S3 routing', 'S3 tests pin TLS/SNI to DMZ NPM. The dd7ae9... hostname intentionally resolves to services NPM internally, so its normal guest path should be blocked')
        self.section('7. Internal service names and services NPM')
        for short in SERVICES_NAMES + ['b9fb593d8225e38b40eacf070fa3995c.s3', S3_BUCKETS[1]]:
            self.check_dns(short + ' internal DNS', short + '.' + DOMAIN, SERVICES)
        self.result('INFO', 'Services NPM ACL boundary', '10.77.130.34:80/443 was tested as denied in section 5. Its npm-admin/npm-homestorage ACLs cannot be independently tested from guest while that network block holds')

    def media(self):
        self.section('8. Guest-to-entertainment HTTP restrictions')
        self.tcp_batch([('KEF HTTP access denied', ip, 80, False, False)
                        for ip in ['10.77.150.40', '10.77.150.42', '10.77.150.44']])
        self.result('INFO', 'Entertainment test scope', 'KEF TCP port 80 must be inaccessible from guest. These checks always run. Other entertainment ports, mDNS, streaming and UDP timing are outside these checks')

    def finish(self):
        self.section('Results')
        counts = {level: sum(1 for row in self.rows if row[0] == level)
                  for level in ['PASS', 'FAIL', 'BLOCKED', 'WARN', 'SKIP', 'INFO']}
        self.say('  '.join('{}={}'.format(k, v) for k, v in counts.items()))
        for level in ['FAIL', 'WARN']:
            for row in self.rows:
                if row[0] == level:
                    self.say('{}: {}'.format(level, row[1]))
        self.say('No rule-level certification is inferred from timeouts, refusals or skipped tests.')
        self.say('Report: ' + str(self.path.resolve()))
        self.log.close()
        return 1 if counts['FAIL'] else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--interface', help='Guest interface, e.g. en0. Default: current internet route interface')
    p.add_argument('--timeout', type=float, default=3, help='TCP connect timeout in seconds, 1 to 15 (default 3)')
    p.add_argument('--media', action='store_true', help='Compatibility option. KEF HTTP denial checks now always run')
    p.add_argument('--blocked-domain', action='append', default=[], metavar='HOST',
                   help='Additional domain expected to be DNS-filtered. DNS queries only. May be repeated')
    p.add_argument('--output', help='New text report path. Existing files are never overwritten')
    p.add_argument('--colour', choices=['auto', 'always', 'never'], default='auto')
    p.add_argument('--version', action='version', version=VERSION)
    args = p.parse_args()
    if not 1 <= args.timeout <= 15:
        p.error('--timeout must be between 1 and 15 seconds')
    for name in args.blocked_domain:
        if len(name) > 253 or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', name):
            p.error('--blocked-domain must be a DNS hostname, not a URL')
    audit = None
    try:
        audit = Audit(args)
        audit.preflight()
        audit.dns_and_internet()
        audit.redirection()
        audit.filtering()
        audit.isolation()
        audit.npm()
        audit.media()
        return audit.finish()
    except (RuntimeError, OSError, ValueError) as e:
        if audit:
            audit.result('FAIL', 'Setup/execution', str(e))
            audit.say('Stopped. Correct the setup and rerun. Report: ' + str(audit.path.resolve()))
            audit.log.close()
        else:
            print('ERROR: ' + str(e), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        if audit:
            audit.say('\nInterrupted. Partial report: ' + str(audit.path.resolve()))
            audit.log.close()
        return 130


if __name__ == '__main__':
    sys.exit(main())
