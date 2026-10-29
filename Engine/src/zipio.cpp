#include "zipio.hpp"

#include <zlib.h>

#include <cstring>
#include <stdexcept>

namespace a1 {

static uint16_t rd16(const std::string& s, size_t p) {
    return uint16_t((unsigned char)s[p]) | (uint16_t((unsigned char)s[p + 1]) << 8);
}
static uint32_t rd32(const std::string& s, size_t p) {
    return uint32_t(rd16(s, p)) | (uint32_t(rd16(s, p + 2)) << 16);
}
static void wr16(std::string& s, uint16_t v) { s.push_back(char(v & 0xff)); s.push_back(char(v >> 8)); }
static void wr32(std::string& s, uint32_t v) { wr16(s, uint16_t(v & 0xffff)); wr16(s, uint16_t(v >> 16)); }

ZipReader::ZipReader(std::string data) : data_(std::move(data)) {
    if (data_.size() < 22) throw std::runtime_error("Not a 3MF/zip file");
    size_t eocd = std::string::npos;
    size_t lo = data_.size() > 65557 ? data_.size() - 65557 : 0;
    for (size_t p = data_.size() - 22 + 1; p-- > lo;) {
        if (rd32(data_, p) == 0x06054b50) { eocd = p; break; }
    }
    if (eocd == std::string::npos) throw std::runtime_error("Not a 3MF/zip file (no directory)");
    uint16_t count = rd16(data_, eocd + 10);
    uint32_t cdOff = rd32(data_, eocd + 16);
    size_t p = cdOff;
    for (uint16_t i = 0; i < count; ++i) {
        if (p + 46 > data_.size() || rd32(data_, p) != 0x02014b50) throw std::runtime_error("Corrupt zip directory");
        Entry e;
        e.method = rd16(data_, p + 10);
        e.csize = rd32(data_, p + 20);
        e.usize = rd32(data_, p + 24);
        uint16_t nlen = rd16(data_, p + 28), xlen = rd16(data_, p + 30), clen = rd16(data_, p + 32);
        e.offset = rd32(data_, p + 42);
        std::string name = data_.substr(p + 46, nlen);
        entries_[name] = e;
        p += 46 + nlen + xlen + clen;
    }
}

std::vector<std::string> ZipReader::names() const {
    std::vector<std::string> v;
    for (auto& kv : entries_) v.push_back(kv.first);
    return v;
}

std::string ZipReader::read(const std::string& name) const {
    auto it = entries_.find(name);
    if (it == entries_.end()) throw std::runtime_error("Missing file in 3MF: " + name);
    const Entry& e = it->second;
    size_t p = e.offset;
    if (p + 30 > data_.size() || rd32(data_, p) != 0x04034b50) throw std::runtime_error("Corrupt zip entry: " + name);
    size_t start = p + 30 + rd16(data_, p + 26) + rd16(data_, p + 28);
    if (start + e.csize > data_.size()) throw std::runtime_error("Truncated zip entry: " + name);
    if (e.method == 0) return data_.substr(start, e.csize);
    if (e.method != 8) throw std::runtime_error("Unsupported compression in " + name);
    std::string out;
    out.resize(e.usize);
    z_stream zs;
    std::memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) throw std::runtime_error("inflate init failed");
    zs.next_in = (Bytef*)(data_.data() + start);
    zs.avail_in = e.csize;
    zs.next_out = (Bytef*)&out[0];
    zs.avail_out = e.usize;
    int r = inflate(&zs, Z_FINISH);
    inflateEnd(&zs);
    if (r != Z_STREAM_END && !(r == Z_BUF_ERROR && zs.avail_out == 0)) throw std::runtime_error("Couldn't decompress " + name);
    return out;
}

void ZipWriter::add(const std::string& name, const std::string& content, bool compress) {
    Entry e;
    e.name = name;
    e.usize = (uint32_t)content.size();
    e.crc = (uint32_t)crc32(0L, (const Bytef*)content.data(), (uInt)content.size());
    e.offset = (uint32_t)out_.size();
    std::string payload;
    if (compress && !content.empty()) {
        z_stream zs;
        std::memset(&zs, 0, sizeof(zs));
        deflateInit2(&zs, 6, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
        payload.resize(deflateBound(&zs, (uLong)content.size()));
        zs.next_in = (Bytef*)content.data();
        zs.avail_in = (uInt)content.size();
        zs.next_out = (Bytef*)&payload[0];
        zs.avail_out = (uInt)payload.size();
        deflate(&zs, Z_FINISH);
        payload.resize(zs.total_out);
        deflateEnd(&zs);
        e.method = 8;
    } else {
        payload = content;
        e.method = 0;
    }
    e.csize = (uint32_t)payload.size();
    wr32(out_, 0x04034b50); wr16(out_, 20); wr16(out_, 0); wr16(out_, e.method);
    wr16(out_, 0); wr16(out_, 0x21);  // time/date
    wr32(out_, e.crc); wr32(out_, e.csize); wr32(out_, e.usize);
    wr16(out_, (uint16_t)name.size()); wr16(out_, 0);
    out_ += name;
    out_ += payload;
    entries_.push_back(e);
}

std::string ZipWriter::finish() {
    uint32_t cd = (uint32_t)out_.size();
    for (auto& e : entries_) {
        wr32(out_, 0x02014b50); wr16(out_, 20); wr16(out_, 20); wr16(out_, 0); wr16(out_, e.method);
        wr16(out_, 0); wr16(out_, 0x21);
        wr32(out_, e.crc); wr32(out_, e.csize); wr32(out_, e.usize);
        wr16(out_, (uint16_t)e.name.size()); wr16(out_, 0); wr16(out_, 0); wr16(out_, 0); wr16(out_, 0);
        wr32(out_, 0); wr32(out_, e.offset);
        out_ += e.name;
    }
    uint32_t cdSize = (uint32_t)out_.size() - cd;
    wr32(out_, 0x06054b50); wr16(out_, 0); wr16(out_, 0);
    wr16(out_, (uint16_t)entries_.size()); wr16(out_, (uint16_t)entries_.size());
    wr32(out_, cdSize); wr32(out_, cd); wr16(out_, 0);
    return std::move(out_);
}

// ---- MD5 (RFC 1321) ----
namespace {
struct Md5 {
    uint32_t a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    static uint32_t rol(uint32_t x, int c) { return (x << c) | (x >> (32 - c)); }
    void block(const unsigned char* p) {
        static const uint32_t K[64] = {
            0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
            0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
            0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
            0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
            0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
            0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
            0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
            0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
        static const int S[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                  5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20,
                                  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
        uint32_t M[16];
        for (int i = 0; i < 16; ++i)
            M[i] = uint32_t(p[i * 4]) | (uint32_t(p[i * 4 + 1]) << 8) | (uint32_t(p[i * 4 + 2]) << 16) | (uint32_t(p[i * 4 + 3]) << 24);
        uint32_t A = a0, B = b0, C = c0, D = d0;
        for (int i = 0; i < 64; ++i) {
            uint32_t F; int g;
            if (i < 16) { F = (B & C) | (~B & D); g = i; }
            else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
            else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
            else { F = C ^ (B | ~D); g = (7 * i) % 16; }
            F = F + A + K[i] + M[g];
            A = D; D = C; C = B;
            B = B + rol(F, S[i]);
        }
        a0 += A; b0 += B; c0 += C; d0 += D;
    }
};
}  // namespace

std::string md5_hex(const std::string& data) {
    Md5 m;
    size_t n = data.size();
    size_t full = n / 64;
    for (size_t i = 0; i < full; ++i) m.block((const unsigned char*)data.data() + i * 64);
    unsigned char tail[128] = {0};
    size_t rem = n - full * 64;
    std::memcpy(tail, data.data() + full * 64, rem);
    tail[rem] = 0x80;
    size_t tl = rem + 1 + 8 <= 64 ? 64 : 128;
    uint64_t bits = uint64_t(n) * 8;
    for (int i = 0; i < 8; ++i) tail[tl - 8 + i] = (unsigned char)(bits >> (8 * i));
    m.block(tail);
    if (tl == 128) m.block(tail + 64);
    uint32_t h[4] = {m.a0, m.b0, m.c0, m.d0};
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j) {
            unsigned char b = (unsigned char)(h[i] >> (8 * j));
            out.push_back(hex[b >> 4]);
            out.push_back(hex[b & 15]);
        }
    return out;
}

}  // namespace a1
