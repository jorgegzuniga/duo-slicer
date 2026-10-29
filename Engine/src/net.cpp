// MQTT 3.1.1 over TLS + implicit FTPS (with TLS session reuse on the data channel), as Bambu printers expect.
#include "../include/a1net.h"

#if __has_include(<OpenSSL/ssl.h>)
#include <OpenSSL/err.h>
#include <OpenSSL/ssl.h>
#else
#include <openssl/err.h>
#include <openssl/ssl.h>
#endif

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

void setErr(char* err, size_t n, const std::string& m) {
    if (err && n) { std::snprintf(err, n, "%s", m.c_str()); }
}

SSL_CTX* clientCtx() {
    static SSL_CTX* c = [] {
        SSL_CTX* x = SSL_CTX_new(TLS_client_method());
        SSL_CTX_set_verify(x, SSL_VERIFY_NONE, nullptr);  // printers use self-signed certificates
        SSL_CTX_set_session_cache_mode(x, SSL_SESS_CACHE_CLIENT);
        return x;
    }();
    return c;
}

int64_t nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

int tcpConnect(const std::string& host, int port, int timeoutMs, std::string& err) {
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* res = nullptr;
    std::string ps = std::to_string(port);
    if (getaddrinfo(host.c_str(), ps.c_str(), &hints, &res) != 0 || !res) { err = "Couldn't find " + host + " on the network."; return -1; }
    int fd = -1;
    for (auto* ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
#ifdef SO_NOSIGPIPE
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int r = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (r < 0 && errno == EINPROGRESS) {
            struct pollfd p = {fd, POLLOUT, 0};
            r = poll(&p, 1, timeoutMs);
            if (r == 1) {
                int so = 0;
                socklen_t sl = sizeof so;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &so, &sl);
                r = so == 0 ? 0 : -1;
                if (so) errno = so;
            } else {
                if (r == 0) errno = ETIMEDOUT;
                r = -1;
            }
        }
        if (r == 0) {
            fcntl(fd, F_SETFL, flags);
            struct timeval tv = {30, 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
            int nd = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof nd);
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) err = "Couldn't reach " + host + ":" + ps + " (" + std::strerror(errno ? errno : ETIMEDOUT) + ").";
    return fd;
}

SSL* tlsWrap(int fd, SSL_SESSION* reuse, std::string& err) {
    SSL* s = SSL_new(clientCtx());
    SSL_set_fd(s, fd);
    if (reuse) SSL_set_session(s, reuse);
    if (SSL_connect(s) != 1) {
        unsigned long e = ERR_get_error();
        char buf[256] = {0};
        if (e) ERR_error_string_n(e, buf, sizeof buf);
        err = std::string("Secure connection failed") + (buf[0] ? std::string(": ") + buf : "");
        SSL_free(s);
        return nullptr;
    }
    return s;
}

bool sslWriteAll(SSL* s, const void* p, size_t n) {
    const char* c = (const char*)p;
    while (n) {
        int w = SSL_write(s, c, (int)std::min<size_t>(n, 1 << 16));
        if (w <= 0) return false;
        c += w;
        n -= (size_t)w;
    }
    return true;
}
bool sslReadAll(SSL* s, void* p, size_t n) {
    char* c = (char*)p;
    while (n) {
        int r = SSL_read(s, c, (int)std::min<size_t>(n, 1 << 16));
        if (r <= 0) return false;
        c += r;
        n -= (size_t)r;
    }
    return true;
}

void putStr(std::string& o, const std::string& s) {
    o.push_back(char(s.size() >> 8));
    o.push_back(char(s.size() & 0xff));
    o += s;
}
std::string packet(uint8_t type, const std::string& body) {
    std::string o;
    o.push_back((char)type);
    size_t n = body.size();
    do {
        uint8_t b = n % 128;
        n /= 128;
        if (n) b |= 0x80;
        o.push_back((char)b);
    } while (n);
    return o + body;
}

}  // namespace

struct A1Mqtt {
    int fd = -1;
    SSL* ssl = nullptr;
    std::mutex mu;
    int64_t lastSend = 0;
    uint16_t pid = 1;
    bool dead = false;
};

extern "C" {

void a1_net_free(void* p) { std::free(p); }

A1Mqtt* a1_mqtt_connect(const char* host, int port, const char* user, const char* pass, const char* clientId, int timeoutMs, char* err,
                        size_t errLen) {
    std::string e;
    int fd = tcpConnect(host, port, timeoutMs, e);
    if (fd < 0) { setErr(err, errLen, e); return nullptr; }
    SSL* s = tlsWrap(fd, nullptr, e);
    if (!s) { close(fd); setErr(err, errLen, e); return nullptr; }
    std::string body;
    putStr(body, "MQTT");
    body.push_back(4);           // protocol level 3.1.1
    body.push_back((char)0xC2);  // username + password + clean session
    body.push_back(0);
    body.push_back(60);  // keep alive (s)
    putStr(body, clientId);
    putStr(body, user);
    putStr(body, pass);
    std::string pk = packet(0x10, body);
    uint8_t ack[4];
    if (!sslWriteAll(s, pk.data(), pk.size()) || !sslReadAll(s, ack, 4) || ack[0] != 0x20) {
        SSL_free(s);
        close(fd);
        setErr(err, errLen, "The printer didn't answer the login.");
        return nullptr;
    }
    if (ack[3] != 0) {
        SSL_free(s);
        close(fd);
        setErr(err, errLen, ack[3] == 4 || ack[3] == 5 ? "The printer refused the access code." : "The printer refused the connection (code " + std::to_string(ack[3]) + ").");
        return nullptr;
    }
    auto* m = new A1Mqtt();
    m->fd = fd;
    m->ssl = s;
    m->lastSend = nowMs();
    return m;
}

int a1_mqtt_subscribe(A1Mqtt* m, const char* topic) {
    std::lock_guard<std::mutex> g(m->mu);
    std::string body;
    uint16_t id = m->pid++;
    body.push_back(char(id >> 8));
    body.push_back(char(id & 0xff));
    putStr(body, topic);
    body.push_back(0);
    std::string pk = packet(0x82, body);
    if (!sslWriteAll(m->ssl, pk.data(), pk.size())) { m->dead = true; return -1; }
    m->lastSend = nowMs();
    return 0;
}

int a1_mqtt_publish(A1Mqtt* m, const char* topic, const char* payload, size_t len) {
    std::lock_guard<std::mutex> g(m->mu);
    if (m->dead) return -1;
    std::string body;
    putStr(body, topic);
    body.append(payload, len);
    std::string pk = packet(0x30, body);
    if (!sslWriteAll(m->ssl, pk.data(), pk.size())) { m->dead = true; return -1; }
    m->lastSend = nowMs();
    return 0;
}

int a1_mqtt_poll(A1Mqtt* m, int timeoutMs, char** topic, char** payload, size_t* plen) {
    int64_t deadline = nowMs() + timeoutMs;
    for (;;) {
        if (m->dead) return -1;
        {
            std::lock_guard<std::mutex> g(m->mu);
            if (nowMs() - m->lastSend > 25000) {
                std::string ping = packet(0xC0, "");
                if (!sslWriteAll(m->ssl, ping.data(), ping.size())) { m->dead = true; return -1; }
                m->lastSend = nowMs();
            }
        }
        bool ready = SSL_pending(m->ssl) > 0;
        if (!ready) {
            int left = (int)std::max<int64_t>(0, deadline - nowMs());
            struct pollfd p = {m->fd, POLLIN, 0};
            int r = poll(&p, 1, std::min(left, 1000));
            if (r < 0 && errno != EINTR) { m->dead = true; return -1; }
            if (r > 0 && (p.revents & (POLLERR | POLLHUP)) && !(p.revents & POLLIN)) { m->dead = true; return -1; }
            ready = r > 0;
        }
        if (ready) {
            std::lock_guard<std::mutex> g(m->mu);
            uint8_t h;
            if (!sslReadAll(m->ssl, &h, 1)) { m->dead = true; return -1; }
            size_t len = 0, mult = 1;
            for (int i = 0; i < 4; ++i) {
                uint8_t b;
                if (!sslReadAll(m->ssl, &b, 1)) { m->dead = true; return -1; }
                len += (b & 127) * mult;
                mult *= 128;
                if (!(b & 128)) break;
            }
            std::string body(len, '\0');
            if (len && !sslReadAll(m->ssl, &body[0], len)) { m->dead = true; return -1; }
            if ((h & 0xF0) == 0x30 && body.size() >= 2) {
                size_t tl = ((uint8_t)body[0] << 8) | (uint8_t)body[1];
                if (2 + tl > body.size()) continue;
                size_t off = 2 + tl;
                int qos = (h >> 1) & 3;
                if (qos) off += 2;
                std::string t = body.substr(2, tl);
                *topic = (char*)std::malloc(t.size() + 1);
                std::memcpy(*topic, t.c_str(), t.size() + 1);
                size_t pl = off <= body.size() ? body.size() - off : 0;
                *payload = (char*)std::malloc(pl + 1);
                if (pl) std::memcpy(*payload, body.data() + off, pl);
                (*payload)[pl] = 0;
                *plen = pl;
                return 1;
            }
            continue;  // SUBACK, PINGRESP, ...
        }
        if (nowMs() >= deadline) return 0;
    }
}

void a1_mqtt_close(A1Mqtt* m) {
    if (!m) return;
    {
        std::lock_guard<std::mutex> g(m->mu);
        if (!m->dead) {
            std::string d = packet(0xE0, "");
            sslWriteAll(m->ssl, d.data(), d.size());
        }
        SSL_shutdown(m->ssl);
        SSL_free(m->ssl);
        close(m->fd);
    }
    delete m;
}

}  // extern "C"

// ---------------------------------------------------------------- FTPS
namespace {

struct Ftp {
    int fd = -1;
    SSL* ssl = nullptr;
    std::string buf;
    std::string lastLine;

    bool readLine(std::string& line) {
        for (;;) {
            size_t p = buf.find("\r\n");
            if (p != std::string::npos) {
                line = buf.substr(0, p);
                buf.erase(0, p + 2);
                return true;
            }
            char tmp[1024];
            int r = SSL_read(ssl, tmp, sizeof tmp);
            if (r <= 0) return false;
            buf.append(tmp, (size_t)r);
        }
    }
    // Returns reply code, or -1.
    int reply() {
        std::string line;
        if (!readLine(line) || line.size() < 3) return -1;
        lastLine = line;
        int code = std::atoi(line.substr(0, 3).c_str());
        if (line.size() > 3 && line[3] == '-') {
            std::string end = line.substr(0, 3) + " ";
            while (readLine(line)) {
                lastLine = line;
                if (line.compare(0, 4, end) == 0) break;
            }
        }
        return code;
    }
    int cmd(const std::string& c) {
        std::string l = c + "\r\n";
        if (!sslWriteAll(ssl, l.data(), l.size())) return -1;
        return reply();
    }
};

}  // namespace

extern "C" int a1_ftps_upload(const char* host, int port, const char* user, const char* pass, const char* remoteName, const uint8_t* data, size_t len,
                              A1UploadProgress progress, void* ctx, char* err, size_t errLen) {
    std::string e;
    Ftp f;
    f.fd = tcpConnect(host, port, 8000, e);
    if (f.fd < 0) { setErr(err, errLen, e); return -1; }
    f.ssl = tlsWrap(f.fd, nullptr, e);
    if (!f.ssl) { close(f.fd); setErr(err, errLen, e); return -1; }
    auto fail = [&](const std::string& m) {
        setErr(err, errLen, m + (f.lastLine.empty() ? "" : " (printer said: " + f.lastLine + ")"));
        if (f.ssl) { SSL_free(f.ssl); }
        if (f.fd >= 0) close(f.fd);
        return -1;
    };
    if (f.reply() != 220) return fail("The printer's file server didn't respond.");
    int c = f.cmd(std::string("USER ") + user);
    if (c == 331) c = f.cmd(std::string("PASS ") + pass);
    if (c != 230) return fail("The printer refused the access code.");
    if (f.cmd("PBSZ 0") / 100 != 2) return fail("Couldn't set up a secure transfer.");
    if (f.cmd("PROT P") / 100 != 2) return fail("Couldn't set up a secure transfer.");
    if (f.cmd("TYPE I") / 100 != 2) return fail("Couldn't switch to binary mode.");
    if (f.cmd("PASV") != 227) return fail("The printer didn't open a data connection.");
    int h1, h2, h3, h4, p1, p2;
    size_t lp = f.lastLine.find('(');
    if (lp == std::string::npos || std::sscanf(f.lastLine.c_str() + lp, "(%d,%d,%d,%d,%d,%d)", &h1, &h2, &h3, &h4, &p1, &p2) != 6)
        return fail("Unexpected data connection reply.");
    int dport = p1 * 256 + p2;
    int dfd = tcpConnect(host, dport, 8000, e);  // always the printer's address, ignore the advertised one
    if (dfd < 0) return fail(e);
    std::string stor = std::string("STOR ") + remoteName + "\r\n";
    if (!sslWriteAll(f.ssl, stor.data(), stor.size())) { close(dfd); return fail("Lost the connection."); }
    int r = f.reply();
    if (r / 100 != 1) { close(dfd); return fail("The printer wouldn't accept the file. Is a microSD card inserted?"); }
    SSL_SESSION* sess = SSL_get1_session(f.ssl);
    SSL* ds = tlsWrap(dfd, sess, e);
    if (sess) SSL_SESSION_free(sess);
    if (!ds) { close(dfd); return fail(e); }
    size_t sent = 0;
    const size_t chunk = 64 * 1024;
    bool ok = true;
    while (sent < len) {
        size_t n = std::min(chunk, len - sent);
        if (!sslWriteAll(ds, data + sent, n)) { ok = false; break; }
        sent += n;
        if (progress) progress((double)sent / (double)len, ctx);
    }
    SSL_shutdown(ds);
    SSL_free(ds);
    close(dfd);
    if (!ok) return fail("The upload was interrupted.");
    r = f.reply();
    if (r / 100 != 2) return fail("The printer didn't confirm the upload.");
    f.cmd("QUIT");
    SSL_free(f.ssl);
    close(f.fd);
    return 0;
}
